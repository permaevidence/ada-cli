#!/bin/bash
# One-time release key ceremony helper (docs/RELEASE_SIGNING_PLAN.md §4).
# Generates an Ed25519 keypair, derives the keyId from the SHA-256
# fingerprint of the raw 32-byte public key, and writes:
#   <out>/<keyId>.priv.pem   private key, mode 0600 — NEVER commit
#   <out>/<keyId>.pub.pem    public key PEM (committed as the expected key)
#   <out>/<keyId>.json       key record: keyId, fingerprint, created, channel
# Usage: release-keygen.sh <channel: briglia-cli|briglia-ut> <output-dir>
set -euo pipefail

CHANNEL="${1:?usage: release-keygen.sh <briglia-cli|briglia-ut> <output-dir>}"
OUT="${2:?usage: release-keygen.sh <briglia-cli|briglia-ut> <output-dir>}"
case "$CHANNEL" in briglia-cli|briglia-ut) ;; *) echo "✖ channel must be briglia-cli or briglia-ut"; exit 1;; esac

# Ed25519-capable openssl, proven by the RFC 8032 known vector (LibreSSL on
# macOS /usr/bin cannot do Ed25519; OpenSSL 1.1.1 fails pkeyutl -rawin).
# shellcheck source=../.github/scripts/openssl-resolve.sh
. "$(dirname "${BASH_SOURCE[0]}")/../.github/scripts/openssl-resolve.sh"
resolve_openssl || { echo "✖ no Ed25519-capable openssl found (set OPENSSL_BIN)"; exit 1; }

mkdir -p "$OUT"
umask 077
TMP_PRIV="$OUT/.keygen-tmp.pem"
trap 'rm -f "$TMP_PRIV" "$OUT/.keygen-pub.raw"' EXIT
"$OPENSSL" genpkey -algorithm ed25519 -out "$TMP_PRIV"

# Raw 32-byte public key = last 32 bytes of the DER SPKI.
"$OPENSSL" pkey -in "$TMP_PRIV" -pubout -outform DER | tail -c 32 > "$OUT/.keygen-pub.raw"
PUB_HEX="$(ossl_hex "$OUT/.keygen-pub.raw")"
[ "${#PUB_HEX}" -eq 64 ] || { echo "✖ raw public key extraction failed"; exit 1; }
FP="$("$OPENSSL" dgst -sha256 -hex < "$OUT/.keygen-pub.raw" | awk '{print $NF}')"
rm -f "$OUT/.keygen-pub.raw"
KEYID="$CHANNEL-release-v1-${FP:0:16}"

mv "$TMP_PRIV" "$OUT/$KEYID.priv.pem"
trap - EXIT
"$OPENSSL" pkey -in "$OUT/$KEYID.priv.pem" -pubout -out "$OUT/$KEYID.pub.pem"
python3 - "$KEYID" "$CHANNEL" "$PUB_HEX" "$FP" > "$OUT/$KEYID.json" <<'PYEOF'
import json, sys, datetime
print(json.dumps({
    "keyId": sys.argv[1], "channel": sys.argv[2],
    "publicKeyHex": sys.argv[3], "fingerprintSHA256": sys.argv[4],
    "created": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}, indent=2))
PYEOF

echo "Generated $KEYID"
echo "  private: $OUT/$KEYID.priv.pem  (mode 0600 — never commit, never log)"
echo "  public:  $OUT/$KEYID.pub.pem"
echo "  record:  $OUT/$KEYID.json"
echo "  raw public key hex: $PUB_HEX"
echo "Next: pin (keyId, publicKeyHex) in ReleaseKeys.pinnedKeyHex, commit the"
echo ".pub.pem as the expected key, store the .priv.pem per the custody plan."
