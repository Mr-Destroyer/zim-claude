<div align="center">

<h1>zim-claude</h1>

<p><strong>Claude Code, pointed at TokenHarbor.</strong></p>

<p>Same flags, same subcommands, same interactive UI as <code>claude</code> —<br>
it just talks to TokenHarbor instead of Anthropic.</p>

<p>
<a href="#install"><img src="https://img.shields.io/badge/platform-Linux%20%C2%B7%20macOS%20%C2%B7%20WSL-2f81f7?style=flat-square" alt="Platform"></a>
<a href="#the-first-run"><img src="https://img.shields.io/badge/API-TokenHarbor-6f42c1?style=flat-square" alt="TokenHarbor"></a>
<a href="#claude-desktop"><img src="https://img.shields.io/badge/Claude%20Desktop-gateway-d97757?style=flat-square" alt="Claude Desktop gateway"></a>
</p>

</div>

---

## What it is

A drop-in replacement for `claude`. Every flag and subcommand passes through untouched:

```bash
zim-claude                                  # interactive session
zim-claude --dangerously-skip-permissions   # any claude flag works
zim-claude -p "explain this function"       # non-interactive
zim-claude mcp list                         # any claude subcommand works
zim-claude mcp add demo -- npx -y some-mcp  # arguments pass through untouched
```

```
  Claude Code  ──▶  tokenharbor.ai  ──▶  upstream
   zim-claude        (Anthropic API)      (model)
```

There is **no local proxy**. TokenHarbor serves the Anthropic Messages API itself
(`POST /v1/messages`), so Claude Code talks to it directly with nothing in between —
no LiteLLM, no virtualenv, no port to manage, and no credential on disk.

### The first run

```bash
$ zim-claude

  [zim-claude] TokenHarbor API key — create one at https://tokenharbor.ai/dashboard/api-keys
  paste it here (input is hidden):

  [zim-claude] free models on tokenharbor.ai
     1) deepseek-v4.1-flash:free   DeepSeek V4.1 Flash
     2) mimo-v2.6-flash:free       MiMo V2.6 Flash
     3) th-rudder                  TH-Rudder
    select 1-3 [1]:

  [zim-claude] model: deepseek-v4.1-flash:free
```

1. **It asks for your API key.** The key is read with echo off, never written to
   disk, and never put on a command line — it is exported into the `claude`
   process only.
2. **It validates the key** against `GET /v1/models`. A rejected key is reported
   and re-asked (up to three times); an unreachable API is a hard error naming the
   host it could not reach.
3. **It lists the free models** and takes a number. Enter accepts the model you
   picked last time. Your choice is remembered in
   `~/.local/share/zim-claude/last-model` — that file holds a model name, never a
   key.
4. **It hands off to `claude`** with `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`
   and `ANTHROPIC_MODEL` set for that process only. Plain `claude` in the same
   shell is unaffected.

Because the key is asked for on every run, nothing in this repo is a secret — and
nothing in this repo is yours to share. To skip the prompt (scripts, CI, or your
own machine), export the key yourself:

```bash
export ZIM_CLAUDE_API_KEY=thk_live_...
zim-claude
```

---

## Install

```bash
git clone <this repo> zim-claude
cd zim-claude
./install.sh
```

That's it. Open a new terminal and run `zim-claude`.

### Requirements

The installer checks for each of these and offers to install anything missing.
**Nothing is installed without you answering `y`.**

| Tool | If missing |
|---|---|
| `bash`, `curl` | required — the installer reports and exits |
| Claude Code (`claude`) | offers `curl -fsSL https://claude.ai/install.sh \| bash` |

That is the whole list. There is no Python, no `pip`, no `litellm`, and no
virtualenv any more.

Claude Code uses Anthropic's official installer rather than `npm install -g`: no
Node dependency, and it sets up the launcher and shell integration itself. It is
run **without sudo** — it installs under `$HOME` and exits with an explicit error
if it detects sudo, so running it under sudo would guarantee failure.

<details>
<summary><b><code>zim-claude: command not found</code> right after installing</b></summary>

The installer is a subprocess and cannot change the `PATH` of the shell that
launched it. A new terminal picks up `~/.local/bin` automatically; to fix the
shell you are already in:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

(`hash -r` will not help — it clears bash's command-lookup cache and never adds a
directory to `PATH`.)

</details>

### What it puts where

| Path | Purpose |
|---|---|
| `~/.local/bin/zim-claude` | the command |
| `~/.local/bin/zim-claude-update.sh` | background self-updater (also runnable by hand) |
| `~/.local/share/zim-claude/media/mcp-server.mjs` | the media MCP server (see [Media](#media)) |
| `~/.local/share/zim-claude/media/README.md` | what that server can do |
| `~/.local/share/zim-claude/media/out/` | files the media server produced |
| `~/.local/share/zim-claude/update.conf` | which checkout and branch the updater tracks |
| `~/.local/share/zim-claude/update.log` | what the updater did, last few hundred KB |
| `~/.local/share/zim-claude/last-model` | the model you picked last time |
| `~/.local/share/zim-claude/` | install state + backups (mode 700) |

Anything it would overwrite is backed up first, under
`~/.local/share/zim-claude/backups/<timestamp>/`.

### Installer flags

```
./install.sh                install
./install.sh --dry-run      print every action, change nothing
./install.sh --uninstall    remove what the installer created
./install.sh --force        overwrite files you have hand-edited (still backs up)
./install.sh --no-rc        don't touch ~/.bashrc
./install.sh --help
```

Re-running `install.sh` is safe and idempotent — it compares file contents and
skips anything already up to date.

`--uninstall` removes the files it installed, but **only if you haven't edited
them**, and never touches your last-model choice.

### Auto-update

`zim-claude` keeps itself current. Each time it starts, it launches
`zim-claude-update.sh` **in the background** and then hands off to `claude`
immediately — the updater can never delay, block or fail a session.

The updater is deliberately conservative:

| Rule | Why |
|---|---|
| At most once an hour | a fetch on every invocation would be noise |
| Locked | two sessions starting at once cannot update together |
| Clean checkout only | a dirty tree is reported and skipped, never stashed |
| Fast-forward only | never `reset`, `force` or merge; a diverged branch is left alone |
| `--no-rc` | no rewriting your shell config |
| Never restarts anything | a running session is untouched |

It only works from a git checkout on a named branch — an unpacked tarball has
nothing to pull from, and the installer records `auto-update: disabled` in that
case. Point it at a different checkout by re-running `./install.sh` from that
checkout.

```bash
zim-claude-update.sh          # update now, ignoring the interval
```

| Variable | Default | Meaning |
|---|---|---|
| `ZIM_CLAUDE_NO_UPDATE` | `0` | set to `1` to never auto-update |
| `ZIM_CLAUDE_UPDATE_INTERVAL` | `3600` | seconds between checks (`0` = every run) |
| `ZIM_CLAUDE_UPDATE_FORCE` | `0` | set to `1` to ignore the interval |
| `ZIM_CLAUDE_UPDATE_TIMEOUT` | `20` | seconds allowed for `git fetch` |

The log is at `~/.local/share/zim-claude/update.log` (rotated at 256 KB). Every
outcome — updated, already current, dirty, diverged, fetch failed — is a line
there.

---

## Configuration

`zim-claude` takes no flags of its own — every argument goes to `claude`.
Configure it through environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `ZIM_CLAUDE_API_KEY` | (asked) | TokenHarbor key; skips the prompt (`TOKENHARBOR_API_KEY` also works) |
| `ZIM_CLAUDE_MODEL` | (picked) | model id; skips the picker |
| `ZIM_CLAUDE_BASE_URL` | `https://tokenharbor.ai` | API base URL |
| `ZIM_CLAUDE_BIN` | `claude` on `PATH` | which claude to run |
| `ZIM_CLAUDE_NO_UPDATE` | `0` | set to `1` to never auto-update |

A scripted run — no terminal, no prompts:

```bash
ZIM_CLAUDE_API_KEY="$TH_KEY" ZIM_CLAUDE_MODEL="deepseek-v4.1-flash:free" \
  zim-claude -p "summarise this diff" --output-format json
```

### What gets exported

| Variable | Value |
|---|---|
| `ANTHROPIC_BASE_URL` | `https://tokenharbor.ai` |
| `ANTHROPIC_AUTH_TOKEN` | your TokenHarbor key (sent as `Authorization: Bearer`) |
| `ANTHROPIC_MODEL` | the model you selected |
| `ANTHROPIC_SMALL_FAST_MODEL` | the same model |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` / `_SONNET_MODEL` / `_OPUS_MODEL` | the same model |
| `ANTHROPIC_API_KEY` | `""` |

The tier variables matter because Claude Code names its background calls and its
`/model` entries after Anthropic tiers. With no proxy to rewrite those names,
`/model sonnet` would ask TokenHarbor for `claude-sonnet-4-5` and get a 404 — so
every tier is pointed at the model you chose.

`ANTHROPIC_API_KEY=""` is load-bearing. Claude Code prefers
`ANTHROPIC_AUTH_TOKEN` (sent as `Authorization: Bearer`) and falls back to
`ANTHROPIC_API_KEY` (`x-api-key`) on a truthiness test, so an empty string means
the auth token wins — and it also clears any real `ANTHROPIC_API_KEY` inherited
from the shell.

---

## Claude Desktop

Claude Desktop ignores `ANTHROPIC_*` environment variables: when it spawns its
embedded agent it *blanks* them and injects its own credentials. It only accepts
a custom endpoint through **Third-Party Inference → Gateway**, and it talks to
that gateway itself — so there is nothing to install for it. Point it straight at
TokenHarbor.

1. **Help → Troubleshooting → Enable Developer Mode**
2. **Claude menu → Developer → Configure Third-Party Inference…**
3. Connection section:

   | Field | Value |
   |---|---|
   | Inference provider | `Gateway` |
   | Gateway base URL | `https://tokenharbor.ai` |
   | Gateway API key | your TokenHarbor key (`thk_…`) |
   | Gateway auth scheme | `bearer` |

4. **Apply Changes** (older builds: *Apply locally*), then **restart Claude
   Desktop**.
5. Add the model under **Custom models**: `deepseek-v4.1-flash:free`.

The model picker only lists ids that look Anthropic-ish, so a free route like
`deepseek-v4.1-flash:free` is filtered out of the list — adding it under **Custom
models** is what makes it selectable. Use whichever free id you prefer:

| Model id | Model |
|---|---|
| `deepseek-v4.1-flash:free` | DeepSeek V4.1 Flash |
| `mimo-v2.6-flash:free` | MiMo V2.6 Flash |
| `th-rudder` | TH-Rudder |

You can confirm the gateway is reachable before touching the app:

```bash
curl -s https://tokenharbor.ai/v1/models \
  -H "Authorization: Bearer $ZIM_CLAUDE_API_KEY" | head -c 300
```

A key mismatch comes back as `{"error":{"message":"Invalid or revoked API key. …
"}}` — that is the key, not the URL. Rotate it at
<https://tokenharbor.ai/dashboard/api-keys>.

> Enabling third-party inference replaces the subscription account path for the
> desktop app. Flip the provider back to default to return to your Claude
> account.

---

## Media

The Anthropic Messages API carries images, and it carries audio and video too,
as long as the route behind it points at a multimodal model. What the API
cannot do is hand you a *file*: a generated image, an edited image or a spoken
track has to exist on disk before it can be Read, played or passed to another
tool.

`install.sh` installs a small MCP server, `zim-media`, that does those steps.
It is dependency-free plain Node — no `npm install`, nothing to build — and it
is registered with Claude Code as `zim-media`.

| Tool | What it does |
|---|---|
| `media_describe` | describe an image, audio or video file, or answer a question about it |
| `audio_transcribe` | transcribe speech to text |
| `image_generate` | generate an image from a prompt and save it |
| `image_edit` | edit an image with a natural-language instruction |
| `image_transform` | local edits: crop, resize, rotate, flip, grayscale, recolor, brighten, contrast, saturate, blur, pad, annotate, convert |
| `video_frames` | extract still frames from a video |
| `text_to_speech` | turn text into a spoken WAV file |
| `capabilities` | report which upstreams are configured and reachable |

Results are written to `~/.local/share/zim-claude/media/out/`, and the tools
report the path, so Claude Code can read the result back.

### Credentials

The server reads provider keys from the same shell profile the proxy launchers
source — `~/.local/share/zim-claude/claude-source/deepseek-claude`, or whatever
`ZIM_CLAUDE_ENV_FILE` points at. The real process environment wins over the
file, so an exported key overrides it. Nothing is hardcoded in the server, and
no key is written to disk by the installer.

Set `ZIM_CLAUDE_ENV_FILE` to point it at a different profile:

```bash
ZIM_CLAUDE_ENV_FILE="$HOME/.config/zim-claude/providers" \
  claude mcp add zim-media --scope user -- node "$HOME/.local/share/zim-claude/media/mcp-server.mjs"
```

The models it uses are configurable too — `ZIM_CLAUDE_GEMINI_VISION_MODEL`,
`ZIM_CLAUDE_GEMINI_IMAGE_MODELS`, `ZIM_CLAUDE_GEMINI_TTS_MODEL`,
`ZIM_CLAUDE_MISTRAL_STT_MODEL` and `ZIM_CLAUDE_MISTRAL_VISION_MODEL`. The
defaults are in `media/README.md`, along with a worked example of each tool.

### What works when a provider is out of quota

`image_edit` and `text_to_speech` prefer a hosted model, and both fall back to
something local when the provider is rate-limited or out of quota: an edit
becomes a local hue shift or transform, and speech becomes a keyless render.
The tool says which path it took, so the answer is never silently worse than
it looks.

---

## Migrating from the LiteLLM version

Earlier releases ran a local LiteLLM proxy in front of Logfare. None of that is
used any more, and `install.sh` cleans it up on the next run:

| Left behind by the old version | What happens |
|---|---|
| `~/.local/bin/start-litellm.sh`, `~/litellm-config.yaml` | removed — but only if you never edited them |
| `~/.local/share/zim-claude/venv/` (a few hundred MB) | removed if this installer built it |
| The four `ANTHROPIC_*` exports in `~/.bashrc` aimed at `localhost` | removed, with a comment left in place |
| `~/claude-source/deepseek-claude` (the old key) | **kept** — it is a credential, so it is reported, never deleted |

A shell aimed at some *other* provider is left completely alone. The `.bashrc`
edit only fires when the exports point at a loopback proxy **and** carry a Logfare
token or a model name this repo shipped. Everything else in the file — aliases,
your own exports, the `PATH` block — is untouched, and a backup is taken first.

Delete the dead credential when you like:

```bash
rm ~/claude-source/deepseek-claude
```

---

## Troubleshooting

**`zim-claude` refuses to start, complaining about an API key.**
This is deliberate. Without a key, Claude Code would silently use whatever
`ANTHROPIC_*` variables your shell already exports — a session against a
different provider, with a different model, and nothing telling you. Create a key
at <https://tokenharbor.ai/dashboard/api-keys>, or export `ZIM_CLAUDE_API_KEY`.

**`TokenHarbor rejected that key (HTTP 401)`.** The key is wrong, revoked, or has
a stray character from a copy-paste. The wrapper strips surrounding whitespace;
rotate the key if it still fails.

**`429` / `Retry-After`.** Free accounts are limited to **60 requests/minute and
1,800 requests/hour** per account (100/min and 3,000/hour per IP). Every tool-call
round trip is its own request, so an agent session burns through them. Claude
Code retries on its own; a paid pass or a wallet top-up removes the request-rate
limit entirely.

**`This call is estimated at about $…, more than half of your $… balance`.**
TokenHarbor pauses a single call that could cost more than half your balance.
Claude Code asks for up to 64,000 output tokens, and the estimate counts all of
them. Either lower the ceiling for the session:

```bash
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=16000
```

or turn the check off for Claude Code with the header TokenHarbor documents:

```bash
export ANTHROPIC_CUSTOM_HEADERS="x-th-confirm-spend: true"
```

**The model I want isn't in the picker.** Only free routes are offered, and only
`…:free` ids plus `th-rudder` count as free. Pin any model you like:

```bash
ZIM_CLAUDE_MODEL=claude-sonnet-5.5 zim-claude
```

If a catalog ever advertises no free route, the wrapper says so and lists
everything instead of refusing to start.

**The picker doesn't appear at all.** `ZIM_CLAUDE_MODEL` is set. Unset it to get
the list back.

**`~/.claude/settings.json` wins over everything.** Claude Code applies a
`settings.json` `env` block *after* inheriting the process environment, so an
`ANTHROPIC_AUTH_TOKEN` there beats the key you just typed. TokenHarbor's own docs
tell you to put a key in that file — if you did, remove it, or every run will use
that key instead of the one you pasted. `install.sh` warns when it finds one.

**`overriding inherited ANTHROPIC_BASE_URL=...`.** Your shell exports a base URL
from somewhere else. `zim-claude` overrides it for its own process only, so plain
`claude` is unaffected. The warning is informational.

**`zim-claude -p "x"` output won't pipe into `jq`.** All of `zim-claude`'s own
diagnostics — including the model menu — go to stderr, so stdout stays clean:

```bash
zim-claude -p "hi" --output-format json 2>/dev/null | jq .
```

---

## Notes for maintainers

**Nothing in this repo is a secret.** Keys are typed at run time and held only in
the `claude` process environment. An earlier version shipped a plaintext token in
`config/token` because a shared upstream key was the whole model; that is gone,
and it should not come back. `tests/run-tests.sh` fails if a key-shaped literal
appears anywhere in the tree.

**The free-model filter is a naming convention, not an API field.** TokenHarbor
advertises free routes as `<model>:free` (`deepseek-v4.1-flash:free`,
`mimo-v2.6-flash:free`) plus `th-rudder`. `GET /v1/models` returns callable ids
only — no pricing — so the suffix is what identifies them. If TokenHarbor changes
that convention the picker falls back to listing every model rather than breaking,
and `is_free_model()` in `scripts/zim-claude` is the one place to update.

**The tier variables are not decoration.** Claude Code 2.x reads
`ANTHROPIC_SMALL_FAST_MODEL` and `ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL`.
Without them, background calls and `/model <tier>` reach TokenHarbor with
Anthropic model names it does not serve. The old proxy hid this by aliasing the
haiku names; with no proxy in the path, the wrapper has to map them itself.

**`ANTHROPIC_API_KEY=""` in the exported environment is load-bearing.** Claude
Code prefers `ANTHROPIC_AUTH_TOKEN` and falls back to `ANTHROPIC_API_KEY` on a
truthiness test. An empty string means the auth token wins, and it also clears a
real `ANTHROPIC_API_KEY` inherited from the shell.

**Prompts read `/dev/tty`, not stdin.** `zim-claude -p x < file` must still be
able to ask for a key on the terminal the user is looking at. When there is no
terminal, a missing key is a hard error with the fix spelled out — never a silent
fallback to whatever the shell exports.

**`scripts/zim-claude` parses no options of its own.** Everything after the
command name belongs to `claude`. Adding a flag here would shadow Claude Code's
own flags, so configuration is environment-only, deliberately.

**`tests/run-tests.sh` drives the interactive prompts through `script(1)`**,
because the wrapper requires a real terminal. Those cases skip (rather than fail)
on a box without `script`.

**Line endings are pinned in `.gitattributes`.** Git for Windows defaults to
`core.autocrlf=true`, which would rewrite the bash scripts on checkout and make
their shebangs unrunnable. The repo is pinned to LF.

**Tests:**

```bash
./tests/run-tests.sh
```

Runs everything against a throwaway sandbox `$HOME`; your real config is never
touched. Covers the installer round-trip, idempotency, the migration from the
LiteLLM-era layout, the key prompt and its failure modes, the free-model picker,
the argument pass-through matrix (spaces, `--`, empty args, newlines),
environment handling, and fail-closed behaviour.
