#!/bin/bash
# Verify a signed release envelope with the COMMITTED expected public key —
# stdlib python + openssl only, so credential-free workflow jobs (authorize,
# supersession) and the Phase E watcher can authenticate live channel state
# without trusting anything served by the channel itself.
#
# Usage: verify-envelope.sh <manifest.sig.json> <expected-pub.pem> <channel> [payload-out]
# On success prints "VERIFIED keyId=<id>" and writes the authenticated
# payload bytes to payload-out (when given). Any failure exits nonzero.
set -euo pipefail

ENVELOPE="${1:?usage: verify-envelope.sh <manifest.sig.json> <pub.pem> <channel> [payload-out]}"
PUB="${2:?missing expected public key PEM}"
CHANNEL="${3:?missing channel}"
PAYLOAD_OUT="${4:-}"
# shellcheck source=openssl-resolve.sh
. "$(dirname "${BASH_SOURCE[0]}")/openssl-resolve.sh"
resolve_openssl

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Size bound before parsing anything (128 KiB, mirrors the client).
SIZE="$(wc -c < "$ENVELOPE")"
[ "$SIZE" -le 131072 ] || { echo "✖ envelope is $SIZE bytes (limit 131072)"; exit 1; }

# Parse strictly with stdlib python; write payload/signature/keyId out.
KEYID="$(python3 - "$ENVELOPE" "$CHANNEL" "$WORK" <<'PYEOF'
import base64, json, sys
envelope_path, channel, work = sys.argv[1:4]
raw = open(envelope_path, "rb").read()
try:
    env = json.loads(raw.decode("utf-8"))
except Exception:
    sys.exit("✖ envelope is not valid JSON")
if not isinstance(env, dict):
    sys.exit("✖ envelope is not a JSON object")
for field in ("format", "channel", "keyId", "payload", "signature"):
    if not isinstance(env.get(field), str):
        sys.exit(f"✖ envelope field '{field}' missing or not a string")
if env["format"] != "ada-release-envelope-v1":
    sys.exit(f"✖ unsupported format {env['format']!r}")
if env["channel"] != channel:
    sys.exit(f"✖ wrong channel {env['channel']!r}")
def strict_b64(value, name):
    try:
        decoded = base64.b64decode(value, validate=True)
    except Exception:
        sys.exit(f"✖ field '{name}' is not valid base64")
    if base64.b64encode(decoded).decode() != value:
        sys.exit(f"✖ field '{name}' is not canonical base64")
    return decoded
payload = strict_b64(env["payload"], "payload")
signature = strict_b64(env["signature"], "signature")
if len(payload) > 65536:
    sys.exit(f"✖ payload is {len(payload)} bytes (limit 65536)")
if len(signature) != 64:
    sys.exit(f"✖ signature is {len(signature)} bytes, not 64")
open(f"{work}/payload", "wb").write(payload)
open(f"{work}/sig", "wb").write(signature)
domain = b"ada-release-envelope-v1\0" + env["channel"].encode() + b"\0" + env["keyId"].encode() + b"\0"
open(f"{work}/input", "wb").write(domain + payload)
print(env["keyId"])
PYEOF
)"

# keyId must match the committed public key's fingerprint (defends against a
# valid signature published under a mislabeled keyId).
PUB_RAW_FP="$("$OPENSSL" pkey -pubin -in "$PUB" -pubout -outform DER | tail -c 32 | "$OPENSSL" dgst -sha256 -hex | awk '{print $NF}')"
EXPECTED_SUFFIX="${PUB_RAW_FP:0:16}"
case "$KEYID" in
    "$CHANNEL-release-v"*"-$EXPECTED_SUFFIX") ;;
    *) echo "✖ keyId '$KEYID' does not match the committed key fingerprint ($EXPECTED_SUFFIX)"; exit 1;;
esac

"$OPENSSL" pkeyutl -verify -rawin -pubin -inkey "$PUB" \
    -in "$WORK/input" -sigfile "$WORK/sig" >/dev/null 2>&1 || {
    echo "✖ SIGNATURE VERIFICATION FAILED"; exit 1; }

if [ -n "$PAYLOAD_OUT" ]; then
    cp "$WORK/payload" "$PAYLOAD_OUT"
fi
echo "VERIFIED keyId=$KEYID"
