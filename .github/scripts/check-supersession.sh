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
#                 needs REPO),
#                 CHANNEL (default briglia-cli)
# Prints the live state; exit 0 = allowed to proceed.
set -euo pipefail

: "${SEQUENCE:?SEQUENCE is required}"
: "${REF_NAME:?REF_NAME is required}"
: "${EXPECTED_PUBKEY:?EXPECTED_PUBKEY is required}"
CHANNEL="${CHANNEL:-briglia-cli}"
if [ -z "${LIVE_ENVELOPE_URL:-}" ]; then
    : "${REPO:?REPO is required when LIVE_ENVELOPE_URL is unset}"
    LIVE_ENVELOPE_URL="https://github.com/$REPO/releases/latest/download/manifest.sig.json"
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ "$SEQUENCE" =~ ^[1-9][0-9]*$ ]] || { echo "✖ SEQUENCE '$SEQUENCE' is not a positive integer"; exit 1; }
[ -f "$EXPECTED_PUBKEY" ] || { echo "✖ committed expected public key missing: $EXPECTED_PUBKEY"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Legacy-transition descriptor (RENAME_PLAN.md §3.2): see legacy-transition.sh.
# The old channel's envelope is accepted as the supersession floor ONLY when
# it authenticates under that compiled descriptor AND our sequence is
# strictly greater. No environment override, no bypass flag; the helper and
# this call site are deleted in the follow-up commit after the first Briglia
# release.
# shellcheck source=legacy-transition.sh
. "$HERE/legacy-transition.sh"

if curl -fsSL --max-filesize 131072 -o "$WORK/live.sig.json" "$LIVE_ENVELOPE_URL"; then
    # Anything served that does not authenticate is a hard stop — a
    # tampered or malformed live envelope must never be "treated as absent".
    if "$HERE/verify-envelope.sh" "$WORK/live.sig.json" "$EXPECTED_PUBKEY" "$CHANNEL" "$WORK/live-payload.json"; then
        LIVE_KIND="current"
    elif legacy_live_authenticates "$WORK/live.sig.json" "$EXPECTED_PUBKEY" "$WORK/live-payload.json"; then
        LIVE_KIND="legacy"
    else
        echo "✖ the live envelope does not authenticate against the committed key (neither as $CHANNEL nor as the legacy $LEGACY_CHANNEL descriptor) — refusing"; exit 1
    fi
    LIVE_SEQ="$(python3 -c "import json;print(json.load(open('$WORK/live-payload.json'))['sequence'])")"
    LIVE_VER="$(python3 -c "import json;print(json.load(open('$WORK/live-payload.json'))['version'])")"
    [[ "$LIVE_SEQ" =~ ^[1-9][0-9]*$ ]] || { echo "✖ live sequence '$LIVE_SEQ' is not a positive integer"; exit 1; }
    if [ "$LIVE_KIND" = "legacy" ]; then
        echo "live release: v$LIVE_VER sequence $LIVE_SEQ (LEGACY $LEGACY_CHANNEL envelope — pre-rename channel state)"
    else
        echo "live release: v$LIVE_VER sequence $LIVE_SEQ"
    fi
    [ "$SEQUENCE" -gt "$LIVE_SEQ" ] || {
        echo "✖ superseded: source sequence $SEQUENCE is not greater than live $LIVE_SEQ — publishing nothing"; exit 1; }
    echo "✔ sequence $SEQUENCE supersedes live $LIVE_SEQ"
else
    # Fail closed forever. The one-time bootstrap that let the audited
    # v0.1.58 publish without live signed state was retired the moment that
    # release was verified live; every later release must supersede an
    # authenticated live envelope. If the live channel is ever gone (release
    # deleted, outage), publishing waits — it never restarts from nothing.
    echo "✖ no authenticated live signed release reachable at $LIVE_ENVELOPE_URL — refusing (bootstrap retired after v0.1.58)"; exit 1
fi
