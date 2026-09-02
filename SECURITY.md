# Security Policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's security advisory
form: on this repository, go to **Security → Report a vulnerability**. Do
not open a public issue for anything you believe is a security problem.

You can expect an acknowledgement within a few days. Please include the
version (`briglia --version`), platform, and reproduction steps.

## Scope

Briglia CLI is an autonomous agent that runs with the permissions of the user
who installs it, by design. Reports we consider in scope include:

- The release/update channel: signature verification, downgrade or
  rollback acceptance, checksum bypasses in `install.sh` or `/upgrade`.
- Prompt-injection paths that let untrusted content (web pages, emails,
  documents, tool output) impersonate the operator or acquire operator
  authority — e.g. defeating the harness-rendered mid-turn user-message
  mechanism.
- Credential handling: secrets leaking into logs, transcripts, tool
  output, exports, or process arguments.
- The app-chat socket, trigger intake, and any other local IPC surface:
  privilege boundaries, peer verification, path traversal.
- Sandbox-relevant parsing: crafted Mind archives, crafted update
  manifests, crafted attachments.

Out of scope: the fact that the agent itself can run shell commands or
modify files when its operator asks it to — that is the product.

## Installation directory

The binary is installed under `~/.local/bin`, which is writable by the
installing user by design: `/upgrade` replaces the binary without `sudo`
and without a privileged helper. Physical or account-level access to that
directory therefore equals update trust — the same trust the signed release
channel protects against network attackers, not against someone already
running as you.

The very first install on a machine without `python3` or `openssl` can only
rely on TLS to fetch the release; every later update verifies the embedded
Ed25519 signature with the key pinned inside the binary. The installer says
so when it runs in that mode.

## Storage permissions

Everything Briglia keeps under `~/.config/briglia` and `~/.local/share/briglia`
is owner-only: both roots are `0700`, files `0600`, directories `0700`
(`projects/` — your own work product — and `toolchain/` are excluded). Every
start re-tightens stragglers, and `briglia doctor` reports anything wider.
This protects against other accounts on the same machine, not against
processes running as you: an MCP server or a command the agent runs can read
whatever the agent can. Before v0.2.5, two places kept activity metadata at
weaker-than-data permissions — the migration engine's `preimages/` and
`parked/` listings and the web-pipeline log; both are owner-only now.

## Browser automation (Playwright)

The `playwright` MCP server that Briglia registers for the Browse subagent is
installed from a lockfile committed with the source
(`Resources/MCPBundles/playwright/package-lock.json`: exact versions and
SHA-512 integrity hashes for every package, no install scripts). Each version
is installed once, with `npm ci --ignore-scripts`, into an immutable
`~/.local/share/briglia/mcp/playwright-<lockfile hash>/` directory, verified
(marker, executable, MCP handshake) before `mcp.json` is switched to it in one
atomic write, and reused on every later start without contacting the
registry. Before v0.2.6 the entry was `npx @playwright/mcp@latest`, which
re-resolved and ran whatever the registry served on every start. Playwright is
updated only by a release that bumps the lockfile; `briglia doctor` reports the
referenced version, unreferenced ones (never deleted automatically) and the
last bootstrap outcome. The browser itself is still downloaded by Playwright's
own installer on first use. Entries you edit by hand are left alone.

## Self-tests and release builds

Release binaries refuse the internal migration-run entry point that the
migration self-test drives itself with, so `__migration-selftest` runs only
on development builds (`swift build`, version `-dev`). The signed release
pipeline proves on the shipped binary that the entry point refuses and that
`briglia migrate --status` and the startup probe still answer. To re-check a
production install, use `briglia migrate --status` and `briglia doctor`.

## Supported versions

Only the latest released version is supported. Fixes ship as a new
release; there are no security backports.
