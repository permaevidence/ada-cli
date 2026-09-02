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

## Supported versions

Only the latest released version is supported. Fixes ship as a new
release; there are no security backports.
