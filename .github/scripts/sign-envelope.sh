#!/bin/bash
# Sign a release manifest into the domain-separated envelope
# (docs/RELEASE_SIGNING_PLAN.md §5). Runs in the release-sign job with the
# private key materialized in a mode-0600 temp file, and locally for staging.
#
# Usage: sign-envelope.sh <private-key.pem> <channel> <manifest.json> <out.sig.json>
# Env:   EXPECTED_PUBKEY_PEM  path to the committed expected public key —
#                             signing REFUSES if the private key derives a
#                             different public key (wrong-key guard, §4.1).
#        OPENSSL_BIN          openssl override (must pass the known-vector probe)
#
# Signature input: "ada-release-envelope-v1\0" + channel + "\0" + keyId + "\0"
# followed by the EXACT manifest bytes. No JSON canonicalization anywhere.
set -euo pipefail

PRIV="${1:?usage: sign-envelope.sh <priv.pem> <channel> <manifest.json> <out.sig.json>}"
CHANNEL="${2:?missing channel}"
MANIFEST="${3:?missing manifest.json}"
OUT="${4:?missing output path}"
: "${EXPECTED_PUBKEY_PEM:?EXPECTED_PUBKEY_PEM is required (committed expected public key)}"
case "$CHANNEL" in ada-cli|ada-ut) ;; *) echo "✖ channel must be ada-cli or ada-ut"; exit 1;; esac
[ -f "$MANIFEST" ] || { echo "✖ manifest not found: $MANIFEST"; exit 1; }

# Resolve an openssl PROVEN against the RFC 8032 TEST 2 vector (sign +
# verify + tamper-reject) before it ever touches the release key — see
# openssl-resolve.sh. No xxd anywhere: the Swift CI container lacks it.
# shellcheck source=openssl-resolve.sh
. "$(dirname "${BASH_SOURCE[0]}")/openssl-resolve.sh"
resolve_openssl
"$OPENSSL" version
echo "✔ known-vector check passed"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Wrong-key guard: the private key must derive the committed public key.
"$OPENSSL" pkey -in "$PRIV" -pubout -outform DER > "$WORK/derived.der"
"$OPENSSL" pkey -pubin -in "$EXPECTED_PUBKEY_PEM" -pubout -outform DER > "$WORK/expected.der"
cmp -s "$WORK/derived.der" "$WORK/expected.der" || {
    echo "✖ private key derives a DIFFERENT public key than the committed expected key — refusing"; exit 1; }
tail -c 32 "$WORK/derived.der" > "$WORK/pub.raw"
PUB_HEX="$(ossl_hex "$WORK/pub.raw")"
FP="$(tail -c 32 "$WORK/derived.der" | "$OPENSSL" dgst -sha256 -hex | awk '{print $NF}')"
KEYID="$CHANNEL-release-v1-${FP:0:16}"
echo "✔ key check passed: $KEYID"

# --- Build the domain-separated input and sign the exact manifest bytes.
printf 'ada-release-envelope-v1\0%s\0%s\0' "$CHANNEL" "$KEYID" > "$WORK/input"
cat "$MANIFEST" >> "$WORK/input"
"$OPENSSL" pkeyutl -sign -rawin -inkey "$PRIV" -in "$WORK/input" -out "$WORK/sig.bin"

# Self-verify before emitting anything.
"$OPENSSL" pkey -pubin -in "$EXPECTED_PUBKEY_PEM" -out "$WORK/pub.pem"
"$OPENSSL" pkeyutl -verify -rawin -pubin -inkey "$WORK/pub.pem" \
    -in "$WORK/input" -sigfile "$WORK/sig.bin" >/dev/null || {
    echo "✖ self-verification of the fresh signature FAILED — refusing to publish"; exit 1; }

python3 - "$MANIFEST" "$WORK/sig.bin" "$CHANNEL" "$KEYID" "$OUT" <<'PYEOF'
import base64, json, sys
manifest_path, sig_path, channel, key_id, out_path = sys.argv[1:6]
payload = open(manifest_path, "rb").read()
signature = open(sig_path, "rb").read()
assert len(signature) == 64, f"signature is {len(signature)} bytes"
envelope = {
    "format": "ada-release-envelope-v1",
    "channel": channel,
    "keyId": key_id,
    "payload": base64.b64encode(payload).decode(),
    "signature": base64.b64encode(signature).decode(),
}
with open(out_path, "w") as f:
    json.dump(envelope, f, separators=(",", ":"))
PYEOF

echo "✔ signed envelope written: $OUT (keyId $KEYID)"
