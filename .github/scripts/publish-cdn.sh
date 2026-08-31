#!/bin/bash
# Publish built tarballs from dist/ to the Vercel Blob CDN.
#   cli/v<version>/<tarball>            immutable, long cache
#   cli/latest/<tarball> + .sha256      stable aliases the installer fetches
#   cli/manifest.json                   consumed by `ada upgrade`
#   cli/install.sh                      the public curl installer
# Requires: BLOB_TOKEN env var, version as $1 ("v0.1.0" or "0.1.0").
set -euo pipefail
VERSION="${1#v}"
: "${BLOB_TOKEN:?BLOB_TOKEN is required}"
PREFIX="${BLOB_PUBLIC_PREFIX:?BLOB_PUBLIC_PREFIX is required}"
# Upload endpoint override for the fake-Blob publisher tests only.
BLOB_API="${BLOB_API_URL:-https://blob.vercel-storage.com}"

# Supersession guard: release jobs run concurrently (an older tag's slow ARM
# job can finish after a newer release went live) and every publish overwrites
# manifest.json + latest/. Never clobber a NEWER live manifest with an older
# release — exit 0 so the superseded run finishes green instead of failing.
LIVE_VERSION="$(curl -sf "$PREFIX/manifest.json" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])" 2>/dev/null || echo "")"
if [ -n "$LIVE_VERSION" ]; then
    VERDICT="$(python3 - "$LIVE_VERSION" "$VERSION" <<'PYEOF'
import sys
def parse(v):
    try:
        return [int(x) for x in v.split("-")[0].split(".")]
    except ValueError:
        return None
live, mine = parse(sys.argv[1]), parse(sys.argv[2])
if live is None or mine is None:
    print("go")  # unparseable versions: fail open, publish as before
else:
    n = max(len(live), len(mine))
    live += [0] * (n - len(live)); mine += [0] * (n - len(mine))
    print("skip" if live > mine else "go")
PYEOF
)"
    if [ "$VERDICT" = "skip" ]; then
        echo "⚠ CDN already serves $LIVE_VERSION (newer than $VERSION) — this release is superseded; skipping publish."
        exit 0
    fi
fi

# Upload one file to a stable blob pathname (no random suffix, overwrite OK).
blob_put() {
    local file="$1" pathname="$2" maxage="$3" encoded
    encoded="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$pathname")"
    curl -sf -X PUT "$BLOB_API/$encoded" \
        -H "Authorization: Bearer $BLOB_TOKEN" \
        -H "x-api-version: 7" \
        -H "x-add-random-suffix: 0" \
        -H "x-allow-overwrite: 1" \
        -H "x-cache-control-max-age: $maxage" \
        --data-binary "@$file" >/dev/null
    echo "  ↑ $pathname"
}

MANIFEST_PLATFORMS=""
for tarball in dist/ada-*.tar.gz; do
    [ -f "$tarball" ] || continue
    name="$(basename "$tarball")"
    platform="${name#ada-}"; platform="${platform%.tar.gz}"
    sha="$(sha256sum "$tarball" | awk '{print $1}')"
    printf '%s  %s\n' "$sha" "$name" > "dist/$name.sha256"

    blob_put "$tarball"            "cli/v$VERSION/$name"        31536000
    blob_put "dist/$name.sha256"   "cli/v$VERSION/$name.sha256" 31536000
    blob_put "$tarball"            "cli/latest/$name"           300
    blob_put "dist/$name.sha256"   "cli/latest/$name.sha256"    300

    [ -n "$MANIFEST_PLATFORMS" ] && MANIFEST_PLATFORMS="$MANIFEST_PLATFORMS,"
    MANIFEST_PLATFORMS="$MANIFEST_PLATFORMS\"$platform\":{\"url\":\"$PREFIX/v$VERSION/$name\",\"sha256\":\"$sha\"}"
done
[ -n "$MANIFEST_PLATFORMS" ] || { echo "✖ no tarballs found in dist/"; exit 1; }

printf '{"version":"%s","platforms":{%s}}\n' "$VERSION" "$MANIFEST_PLATFORMS" > dist/manifest.json
python3 -c "import json; json.load(open('dist/manifest.json'))"  # sanity
blob_put dist/manifest.json  "cli/manifest.json" 300
blob_put scripts/get-ada.sh  "cli/install.sh"    300

echo "Published Ada CLI $VERSION:"
cat dist/manifest.json
