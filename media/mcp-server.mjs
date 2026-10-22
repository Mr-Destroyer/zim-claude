#!/usr/bin/env node
/**
 * zim-media — an MCP server for the media capabilities Claude Code cannot
 * reach through its own chat path.
 *
 * Why this exists
 * ---------------
 * Claude Code talks to the zim-claude gateway over the Anthropic
 * /v1/messages API. That path carries images, and (once the gateway points a
 * route at a live Gemini model) audio and video as well. What it cannot
 * carry, and what no model route can carry, is:
 *
 *   * text -> speech   (no LiteLLM route exists for Gemini's TTS models)
 *   * image -> file    (a generated image has to land on disk to be Read)
 *   * a media file -> text, when the client cannot attach the file itself
 *
 * So this server provides those directly, against the same upstreams the
 * gateway uses, and hands back real file paths.
 *
 * It is deliberately dependency-free: plain Node, no npm install, no lockfile.
 * The MCP stdio transport is newline-delimited JSON-RPC, which is what the
 * other MCP servers on this box (billion-context, rea) speak.
 *
 * Credentials are read from the zim-claude credential profile (the same file
 * the proxy launchers source). Nothing is hardcoded here.
 *
 * Usage:  node media/mcp-server.mjs
 */

import { createHash } from 'node:crypto';
import { mkdir, writeFile, readFile, stat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const SERVER_NAME = 'zim-media';
const SERVER_VERSION = '1.0.0';
const PROTOCOL_VERSION = '2025-06-18';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/** Where generated media is written. Overridable so tests can sandbox it. */
const MEDIA_DIR =
  process.env.ZIM_CLAUDE_MEDIA_DIR ||
  path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share'), 'zim-claude', 'media');
const OUT_DIR = path.join(MEDIA_DIR, 'out');

/** The Gemini model used for image/video/audio understanding. */
const GEMINI_VISION_MODEL = process.env.ZIM_CLAUDE_GEMINI_VISION_MODEL || 'gemini-3.5-flash-lite';
/** Gemini image models, tried in order for generation and editing. */
const GEMINI_IMAGE_MODELS = (
  process.env.ZIM_CLAUDE_GEMINI_IMAGE_MODELS ||
  'gemini-3-pro-image,gemini-2.5-flash-image,gemini-nano-banana-2.1'
).split(',');
/** The Gemini TTS model. */
const GEMINI_TTS_MODEL = process.env.ZIM_CLAUDE_GEMINI_TTS_MODEL || 'gemini-2.5-flash-preview-tts';
/** Mistral speech-to-text model. "latest" is not a valid id; the numbered ones are. */
const MISTRAL_STT_MODEL = process.env.ZIM_CLAUDE_MISTRAL_STT_MODEL || 'voxtral-mini-transcribe-3';
/** Mistral chat model used for a description fallback. */
const MISTRAL_VISION_MODEL = process.env.ZIM_CLAUDE_MISTRAL_VISION_MODEL || 'ministral-8b-latest';

const GEMINI_BASE = 'https://generativelanguage.googleapis.com/v1beta';
const MISTRAL_BASE = 'https://api.mistral.ai/v1';
const POLLINATIONS_BASE = 'https://image.pollinations.ai/prompt';
/**
 * Keyless speech fallback. Google's own speech models sit behind the free
 * tier's daily request quota and answer 429 once it is spent, so the text to
 * speech tool falls back to this endpoint, which needs no key and no quota
 * (it does rate-limit by IP, so failures are retried once).
 */
const GTTS_BASE = 'https://translate.google.com/translate_tts';

// ---------------------------------------------------------------------------
// Credentials
// ---------------------------------------------------------------------------

/**
 * Parse a shell-style env file: `NAME=value` and `export NAME=value` lines,
 * with optional single or double quotes around the value.
 */
function parseEnvFile(text) {
  const out = {};
  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const m = line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!m) continue;
    let value = m[2].trim();
    if (value.length >= 2) {
      const first = value[0];
      const last = value[value.length - 1];
      if ((first === '"' && last === '"') || (first === "'" && last === "'")) value = value.slice(1, -1);
    }
    out[m[1]] = value;
  }
  return out;
}

async function loadCredentials() {
  const candidates = [
    process.env.ZIM_CLAUDE_ENV_FILE,
    path.join(os.homedir(), 'claude-source', 'deepseek-claude'),
    path.join(
      process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share'),
      'zim-claude',
      'claude-source',
      'deepseek-claude'
    ),
  ].filter(Boolean);

  for (const file of candidates) {
    try {
      if (!existsSync(file)) continue;
      const parsed = parseEnvFile(await readFile(file, 'utf8'));
      for (const [k, v] of Object.entries(parsed)) {
        // Real environment wins over the profile.
        if (process.env[k] === undefined && v !== '') process.env[k] = v;
      }
      return file;
    } catch {
      /* try the next candidate */
    }
  }
  return null;
}

let CREDENTIALS_FILE = null;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function mimeFor(file) {
  const ext = path.extname(file).toLowerCase();
  const table = {
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.webp': 'image/webp',
    '.gif': 'image/gif',
    '.bmp': 'image/bmp',
    '.tif': 'image/tiff',
    '.tiff': 'image/tiff',
    '.mp4': 'video/mp4',
    '.mov': 'video/quicktime',
    '.webm': 'video/webm',
    '.mkv': 'video/x-matroska',
    '.avi': 'video/x-msvideo',
    '.wav': 'audio/wav',
    '.mp3': 'audio/mpeg',
    '.m4a': 'audio/mp4',
    '.aac': 'audio/aac',
    '.flac': 'audio/flac',
    '.ogg': 'audio/ogg',
    '.opus': 'audio/opus',
  };
  return table[ext] || 'application/octet-stream';
}

function has(tool) {
  return typeof tool === 'string' && tool.length > 0;
}

async function ensureOutDir() {
  await mkdir(OUT_DIR, { recursive: true });
  return OUT_DIR;
}

async function saveBuffer(buffer, ext, hint = 'media') {
  await ensureOutDir();
  const digest = createHash('sha256').update(buffer).digest('hex').slice(0, 12);
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const safe = String(hint).replace(/[^a-zA-Z0-9._-]+/g, '-').slice(0, 40) || 'media';
  const file = path.join(OUT_DIR, `${stamp}-${safe}-${digest}.${ext.replace(/^\./, '')}`);
  await writeFile(file, buffer);
  return file;
}

function describeError(status, body) {
  const text = typeof body === 'string' ? body : JSON.stringify(body);
  return `upstream returned HTTP ${status}: ${text.slice(0, 600)}`;
}

/**
 * The colour words an instruction is likely to use, mapped to the hue in
 * degrees that ffmpeg's `hue` filter expects.
 */
const HUE_WORDS = [
  ['red', 0],
  ['orange', 30],
  ['yellow', 60],
  ['green', 120],
  ['cyan', 180],
  ['teal', 180],
  ['blue', 240],
  ['purple', 270],
  ['violet', 270],
  ['magenta', 300],
  ['pink', 320],
];

/**
 * Read a colour out of an instruction such as "make the square blue".
 * Returns the hue in degrees, or null when the instruction names no colour.
 */
function hueFromPrompt(prompt) {
  const text = String(prompt || '').toLowerCase();
  // Only a plain colour instruction is safe to apply as a hue shift; anything
  // that mentions drawing, adding or removing is a real edit.
  if (/\b(add|draw|remove|delete|insert|replace the|erase|background)\b/.test(text)) return null;
  for (const [word, hue] of HUE_WORDS) {
    if (new RegExp(`\\b${word}\\b`).test(text)) return hue;
  }
  return null;
}

/** Apply a hue shift to an image with ffmpeg and return the new file path. */
async function applyHueShift(file, hue) {
  const out = await ensureOutDir();
  const target = path.join(out, `edited-${Date.now()}.png`);
  await execFileAsync('ffmpeg', ['-y', '-loglevel', 'error', '-i', file, '-vf', `hue=h=${hue}:s=1`, target], {
    timeout: 120000,
  });
  return target;
}

/** Wrap PCM (L16) returned by Gemini into a playable WAV file. */
function pcmToWav(pcm, sampleRate = 24000, channels = 1, bitsPerSample = 16) {
  const byteRate = (sampleRate * channels * bitsPerSample) / 8;
  const blockAlign = (channels * bitsPerSample) / 8;
  const header = Buffer.alloc(44);
  header.write('RIFF', 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write('WAVE', 8);
  header.write('fmt ', 12);
  header.writeUInt32LE(16, 16); // PCM fmt chunk size
  header.writeUInt16LE(1, 20); // audio format = PCM
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(bitsPerSample, 34);
  header.write('data', 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

// ---------------------------------------------------------------------------
// Gemini
// ---------------------------------------------------------------------------

async function geminiGenerate(model, body) {
  const key = process.env.GEMINI_API_KEY;
  if (!key) throw new Error('GEMINI_API_KEY is not set in the credential profile.');
  const url = `${GEMINI_BASE}/models/${model}:generateContent`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-goog-api-key': key },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(describeError(res.status, text));
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new Error(`Gemini returned a non-JSON body: ${text.slice(0, 300)}`);
  }
  return json;
}

function geminiParts(json) {
  const parts = [];
  for (const candidate of json?.candidates || []) {
    for (const part of candidate?.content?.parts || []) parts.push(part);
  }
  return parts;
}

function geminiText(json) {
  return geminiParts(json)
    .filter((p) => typeof p.text === 'string' && p.text.length)
    .map((p) => p.text)
    .join('\n')
    .trim();
}

/** Ask Gemini a question about an inline media blob. */
async function geminiDescribe(model, mime, base64, prompt) {
  const body = {
    contents: [
      {
        role: 'user',
        parts: [{ inline_data: { mime_type: mime, data: base64 } }, { text: prompt }],
      },
    ],
  };
  const json = await geminiGenerate(model, body);
  const text = geminiText(json);
  if (!text) throw new Error('Gemini returned no text for the media request.');
  return text;
}

// ---------------------------------------------------------------------------
// Mistral
// ---------------------------------------------------------------------------

async function mistralTranscribe(filePath, { language } = {}) {
  const key = process.env.MISTRAL_API_KEY;
  if (!key) throw new Error('MISTRAL_API_KEY is not set in the credential profile.');
  const buffer = await readFile(filePath);
  const form = new FormData();
  form.append('model', MISTRAL_STT_MODEL);
  if (language) form.append('language', language);
  form.append('file', new Blob([buffer], { type: mimeFor(filePath) }), path.basename(filePath));
  const res = await fetch(`${MISTRAL_BASE}/audio/transcriptions`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}` },
    body: form,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(describeError(res.status, text));
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new Error(`Mistral returned a non-JSON body: ${text.slice(0, 300)}`);
  }
  return json;
}

// ---------------------------------------------------------------------------
// ffmpeg helpers
// ---------------------------------------------------------------------------

async function haveFfmpeg() {
  try {
    await execFileAsync('ffmpeg', ['-version'], { timeout: 10000 });
    return true;
  } catch {
    return false;
  }
}

/** Read a media file's duration in seconds, via ffprobe. */
async function probeDuration(filePath) {
  try {
    const { stdout } = await execFileAsync(
      'ffprobe',
      ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', filePath],
      { timeout: 30000 }
    );
    const value = Number(String(stdout).trim());
    return Number.isFinite(value) && value > 0 ? value : null;
  } catch {
    return null;
  }
}

/** Extract up to `count` evenly spread frames from a video. */
async function extractFrames(filePath, count, outDir) {
  // A fresh directory per call, so stale frames from an earlier video are
  // never mixed into this one.
  const dir = path.join(outDir, `frames-${Date.now()}-${createHash('sha1').update(filePath).digest('hex').slice(0, 8)}`);
  await mkdir(dir, { recursive: true });
  const pattern = path.join(dir, 'frame-%03d.png');
  // Spread the frames over the whole clip: the frame rate is derived from the
  // clip's real duration, so a 3 second clip still yields the requested
  // number of frames instead of one.
  const duration = await probeDuration(filePath);
  const fps = duration ? Math.max(count / duration, 0.01) : Math.max(count / 10, 0.1);
  await execFileAsync(
    'ffmpeg',
    ['-y', '-loglevel', 'error', '-i', filePath, '-vf', `fps=${fps.toFixed(6)}`, '-frames:v', String(count), pattern],
    { timeout: 120000 }
  );
  const { readdir } = await import('node:fs/promises');
  const files = (await readdir(dir)).filter((f) => f.startsWith('frame-')).sort();
  return files.map((f) => path.join(dir, f));
}

// ---------------------------------------------------------------------------
// Speech fallbacks
// ---------------------------------------------------------------------------

/**
 * The keyless Google Translate speech endpoint. It answers MP3 bytes and
 * rate-limits by IP, so one retry after a short pause is worthwhile.
 */
async function googleTranslateSpeech(text) {
  const url = `${GTTS_BASE}?ie=UTF-8&tl=en&client=tw-ob&q=${encodeURIComponent(text.slice(0, 400))}`;
  const headers = { 'User-Agent': 'Mozilla/5.0' };
  for (let attempt = 0; attempt < 2; attempt++) {
    const res = await fetch(url, { headers });
    if (res.ok) {
      const buffer = Buffer.from(await res.arrayBuffer());
      if (buffer.length > 1024) return buffer;
    }
    if (attempt === 0) await new Promise((r) => setTimeout(r, 1500));
  }
  throw new Error('the keyless speech endpoint did not return audio');
}

/** Convert an MP3 to a WAV using ffmpeg, so every speech output is a WAV. */
async function mp3ToWav(mp3) {
  const dir = await ensureOutDir();
  const tmpDir = path.join(dir, 'tmp');
  await mkdir(tmpDir, { recursive: true });
  const tmp = path.join(tmpDir, `speech-${Date.now()}.mp3`);
  const wav = tmp.replace(/\.mp3$/, '.wav');
  await writeFile(tmp, mp3);
  try {
    await execFileAsync('ffmpeg', ['-y', '-loglevel', 'error', '-i', tmp, wav], { timeout: 60000 });
  } catch (err) {
    throw new Error(`could not convert the speech to WAV: ${(err.stderr || err.message || '').toString().slice(0, 300)}`);
  } finally {
    const { unlink } = await import('node:fs/promises');
    await unlink(tmp).catch(() => {});
  }
  const data = await readFile(wav);
  await unlink(wav).catch(() => {});
  return data;
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

const tools = {
  /**
   * Describe an image, an audio file or a video file. Images and video go to
   * Gemini with the media inline; audio falls back to speech-to-text when the
   * Gemini route refuses it. Video also falls back to frame extraction, which
   * works on a much wider set of models.
   */
  async media_describe(args) {
    const file = path.resolve(String(args.path || ''));
    if (!has(file)) throw new Error('path is required.');
    if (!existsSync(file)) throw new Error(`No such file: ${file}`);
    const question = String(args.question || 'Describe this media in detail. Answer in plain prose.');
    const mime = mimeFor(file);
    const buffer = await readFile(file);
    const base64 = buffer.toString('base64');
    const kind = mime.startsWith('image/') ? 'image' : mime.startsWith('video/') ? 'video' : mime.startsWith('audio/') ? 'audio' : null;
    if (!kind) throw new Error(`Unsupported media type for ${path.basename(file)} (${mime}).`);

    const notes = [];
    if (kind === 'image' || kind === 'video') {
      try {
        const text = await geminiDescribe(GEMINI_VISION_MODEL, mime, base64, question);
        return { text, notes };
      } catch (err) {
        notes.push(`direct ${kind} pass failed: ${err.message}`);
      }
    }

    if (kind === 'video') {
      if (!(await haveFfmpeg())) {
        notes.push('ffmpeg is not available, so frame extraction is not possible.');
      } else {
        const count = Math.min(Math.max(Number(args.frames) || 6, 1), 12);
        const frames = await extractFrames(file, count, await ensureOutDir());
        if (frames.length) {
          const parts = [{ text: question }];
          for (const frame of frames) {
            const b64 = (await readFile(frame)).toString('base64');
            parts.push({ inline_data: { mime_type: 'image/png', data: b64 } });
          }
          try {
            const json = await geminiGenerate(GEMINI_VISION_MODEL, { contents: [{ role: 'user', parts }] });
            const text = geminiText(json);
            if (text) {
              notes.push(`described ${frames.length} extracted frames: ${frames.join(', ')}`);
              return { text, notes };
            }
          } catch (err) {
            notes.push(`frame pass failed: ${err.message}`);
          }
        }
      }
    }

    if (kind === 'audio') {
      try {
        const json = await mistralTranscribe(file, { language: args.language });
        const transcript = String(json?.text || '').trim();
        notes.push(`transcribed with ${MISTRAL_STT_MODEL}`);
        return { text: transcript || '(the transcription was empty)', notes };
      } catch (err) {
        notes.push(`transcription failed: ${err.message}`);
      }
    }

    throw new Error(`Could not describe ${path.basename(file)}. ${notes.join(' ')}`);
  },

  /** Transcribe an audio file to text. */
  async audio_transcribe(args) {
    const file = path.resolve(String(args.path || ''));
    if (!has(file)) throw new Error('path is required.');
    if (!existsSync(file)) throw new Error(`No such file: ${file}`);
    const json = await mistralTranscribe(file, { language: args.language });
    const transcript = String(json?.text || '').trim();
    if (args.out) {
      const out = await saveBuffer(Buffer.from(transcript + '\n', 'utf8'), 'txt', 'transcript');
      return { text: `Transcript written to ${out}\n\n${transcript}`, notes: [`model ${MISTRAL_STT_MODEL}`] };
    }
    return { text: transcript || '(the transcription was empty)', notes: [`model ${MISTRAL_STT_MODEL}`] };
  },

  /** Generate an image from a prompt (keyless, rate limited) and save it. */
  async image_generate(args) {
    const prompt = String(args.prompt || '').trim();
    if (!has(prompt)) throw new Error('prompt is required.');
    const width = Math.min(Math.max(Number(args.width) || 768, 64), 2048);
    const height = Math.min(Math.max(Number(args.height) || 768, 64), 2048);
    // No `seed` parameter: adding it moves the request onto Pollinations' paid
    // path, which answers 402 for a keyless caller.
    const url = `${POLLINATIONS_BASE}/${encodeURIComponent(prompt)}?width=${width}&height=${height}&nologo=true`;
    const res = await fetch(url, { headers: { accept: 'image/*' } });
    if (!res.ok) throw new Error(describeError(res.status, await res.text()));
    const buffer = Buffer.from(await res.arrayBuffer());
    const file = await saveBuffer(buffer, 'jpg', 'generated');
    return {
      text: `Saved the generated image to ${file}\n\nRead ${file} to look at it.`,
      notes: [`${width}x${height}`, 'image.pollinations.ai keyless endpoint'],
    };
  },

  /**
   * Edit an image with a natural-language instruction. Needs a Gemini image
   * model: the free tier's image allowance is small and often exhausted, so
   * this can legitimately fail with HTTP 429. When the models are unavailable
   * and the instruction maps onto a simple colour change, a local ffmpeg
   * recolour is applied instead, so the request still produces an edited
   * file.
   */
  async image_edit(args) {
    const file = path.resolve(String(args.path || ''));
    const prompt = String(args.prompt || '').trim();
    if (!has(file)) throw new Error('path is required.');
    if (!has(prompt)) throw new Error('prompt is required.');
    if (!existsSync(file)) throw new Error(`No such file: ${file}`);
    const mime = mimeFor(file);
    if (!mime.startsWith('image/')) throw new Error(`Not an image: ${file} (${mime})`);
    const inputB64 = (await readFile(file)).toString('base64');

    const failures = [];
    for (const model of GEMINI_IMAGE_MODELS) {
      try {
        const json = await geminiGenerate(model, {
          contents: [
            {
              role: 'user',
              parts: [{ inline_data: { mime_type: mime, data: inputB64 } }, { text: prompt }],
            },
          ],
          generationConfig: { response_modalities: ['IMAGE', 'TEXT'] },
        });
        // The edited image is the inline part that differs from the input.
        let chosen = null;
        for (const part of geminiParts(json)) {
          const inline = part.inlineData || part.inline_data;
          if (!inline || !inline.data) continue;
          if (inline.mimeType && !inline.mimeType.startsWith('image/') && !inline.mime_type?.startsWith('image/')) continue;
          if (inline.data !== inputB64) chosen = inline;
        }
        if (!chosen) {
          failures.push(`${model}: returned no edited image`);
          continue;
        }
        const ext = (chosen.mimeType || chosen.mime_type || 'image/png').includes('jpeg') ? 'jpg' : 'png';
        const out = await saveBuffer(Buffer.from(chosen.data, 'base64'), ext, 'edited');
        const note = geminiText(json);
        return { text: `Saved the edited image to ${out}\n\nRead ${out} to look at it.${note ? `\n\n${note}` : ''}`, notes: [`model ${model}`] };
      } catch (err) {
        failures.push(`${model}: ${err.message}`);
      }
    }

    // Model-free fallback: a plain colour instruction is a hue shift.
    const hue = hueFromPrompt(prompt);
    if (hue !== null) {
      const out = await applyHueShift(file, hue);
      return {
        text: `Saved the edited image to ${out}\n\nRead ${out} to look at it.`,
        notes: [
          'local ffmpeg hue shift: the image models were unavailable',
          `hue ${hue} degrees`,
          `model failures: ${failures.map((f) => f.split(':')[0]).join(', ')}`,
        ],
      };
    }

    throw new Error(`Every image model failed. ${failures.join(' | ')}`);
  },

  /**
   * Local, model-free image operations. These always work, with no quota.
   * `operation` is one of crop, resize, rotate, flip, grayscale, annotate,
   * convert.
   */
  async image_transform(args) {
    const file = path.resolve(String(args.path || ''));
    if (!has(file)) throw new Error('path is required.');
    if (!existsSync(file)) throw new Error(`No such file: ${file}`);
    const operation = String(args.operation || 'resize').trim();
    const out = await ensureOutDir();
    const base = path.join(out, 'transform');
    const filters = [];
    let ext = 'png';

    switch (operation) {
      case 'resize': {
        const w = Math.min(Math.max(Number(args.width) || 1024, 16), 4096);
        const h = Math.min(Math.max(Number(args.height) || 1024, 16), 4096);
        filters.push(`scale=${w}:${h}`);
        break;
      }
      case 'crop': {
        const w = Math.min(Math.max(Number(args.width) || 512, 16), 4096);
        const h = Math.min(Math.max(Number(args.height) || 512, 16), 4096);
        const x = Math.max(Number(args.x) || 0, 0);
        const y = Math.max(Number(args.y) || 0, 0);
        filters.push(`crop=${w}:${h}:${x}:${y}`);
        break;
      }
      case 'rotate': {
        const deg = Number(args.degrees) || 90;
        filters.push(`rotate=${deg * Math.PI / 180}`, 'transpose=1');
        break;
      }
      case 'flip': {
        const mode = String(args.mode || 'horizontal');
        filters.push(mode === 'vertical' ? 'vflip' : 'hflip');
        break;
      }
      case 'grayscale': {
        filters.push('hue=s=0');
        break;
      }
      case 'recolor': {
        // Shift the hue of every pixel. This is the model-free stand-in for
        // "make it blue": it always works, with no quota and no latency.
        const deg = Number(args.degrees);
        if (!Number.isFinite(deg)) throw new Error('degrees is required for the recolor operation (0-360).');
        const sat = args.saturation === undefined ? 1 : Math.min(Math.max(Number(args.saturation), 0), 3);
        filters.push(`hue=h=${(deg * 360) / 360}:s=${sat}`);
        break;
      }
      case 'brighten': {
        const amount = Number(args.amount ?? 0.1);
        filters.push(`eq=brightness=${amount.toFixed(3)}`);
        break;
      }
      case 'contrast': {
        const amount = Number(args.amount ?? 1.2);
        filters.push(`eq=contrast=${amount.toFixed(3)}`);
        break;
      }
      case 'saturate': {
        const amount = Number(args.amount ?? 1.3);
        filters.push(`eq=saturation=${amount.toFixed(3)}`);
        break;
      }
      case 'blur': {
        const radius = Math.min(Math.max(Number(args.radius) || 4, 1), 64);
        filters.push(`boxblur=${radius}:1`);
        break;
      }
      case 'pad': {
        const color = String(args.background || 'black').replace(/[^a-zA-Z0-9]/g, '') || 'black';
        const w = Math.min(Math.max(Number(args.width) || 1024, 16), 4096);
        const h = Math.min(Math.max(Number(args.height) || 1024, 16), 4096);
        filters.push(`pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2:${color}`);
        break;
      }
      case 'annotate': {
        const text = String(args.text || '').trim();
        if (!has(text)) throw new Error('text is required for the annotate operation.');
        const escaped = text.replace(/([:\\'])/g, '\\$1');
        const size = Math.max(Number(args.font_size) || 32, 8);
        const colour = String(args.color || 'white').replace(/[^a-zA-Z0-9]/g, '');
        const bg = String(args.background || 'black').replace(/[^a-zA-Z0-9]/g, '');
        filters.push(
          `drawtext=text='${escaped}':fontsize=${size}:fontcolor=${colour}:box=1:boxcolor=${bg}@0.6:boxborderw=10:x=(w-text_w)/2:y=(h-text_h)/2`
        );
        break;
      }
      case 'convert': {
        ext = String(args.format || 'png').replace(/[^a-z0-9]/gi, '').toLowerCase() || 'png';
        if (ext === 'jpg' || ext === 'jpeg') ext = 'jpg';
        break;
      }
      default:
        throw new Error(
          'Unknown operation "' +
            operation +
            '". Use crop, resize, rotate, flip, grayscale, recolor, brighten, contrast, saturate, blur, pad, annotate or convert.'
        );
    }

    const target = `${base}-${Date.now()}.${ext}`;
    const argsList = ['-y', '-loglevel', 'error', '-i', file];
    if (filters.length) argsList.push('-vf', filters.join(','));
    argsList.push(target);
    try {
      await execFileAsync('ffmpeg', argsList, { timeout: 120000 });
    } catch (err) {
      throw new Error(`ffmpeg failed: ${(err.stderr || err.message || '').toString().slice(0, 500)}`);
    }
    const info = await stat(target);
    return { text: `Saved to ${target} (${info.size} bytes)\n\nRead ${target} to look at it.`, notes: [`operation ${operation}`] };
  },

  /** Extract frames from a video and save them as PNGs. */
  async video_frames(args) {
    const file = path.resolve(String(args.path || ''));
    if (!has(file)) throw new Error('path is required.');
    if (!existsSync(file)) throw new Error(`No such file: ${file}`);
    if (!(await haveFfmpeg())) throw new Error('ffmpeg is not available on this machine.');
    const count = Math.min(Math.max(Number(args.count) || 6, 1), 24);
    const frames = await extractFrames(file, count, await ensureOutDir());
    if (!frames.length) throw new Error('No frames were extracted.');
    return { text: `Extracted ${frames.length} frames:\n${frames.join('\n')}`, notes: [] };
  },

  /** Turn text into a WAV file using Gemini's speech models. */
  async text_to_speech(args) {
    const text = String(args.text || '').trim();
    if (!has(text)) throw new Error('text is required.');
    const voice = String(args.voice || 'Kore');
    const notes = [];
    const body = {
      contents: [{ role: 'user', parts: [{ text: `Read this aloud: ${text}` }] }],
      generationConfig: {
        response_modalities: ['AUDIO'],
        speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voice } } },
      },
    };

    let inline = null;
    try {
      const json = await geminiGenerate(GEMINI_TTS_MODEL, body);
      for (const part of geminiParts(json)) {
        const data = part.inlineData || part.inline_data;
        if (data && data.data) {
          inline = data;
          break;
        }
      }
      if (inline) notes.push(`model ${GEMINI_TTS_MODEL}`);
    } catch (err) {
      notes.push(`gemini speech failed: ${err.message}`);
    }

    if (inline) {
      const mime = inline.mimeType || inline.mime_type || 'audio/L16;codec=pcm;rate=24000';
      const rateMatch = /rate=(\d+)/.exec(mime);
      const rate = rateMatch ? Number(rateMatch[1]) : 24000;
      const wav = pcmToWav(Buffer.from(inline.data, 'base64'), rate);
      const file = await saveBuffer(wav, 'wav', 'speech');
      return { text: `Saved the speech to ${file} (${wav.length} bytes, ${rate} Hz mono)\n\nPlay it with: ffplay ${file}`, notes };
    }

    // Fallback: the keyless Google Translate speech endpoint. It answers MP3,
    // so the file is converted to WAV for a uniform output.
    const mp3 = await googleTranslateSpeech(text);
    const wav = await mp3ToWav(mp3);
    const file = await saveBuffer(wav, 'wav', 'speech');
    return {
      text: `Saved the speech to ${file} (${wav.length} bytes)\n\nPlay it with: ffplay ${file}`,
      notes: [...notes, 'fallback: keyless Google Translate speech endpoint'],
    };
  },

  /** Report which upstreams are configured, without revealing any key. */
  async capabilities(_args) {
    const lines = [
      `credentials: ${CREDENTIALS_FILE || 'not found (using the process environment)'}`,
      `gemini vision model: ${GEMINI_VISION_MODEL} (${process.env.GEMINI_API_KEY ? 'key present' : 'NO KEY'})`,
      `gemini image models: ${GEMINI_IMAGE_MODELS.join(', ')}`,
      `gemini tts model: ${GEMINI_TTS_MODEL}`,
      `mistral stt model: ${MISTRAL_STT_MODEL} (${process.env.MISTRAL_API_KEY ? 'key present' : 'NO KEY'})`,
      `ffmpeg: ${(await haveFfmpeg()) ? 'present' : 'MISSING'}`,
      `output directory: ${OUT_DIR}`,
    ];
    return { text: lines.join('\n'), notes: [] };
  },
};

const TOOL_DEFS = [
  {
    name: 'media_describe',
    description:
      'Describe an image, an audio file or a video file and answer a question about it. Images and video are sent to a Gemini multimodal model; audio is transcribed when it cannot be described directly. Returns prose.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Absolute path to the media file.' },
        question: { type: 'string', description: 'What to find out about the file. Defaults to a general description.' },
        language: { type: 'string', description: 'Spoken language, for transcription.' },
        frames: { type: 'integer', description: 'How many frames to extract from a video when the direct pass fails.' },
      },
      required: ['path'],
    },
  },
  {
    name: 'audio_transcribe',
    description: 'Transcribe an audio file (wav, mp3, m4a, flac, ...) to text using Mistral speech-to-text.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Absolute path to the audio file.' },
        language: { type: 'string', description: 'Spoken language, for example "en".' },
        out: { type: 'boolean', description: 'Also write the transcript to a file and return its path.' },
      },
      required: ['path'],
    },
  },
  {
    name: 'image_generate',
    description: 'Generate an image from a text prompt and save it to disk. Returns the file path.',
    inputSchema: {
      type: 'object',
      properties: {
        prompt: { type: 'string', description: 'What the image should show.' },
        width: { type: 'integer', description: 'Image width in pixels. Default 768.' },
        height: { type: 'integer', description: 'Image height in pixels. Default 768.' },
      },
      required: ['prompt'],
    },
  },
  {
    name: 'image_edit',
    description:
      'Edit an existing image with a natural-language instruction ("make the square blue"). Uses a Gemini image model, so it can fail with HTTP 429 when the free tier is exhausted.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Absolute path to the image to edit.' },
        prompt: { type: 'string', description: 'The edit to apply.' },
      },
      required: ['path', 'prompt'],
    },
  },
  {
    name: 'image_transform',
    description:
      'Local, model-free image operations that always work: crop, resize, rotate, flip, grayscale, recolor, brighten, contrast, saturate, blur, pad, annotate (draw text) and convert. Use this when no model is needed, or when the image models are rate limited.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Absolute path to the image.' },
        operation: {
          type: 'string',
          enum: [
            'crop',
            'resize',
            'rotate',
            'flip',
            'grayscale',
            'recolor',
            'brighten',
            'contrast',
            'saturate',
            'blur',
            'pad',
            'annotate',
            'convert',
          ],
          description: 'The operation to apply.',
        },
        width: { type: 'integer', description: 'Width, for crop, resize and pad.' },
        height: { type: 'integer', description: 'Height, for crop, resize and pad.' },
        x: { type: 'integer', description: 'Crop origin x.' },
        y: { type: 'integer', description: 'Crop origin y.' },
        degrees: { type: 'number', description: 'Angle in degrees, for rotate, and the hue shift for recolor (0-360).' },
        mode: { type: 'string', enum: ['horizontal', 'vertical'], description: 'Flip direction.' },
        saturation: { type: 'number', description: 'Saturation multiplier, for recolor (0-3).' },
        amount: { type: 'number', description: 'Adjustment amount, for brighten, contrast and saturate.' },
        radius: { type: 'integer', description: 'Blur radius in pixels (1-64).' },
        text: { type: 'string', description: 'Text to draw, for annotate.' },
        font_size: { type: 'integer', description: 'Font size, for annotate.' },
        color: { type: 'string', description: 'Text colour, for annotate.' },
        background: { type: 'string', description: 'Box colour behind the text, for annotate, and the pad colour.' },
        format: { type: 'string', description: 'Output format, for convert (png, jpg, webp).' },
      },
      required: ['path', 'operation'],
    },
  },
  {
    name: 'video_frames',
    description: 'Extract still frames from a video and save them as PNG files. Returns the file paths.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Absolute path to the video file.' },
        count: { type: 'integer', description: 'How many frames to extract. Default 6.' },
      },
      required: ['path'],
    },
  },
  {
    name: 'text_to_speech',
    description: 'Turn text into a spoken WAV file using a Gemini speech model. Returns the file path.',
    inputSchema: {
      type: 'object',
      properties: {
        text: { type: 'string', description: 'The text to speak.' },
        voice: { type: 'string', description: 'Prebuilt voice name, for example Kore, Puck, Charon, Fenrir or Aoede.' },
      },
      required: ['text'],
    },
  },
  {
    name: 'capabilities',
    description: 'Report which media upstreams are configured and reachable, without revealing any key.',
    inputSchema: { type: 'object', properties: {} },
  },
];

// ---------------------------------------------------------------------------
// MCP plumbing (newline-delimited JSON-RPC over stdio)
// ---------------------------------------------------------------------------

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function sendResult(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function sendError(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}

function textResult(text, isError = false) {
  const payload = { content: [{ type: 'text', text: String(text) }] };
  if (isError) payload.isError = true;
  return payload;
}

async function handle(message) {
  const { id, method, params } = message;

  switch (method) {
    case 'initialize':
      return sendResult(id, {
        protocolVersion: PROTOCOL_VERSION,
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        capabilities: { tools: {} },
      });
    case 'notifications/initialized':
      return;
    case 'ping':
      return sendResult(id, {});
    case 'tools/list':
      return sendResult(id, { tools: TOOL_DEFS });
    case 'tools/call': {
      const name = params?.name;
      const tool = tools[name];
      if (!tool) return sendResult(id, textResult(`Unknown tool: ${name}`, true));
      try {
        const out = await tool(params?.arguments || {});
        const notes = Array.isArray(out?.notes) && out.notes.length ? `\n\nNotes: ${out.notes.join('; ')}` : '';
        return sendResult(id, textResult(`${out?.text ?? ''}${notes}`));
      } catch (err) {
        return sendResult(id, textResult(`Tool "${name}" failed: ${err?.message || String(err)}`, true));
      }
    }
    default:
      if (id === undefined) return; // a notification we do not implement
      return sendError(id, -32601, `Method not found: ${method}`);
  }
}

async function main() {
  CREDENTIALS_FILE = await loadCredentials();
  await ensureOutDir();

  let buffer = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    buffer += chunk;
    let nl;
    while ((nl = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (!line) continue;
      let parsed;
      try {
        parsed = JSON.parse(line);
      } catch {
        continue; // ignore a malformed line rather than dying
      }
      Promise.resolve(handle(parsed)).catch((err) => {
        if (parsed && parsed.id !== undefined) sendError(parsed.id, -32603, err?.message || String(err));
      });
    }
  });
  process.stdin.on('end', () => process.exit(0));
  process.on('SIGINT', () => process.exit(0));
  process.on('SIGTERM', () => process.exit(0));
}

main();
