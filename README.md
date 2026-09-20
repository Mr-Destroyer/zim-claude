# zim-claude

Claude Code, pointed at DeepSeek through a local LiteLLM proxy.

`zim-claude` is a drop-in replacement for `claude` — same flags, same subcommands,
same interactive UI — except it talks to a LiteLLM proxy on `localhost:4000`, which
forwards to Token Juice. The proxy starts automatically the first time you use it.

```bash
zim-claude                                  # interactive session
zim-claude --dangerously-skip-permissions   # any claude flag works
zim-claude -p "explain this function"       # non-interactive
zim-claude mcp list                         # any claude subcommand works
zim-claude mcp add demo -- npx -y some-mcp  # arguments pass through untouched
```

## Install

```bash
git clone <this repo> zim-claude
cd zim-claude
./install.sh
```

That's it. Open a new terminal and run `zim-claude`.

### Requirements

The installer checks for these and offers to install anything missing:

| Tool | If missing |
|---|---|
| `bash`, `curl`, `base64` | required, installer reports and exits |
| Claude Code (`claude`) | offers `npm install -g @anthropic-ai/claude-code` |
| `litellm` | offers `pip install --user --break-system-packages 'litellm[proxy]'` |

Nothing is installed without you answering `y`.

### What it puts where

| Path | Purpose |
|---|---|
| `~/.local/bin/zim-claude` | the command |
| `~/.local/bin/start-litellm.sh` | proxy manager: `start`/`stop`/`restart`/`status`/`logs` |
| `~/claude-source/deepseek-claude` | the env profile (mode 600) |
| `~/litellm-config.yaml` | LiteLLM proxy config |
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
./install.sh --start        start the proxy when done
```

Re-running `install.sh` is safe and idempotent — it compares file contents and skips
anything already up to date.

`--uninstall` removes the files it installed, but **only if you haven't edited them**,
and never touches your env profile or `~/litellm-config.yaml`.

## The proxy

`start-litellm.sh` manages it:

```bash
start-litellm.sh status     # is it running?
start-litellm.sh logs       # tail the log
start-litellm.sh restart    # after editing the config
start-litellm.sh stop
```

You normally never need these — `zim-claude` health-checks `localhost:4000` and starts
the proxy if it's down. The check costs ~8 ms when the proxy is already up.

## Configuration

`zim-claude` takes no flags of its own — every argument goes to `claude`. Configure it
through environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `LITELLM_ENV_FILE` | `~/claude-source/deepseek-claude` | profile to source |
| `LITELLM_PORT` | `4000` | proxy port |
| `LITELLM_LOG` | `/tmp/litellm-proxy.log` | proxy log |
| `LITELLM_SERVICE` | `<install dir>/start-litellm.sh` | proxy manager |
| `ZIM_CLAUDE_BIN` | `claude` on `PATH` | which claude to run |
| `ZIM_CLAUDE_NO_PROXY` | `0` | set to `1` to never touch the proxy |
| `ZIM_CLAUDE_REQUIRE_PROXY` | `0` | set to `1` to hard-fail if the proxy is down |

Using a different profile:

```bash
LITELLM_ENV_FILE=~/claude-source/some-other-model zim-claude
```

## Troubleshooting

**`zim-claude` refuses to start, complaining about the env file.**
This is deliberate. Without the profile, Claude Code would silently use whatever
`ANTHROPIC_*` variables your shell already exports — a session against a different
provider, with a different model, and nothing telling you. Re-run `install.sh`, or point
`LITELLM_ENV_FILE` at a real profile.

**It warns `overriding inherited ANTHROPIC_BASE_URL=...`.**
Your shell exports an `ANTHROPIC_BASE_URL` from somewhere else. `zim-claude` overrides it
for its own process only, so plain `claude` is unaffected. The warning is informational.

**The proxy won't start.**
```bash
start-litellm.sh logs
```
The usual causes are the port already being held by a stray process, or a required
environment variable being unset. `start-litellm.sh` verifies that every
`os.environ/<VAR>` referenced by the config is actually set before launching.

**`zim-claude -p "x"` output won't pipe into `jq`.**
All of `zim-claude`'s own diagnostics go to stderr, so stdout stays clean:
```bash
zim-claude -p "hi" --output-format json 2>/dev/null | jq .
```

## Notes for maintainers

**`ANTHROPIC_API_KEY=""` in the profile is load-bearing.** Claude Code prefers
`ANTHROPIC_AUTH_TOKEN` (sent as `Authorization: Bearer`) and falls back to
`ANTHROPIC_API_KEY` (`x-api-key`). The fallback check is a truthiness test, so an empty
string means the auth token wins — and it also clears any real `ANTHROPIC_API_KEY`
inherited from the shell. Deleting that line breaks authentication.

**`scripts/start-litellm.sh` and `config/litellm-config.yaml` ship byte-for-byte
unmodified**, which is why their `$HOME`-relative defaults line up with where the
installer places things. If you edit them, keep them identical to the working originals;
`tests/run-tests.sh` diffs them and fails if they drift. Note that `start-litellm.sh`'s
`help` reads its own header with `sed -n '2,9p'`, so its comment block must stay on
lines 2–9.

**The token ships in plaintext at `config/token`.** This is deliberate. An earlier
revision kept it base64-encoded in `config/.token.b64`, which failed in practice for a
reason that had nothing to do with base64: GitHub's web uploader skips dotfiles, so the
file was never committed, and every fresh clone installed a wrapper with no credential.
Base64 was never protection anyway — `install.sh` had to reverse it, so anyone with the
repo could too.

Treat the repo as containing the credential. If it is ever pushed somewhere public,
rotate the token at Token Juice rather than trying to scrub the history.

`install.sh` still reads `config/.token.b64` if `config/token` is absent, so an older
checkout keeps working.

**Tests:**

```bash
./tests/run-tests.sh
```

Runs everything against a throwaway sandbox `$HOME`; your real config is never touched.
Covers the installer round-trip, idempotency, secret preservation, the argument
pass-through matrix (spaces, `--`, empty args, newlines), environment handling, and
fail-closed behaviour.
