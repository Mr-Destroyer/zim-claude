# zim-media

An MCP server for the media work Claude Code cannot finish on its own.

Claude Code talks to the zim-claude gateway over the Anthropic `/v1/messages`
API. That path carries images, and it carries audio and video too as long as
the route points at a live multimodal model. What it cannot do is produce a
file: a generated image, an edited image or a spoken track has to exist on
disk before it can be Read, played or handed to another tool. This server
provides those steps, plus the local fallbacks that always work.

It is dependency-free: plain Node, no `npm install`, no lockfile. The MCP
stdio transport is newline-delimited JSON-RPC, which is what the other MCP
servers on this machine speak.

## Running it

```bash
node media/mcp-server.mjs
```

Register it with Claude Code:

```bash
claude mcp add zim-media --scope user -- node /path/to/zim-claude/media/mcp-server.mjs
```

`install.sh` does this for you (see "Installing" below).

## Tools

| Tool | What it does | Upstream |
| --- | --- | --- |
| `media_describe` | Describe an image, audio or video file, or answer a question about it | Gemini multimodal model |
| `audio_transcribe` | Transcribe speech to text | Mistral `voxtral-*-transcribe` |
| `image_generate` | Generate an image from a prompt and save it | keyless image endpoint |
| `image_edit` | Edit an image with a natural-language instruction | Gemini image model, with a local fallback |
| `image_transform` | Local image operations: crop, resize, rotate, flip, grayscale, recolor, brighten, contrast, saturate, blur, pad, annotate, convert | ffmpeg only |
| `video_frames` | Extract still frames from a video | ffmpeg only |
| `text_to_speech` | Turn text into a spoken WAV file | Gemini speech model, with a keyless fallback |
| `capabilities` | Report which upstreams are configured and reachable | — |

### `media_describe`

```json
{"name": "media_describe", "arguments": {"path": "/abs/path/clip.mp4", "question": "What number is on screen?"}}
```

Images and video go straight to the Gemini model as inline data. An audio file
is transcribed with Mistral and the transcript is handed to the model, so a
question about an audio file is answered about its words.

### `audio_transcribe`

```json
{"name": "audio_transcribe", "arguments": {"path": "/abs/path/speech.wav", "language": "en", "out": true}}
```

With `out: true` the transcript is also written to a file and its path is
returned.

### `image_generate`

```json
{"name": "image_generate", "arguments": {"prompt": "a red circle on white", "width": 768, "height": 768}}
```

Uses a keyless image endpoint, so it needs no key. It is rate limited per IP
and answers JPEG. The path is returned, so the result can be Read.

### `image_edit`

```json
{"name": "image_edit", "arguments": {"path": "/abs/path/in.png", "prompt": "make the square blue"}}
```

Needs a Gemini image model. The free tier's image allowance is small and is
often exhausted, so this can legitimately fail with HTTP 429. When the models
are unavailable and the instruction names a single colour, a local ffmpeg hue
shift is applied instead and the result says so in its notes. For any other
edit, use `image_transform` for the local operations, or retry later.

### `image_transform`

```json
{"name": "image_transform", "arguments": {"path": "/abs/path/in.png", "operation": "recolor", "degrees": 240}}
```

Always works, with no quota and no latency. Operations: `crop`, `resize`,
`rotate`, `flip`, `grayscale`, `recolor`, `brighten`, `contrast`, `saturate`,
`blur`, `pad`, `annotate`, `convert`.

### `video_frames`

```json
{"name": "video_frames", "arguments": {"path": "/abs/path/clip.mp4", "count": 6}}
```

Frames are spread over the whole clip: the frame rate comes from the clip's
real duration, so a short clip still yields the requested number of frames.

### `text_to_speech`

```json
{"name": "text_to_speech", "arguments": {"text": "Hello there", "voice": "Kore"}}
```

Prefers a Gemini speech model and returns a WAV file. When the speech model
is rate limited it falls back to a keyless speech endpoint and converts the
answer to WAV, so the tool still returns a playable file. The notes say which
path was taken.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZIM_CLAUDE_ENV_FILE` | `~/claude-source/deepseek-claude` | Credential profile to read |
| `ZIM_CLAUDE_MEDIA_DIR` | `$XDG_DATA_HOME/zim-claude/media` | Where output files are written |
| `ZIM_CLAUDE_GEMINI_VISION_MODEL` | `gemini-3.5-flash-lite` | Model for describing media |
| `ZIM_CLAUDE_GEMINI_IMAGE_MODELS` | `gemini-3-pro-image,gemini-2.5-flash-image,gemini-nano-banana-2.1` | Image models, tried in order |
| `ZIM_CLAUDE_GEMINI_TTS_MODEL` | `gemini-2.5-flash-preview-tts` | Model for speech |
| `ZIM_CLAUDE_MISTRAL_STT_MODEL` | `voxtral-mini-transcribe-3` | Model for transcription |
| `ZIM_CLAUDE_MISTRAL_VISION_MODEL` | `ministral-8b-latest` | Mistral model for images, as a spare |

Credentials come from the same profile the proxy launchers source. The real
process environment wins over the profile, so an exported key overrides the
file. Nothing is hardcoded in this server.

The output directory is created on demand, and holds one file per result.

## Installing

`install.sh` copies the server to the install state directory and registers it
with Claude Code:

```bash
bash install.sh
```

To register it by hand instead:

```bash
claude mcp add zim-media --scope user -- node "$HOME/.local/share/zim-claude/media/mcp-server.mjs"
```
