#!/bin/bash
# Final verification THROUGH THE PUBLIC PATH, in the only sound order
# (docs/RELEASE_SIGNING_PLAN.md §7.5):
#
#   1. fetch the public envelope and AUTHENTICATE it with the COMMITTED
#      expected public key (verify-envelope.sh) — nothing from the channel
#      is parsed for decisions before this;
#   2. require it to be byte-identical to the envelope this run signed;
#   3. take url/size/sha256 from the AUTHENTICATED payload only, pin the URL
#      to this release's asset location, and download with the exact size;
#   4. require the public asset to be byte-identical to the candidate
#      tarball that verify-candidate already checked;
#   5. only then extract and run the public binary — as a functional check
#      (it reports its version and re-verifies the envelope with its pinned
#      key), never as the source of trust.
#
# The earlier shape — parse the unauthenticated envelope, download whatever
# it points at, run THAT binary and ask it whether the envelope verifies —
# would let a forged asset simply answer "yes". Testable against a fake
# release server (scripts/publisher_selftest.py) via RELEASE_BASE_URL.
#
# Env (required): VERSION, SEQUENCE, PLATFORM, EXPECTED_PUBKEY,
#                 CANDIDATE_TARBALL, CANDIDATE_ENVELOPE
# Env (optional): RELEASE_BASE_URL (default https://github.com/$REPO, needs
#                 REPO), ATTEMPTS (default 10), RETRY_SLEEP seconds (30),
#                 CHANNEL (briglia-cli)
set -euo pipefail

: "${VERSION:?VERSION is required}"
: "${SEQUENCE:?SEQUENCE is required}"
: "${PLATFORM:?PLATFORM is required}"
: "${EXPECTED_PUBKEY:?EXPECTED_PUBKEY is required}"
: "${CANDIDATE_TARBALL:?CANDIDATE_TARBALL is required}"
: "${CANDIDATE_ENVELOPE:?CANDIDATE_ENVELOPE is required}"
ATTEMPTS="${ATTEMPTS:-10}"
RETRY_SLEEP="${RETRY_SLEEP:-30}"
CHANNEL="${CHANNEL:-briglia-cli}"
if [ -z "${RELEASE_BASE_URL:-}" ]; then
    : "${REPO:?REPO is required when RELEASE_BASE_URL is unset}"
    RELEASE_BASE_URL="https://github.com/$REPO"
fi
RELEASE_BASE_URL="${RELEASE_BASE_URL%/}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$CANDIDATE_TARBALL" ] || { echo "✖ candidate tarball missing: $CANDIDATE_TARBALL"; exit 1; }
[ -f "$CANDIDATE_ENVELOPE" ] || { echo "✖ candidate envelope missing: $CANDIDATE_ENVELOPE"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Authenticate FIRST. A signature failure is final, not "not yet":
#    the public channel is serving metadata that does not authenticate.
#    Only an authenticated OLDER version (GitHub's latest pointer lags a
#    published release by up to a couple of minutes) retries.
SERVED=""
for attempt in $(seq 1 "$ATTEMPTS"); do
    SERVED=""; NOTE=""
    if curl -fsSL --max-filesize 131072 -o "$WORK/public.sig.json" \
         "$RELEASE_BASE_URL/releases/latest/download/manifest.sig.json"; then
        if "$HERE/verify-envelope.sh" "$WORK/public.sig.json" "$EXPECTED_PUBKEY" "$CHANNEL" "$WORK/payload.json" >/dev/null; then
            SERVED="$(python3 -c "import json;print(json.load(open('$WORK/payload.json'))['version'])")"
            [ "$SERVED" = "$VERSION" ] && break
            NOTE=", authenticated v$SERVED"
        else
            echo "✖ the PUBLIC envelope does not authenticate against the committed key — refusing"; exit 1
        fi
    fi
    echo "…latest does not serve $VERSION yet (attempt $attempt$NOTE)"
    sleep "$RETRY_SLEEP"
done
[ "$SERVED" = "$VERSION" ] || { echo "✖ the public latest path never served an authenticated v$VERSION"; exit 1; }
echo "✔ public envelope authenticates with the committed key (v$VERSION)"

# 2. Exactly the bytes this run signed.
cmp -s "$WORK/public.sig.json" "$CANDIDATE_ENVELOPE" || {
    echo "✖ the public envelope authenticates but is NOT byte-identical to the one this run signed"; exit 1; }
echo "✔ public envelope is byte-identical to the signed candidate"

# 3. Authenticated payload → pinned URL, exact size, sha256.
python3 - "$WORK/payload.json" "$PLATFORM" "$SEQUENCE" "$RELEASE_BASE_URL/releases/download/v$VERSION/" "$WORK" <<'PYEOF'
import json, re, sys
payload_path, platform, sequence, prefix, work = sys.argv[1:6]
p = json.load(open(payload_path))
assert p["sequence"] == int(sequence), f"authenticated sequence {p['sequence']} != expected {sequence}"
entry = p["platforms"][platform]
url, sha, size = entry["url"], entry["sha256"], int(entry["size"])
assert url.startswith(prefix), f"asset url {url} is outside this release's pinned location {prefix}"
name = url[len(prefix):]
assert re.fullmatch(r"[A-Za-z0-9._-]+", name) and ".." not in name, f"asset name {name!r} is not plain"
assert re.fullmatch(r"[0-9a-f]{64}", sha), "sha256 is not 64 lowercase hex"
assert size > 0, "size must be positive"
open(f"{work}/asset-url", "w").write(url)
open(f"{work}/asset-sha", "w").write(sha)
open(f"{work}/asset-size", "w").write(str(size))
PYEOF
ASSET_URL="$(cat "$WORK/asset-url")"; ASSET_SHA="$(cat "$WORK/asset-sha")"; ASSET_SIZE="$(cat "$WORK/asset-size")"
curl -fsSL --max-filesize "$ASSET_SIZE" -o "$WORK/public.tar.gz" "$ASSET_URL" || {
    echo "✖ downloading the public asset failed (or it exceeded the authenticated size)"; exit 1; }
[ "$(wc -c < "$WORK/public.tar.gz" | tr -d ' ')" = "$ASSET_SIZE" ] || {
    echo "✖ public asset size differs from the authenticated size"; exit 1; }
GOT_SHA="$(python3 -c "import hashlib,sys;h=hashlib.sha256()
with open(sys.argv[1],'rb') as f:
    for c in iter(lambda: f.read(1<<20), b''): h.update(c)
print(h.hexdigest())" "$WORK/public.tar.gz")"
[ "$GOT_SHA" = "$ASSET_SHA" ] || { echo "✖ public asset sha256 does not match the authenticated manifest"; exit 1; }
echo "✔ public asset matches the authenticated size and sha256"

# 4. Exactly the artifact verify-candidate checked.
cmp -s "$WORK/public.tar.gz" "$CANDIDATE_TARBALL" || {
    echo "✖ public asset hashes correctly but is NOT byte-identical to the verified candidate tarball"; exit 1; }
echo "✔ public asset is byte-identical to the verified candidate"

# 5. Functional check of the now-authenticated public build.
mkdir "$WORK/extracted"
tar -xzf "$WORK/public.tar.gz" -C "$WORK/extracted"
[ -x "$WORK/extracted/briglia" ] || chmod +x "$WORK/extracted/briglia"
"$WORK/extracted/briglia" --version | grep -qx "$VERSION" || { echo "✖ public binary does not report version $VERSION"; exit 1; }
"$WORK/extracted/briglia" __verify-envelope "$WORK/public.sig.json" \
    --expect-version "$VERSION" --expect-sequence "$SEQUENCE" || {
    echo "✖ the public binary's own pinned-key verifier rejects the envelope"; exit 1; }
echo "✔ end-to-end public verification passed for $PLATFORM (v$VERSION, sequence $SEQUENCE)"
