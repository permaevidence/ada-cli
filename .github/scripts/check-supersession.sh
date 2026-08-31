#!/bin/bash
# Live-channel supersession gate, shared by the credential-free authorize
# job and the publish job's inside-the-lock re-check
# (docs/RELEASE_SIGNING_PLAN.md §7.4): the sequence about to be published
# must be STRICTLY greater than the latest successfully released one, as
# authenticated with the COMMITTED expected public key — never as claimed
# by anything the channel serves. Testable against a fake channel
# (scripts/publisher_selftest.py) via LIVE_ENVELOPE_URL.
#
# Env (required): SEQUENCE (ours), REF_NAME (tag), EXPECTED_PUBKEY (pem path)
# Env (optional): LIVE_ENVELOPE_URL (default: this repo's latest envelope,
#                 needs REPO), BOOTSTRAP_FILE (default .github/BOOTSTRAP_RELEASE),
#                 CHANNEL (default ada-cli)
# Prints the live state; exit 0 = allowed to proceed.
set -euo pipefail

: "${SEQUENCE:?SEQUENCE is required}"
: "${REF_NAME:?REF_NAME is required}"
: "${EXPECTED_PUBKEY:?EXPECTED_PUBKEY is required}"
BOOTSTRAP_FILE="${BOOTSTRAP_FILE:-.github/BOOTSTRAP_RELEASE}"
CHANNEL="${CHANNEL:-ada-cli}"
if [ -z "${LIVE_ENVELOPE_URL:-}" ]; then
    : "${REPO:?REPO is required when LIVE_ENVELOPE_URL is unset}"
    LIVE_ENVELOPE_URL="https://github.com/$REPO/releases/latest/download/manifest.sig.json"
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ "$SEQUENCE" =~ ^[1-9][0-9]*$ ]] || { echo "✖ SEQUENCE '$SEQUENCE' is not a positive integer"; exit 1; }
[ -f "$EXPECTED_PUBKEY" ] || { echo "✖ committed expected public key missing: $EXPECTED_PUBKEY"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if curl -fsSL --max-filesize 131072 -o "$WORK/live.sig.json" "$LIVE_ENVELOPE_URL"; then
    # Anything served that does not authenticate is a hard stop — a
    # tampered or malformed live envelope must never be "treated as absent"
    # and thereby unlock the bootstrap path.
    "$HERE/verify-envelope.sh" "$WORK/live.sig.json" "$EXPECTED_PUBKEY" "$CHANNEL" "$WORK/live-payload.json" || {
        echo "✖ the live envelope does not authenticate against the committed key — refusing"; exit 1; }
    LIVE_SEQ="$(python3 -c "import json;print(json.load(open('$WORK/live-payload.json'))['sequence'])")"
    LIVE_VER="$(python3 -c "import json;print(json.load(open('$WORK/live-payload.json'))['version'])")"
    echo "live release: v$LIVE_VER sequence $LIVE_SEQ"
    [ "$SEQUENCE" -gt "$LIVE_SEQ" ] || {
        echo "✖ superseded: source sequence $SEQUENCE is not greater than live $LIVE_SEQ — publishing nothing"; exit 1; }
    echo "✔ sequence $SEQUENCE supersedes live $LIVE_SEQ"
else
    # One-time bootstrap (§7.4): only the exact audited initial release may
    # proceed without live signed state, and only while the committed
    # bootstrap marker names it. Removed after the first signed release.
    [ -f "$BOOTSTRAP_FILE" ] || {
        echo "✖ no live signed release AND no bootstrap marker — refusing"; exit 1; }
    read -r BOOT_TAG BOOT_SEQ < "$BOOTSTRAP_FILE"
    [ "$REF_NAME" = "$BOOT_TAG" ] && [ "$SEQUENCE" = "$BOOT_SEQ" ] || {
        echo "✖ bootstrap marker names $BOOT_TAG/$BOOT_SEQ, got $REF_NAME/$SEQUENCE"; exit 1; }
    echo "✔ bootstrap release accepted: $BOOT_TAG (sequence $BOOT_SEQ)"
fi
