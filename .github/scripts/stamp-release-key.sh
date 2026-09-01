#!/bin/bash
# Stamp a release-verification key into ReleaseKeys.pinnedKeyHex between the
# STAMP-KEYS markers. Used by the STAGING pipeline to bake a test key into
# staging builds; the PRODUCTION key is committed permanently at the key
# ceremony and never stamped at build time.
#
# Usage: stamp-release-key.sh <keyId> <64-hex-public-key>
set -euo pipefail

KEYID="${1:?usage: stamp-release-key.sh <keyId> <publicKeyHex>}"
PUBHEX="${2:?missing public key hex}"
[[ "$PUBHEX" =~ ^[0-9a-f]{64}$ ]] || { echo "✖ public key must be 64 lowercase hex chars"; exit 1; }
[[ "$KEYID" =~ ^briglia-(cli|ut)-release-v[0-9]+-[0-9a-f]{16}$ ]] || { echo "✖ keyId '$KEYID' has the wrong shape"; exit 1; }

FILE="TelegramConcierge/CLI/ReleaseSigning.swift"
python3 - "$FILE" "$KEYID" "$PUBHEX" <<'PYEOF'
import re, sys
path, key_id, pub_hex = sys.argv[1:4]
source = open(path).read()
pattern = re.compile(
    r"(// STAMP-KEYS-BEGIN.*?\n)(.*?)(\s*// STAMP-KEYS-END)", re.DOTALL)
match = pattern.search(source)
if not match:
    sys.exit("✖ STAMP-KEYS markers not found")
replacement = (
    f'    static let pinnedKeyHex: [(keyId: String, publicKeyHex: String)] = [\n'
    f'        (keyId: "{key_id}",\n'
    f'         publicKeyHex: "{pub_hex}"),\n'
    f'    ]'
)
updated = source[:match.start(2)] + replacement + source[match.end(2):]
open(path, "w").write(updated)
PYEOF
grep -q "$PUBHEX" "$FILE" || { echo "✖ key stamp failed"; exit 1; }
echo "Stamped $KEYID into ReleaseKeys.pinnedKeyHex"
