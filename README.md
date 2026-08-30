# Ada CLI

Ada — a personal AI agent — as a command-line tool. A sibling of the Ada
macOS app sharing its core (agent loop, filesystem/bash/LSP tools, web
research orchestrator, subagents, long-term memory) with no GUI, no legal
databases, and no license-key checks. English throughout. Runs on macOS
and Linux.

## Install (prebuilt — no GitHub account, no Swift)

```sh
curl -fsSL https://ada-app-psi.vercel.app/cli/install.sh | bash
ada setup                   # first-run wizard (~5 minutes)
ada                         # chat; leave with /quit, /exit or Ctrl-C
```

Prebuilt binaries: macOS arm64 (Apple Silicon), Linux x64, Linux arm64.
To update later: `ada upgrade` in a terminal, or send `/upgrade` from
Telegram (or type it in the chat) — Ada downloads the release, verifies it,
swaps itself, and restarts in place, confirming when it's back online.
Remote `/upgrade` needs a user-writable install dir (sudo installs must use
the terminal command). The installer and the updater both verify the
release's SHA-256 checksum before installing.

## Install from source (development)

```sh
git clone https://github.com/permaevidence/ada-cli.git
cd ada-cli
./scripts/install.sh        # builds release + installs the `ada` command
```

To update later: `git pull && ./scripts/install.sh`.

### Linux notes

- Prebuilt binaries need no Swift toolchain (the Swift runtime is statically
  linked); only system `libcurl4` + `libxml2` are required — the installer
  checks and tells you the exact package command if they're missing.
- Building from source instead requires Swift 6+
  (https://www.swift.org/install/linux/ — swiftly is the easiest path).
  `./scripts/install.sh` tells you if it's missing.
- The media pipeline uses **poppler-utils** and **ImageMagick** instead of
  PDFKit/ImageIO — the setup wizard offers to install them (or:
  `sudo apt install poppler-utils imagemagick`). Verify any time with
  `ada media-selftest`.
- Permissions: there is no Full Disk Access on Linux (plain file permissions
  apply). The wizard's permissions step instead checks **automatic suspend** —
  a suspended machine stops Ada — and can disable it via GNOME `gsettings` or
  by masking the systemd sleep targets on headless boxes.
- The `shortcuts` tool and native text-layout PDF generation are macOS-only;
  document generation on Linux goes through the bundled skills (python).

Commands:

| command | |
| --- | --- |
| `ada` / `ada chat` | interactive chat REPL (`/stop`, `/status`, `/prune`, `/attach`, `/quit`) |
| `ada setup` | setup wizard; rerun any single section later. Step 1 can configure SEVERAL main-agent providers (OpenCode Go, OpenRouter, custom endpoint, local server) — hop between them anytime with `/provider <name>` in chat |
| `ada daemon` | headless mode — Telegram channel only. One conversation-owning instance at a time: `ada` and `ada daemon` share state, so the second refuses to start |
| `ada service install` | Linux: systemd user service for the daemon (auto-start at boot via linger; keep-awake support on Ubuntu Touch). `status`/`uninstall` included |
| `ada toolchain` | Linux: install/upgrade/remove the media toolchain (poppler, ImageMagick, ffmpeg, optional LibreOffice/pandoc); userdata prefix on Ubuntu Touch |
| `ada doctor [--online]` | configuration / permissions / toolchain health checks |
| `ada media-selftest` | verify the PDF/image pipeline (poppler/ImageMagick on Linux) |

## Storage

| path | contents |
| --- | --- |
| `~/.config/ada/` | user-editable config: `secrets.json` (0600), `mcp.json`, `mcp-routing.json`, `agents/`, `skills/` |
| `~/.local/share/ada/` | state: conversation, archive, sessions, attachments, logs, projects |
| `~/Documents/AdaCLI/` | landing zone: files Ada receives, downloads or generates for you |

Both are XDG-style and distinct from Ada.app's paths, so the CLI and the app
coexist on the same Mac — and the same paths work unchanged on Linux.

## Scope — intentional omissions

Reviewers: the following are **deliberate design decisions**, not porting
gaps:

- **No Sparkle** — updating is one command: `ada upgrade` in a terminal, or
  `/upgrade` from chat (Telegram or terminal), which also self-restarts.
  `/restart` re-execs in place without updating — the remote way to apply
  configuration that loads at startup (mcp.json, skills).
  Both pull the latest prebuilt release from the CDN, verify its SHA-256,
  and swap the binary + resource bundle in place (source installs:
  `git pull && ./scripts/install.sh`).
- **No local Whisper (WhisperKit)** — voice transcription is cloud-only
  (OpenAI). The `/transcribe_local` command surface is inherited from
  Ada.app and non-functional here.
- **No legal databases, no licensing** — this fork predates and excludes the
  Ada.app legal product surface entirely.
- **No computer-use tools, no GUI** — headless by definition.
- **English only** — Ada.app's Italian localization is intentionally dropped;
  remaining Italian strings are cleanup debt, not a localization effort.
- **File-based secrets, not the macOS Keychain** — a from-source binary gets
  a new code identity every rebuild, so Keychain use means blocking consent
  prompts on every update (and headless runs hang). `secrets.json` (0600) is
  the same posture as `~/.aws/credentials`.
- **WhatsApp deferred** (not deleted) — Telegram is the only channel wired
  into the wizard for now.
- **Service installer is systemd-only** — `ada service install` covers
  Linux (including Ubuntu Touch); a macOS launchd generator is future
  work — run `ada daemon` in a terminal there.

## Development

Read `AGENTS.md` before contributing changes — it records the build/test
commands and the invariants every change must preserve. Security reports:
see `SECURITY.md`.

CI builds and smoke-tests every push on Ubuntu (Swift container) and macOS:
version/doctor checks, the media-selftest, and a full chat turn against a
mock OpenAI-compatible server. Platform seams live in
`TelegramConcierge/Utilities/PlatformCompat.swift` (shell, process signals,
binary lookup) and `PlatformMedia.swift` (AdaPDF + PlatformImage); Linux
swaps CryptoKit → swift-crypto and Combine → OpenCombine via
platform-conditional package dependencies.

## License

Ada CLI is **source-available** (not open source) under the Business
Source License 1.1 — see `LICENSE`. Production use is free for individual
people, including commercial use as a freelancer or sole proprietor;
companies and other entities need a commercial license (contact address in
`LICENSE`). Non-production use — evaluation, development, testing — is
free for everyone. Each released version automatically converts to
Apache-2.0 four years after its release. Third-party components are listed
in `THIRD_PARTY_NOTICES.md`.

External contributions are not being accepted yet while the contribution
policy (CLA) is finalized — bug reports and security reports are very
welcome.
