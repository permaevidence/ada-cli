#!/bin/bash
# Publish ONE immutable GitHub Release for a tag: assemble a draft, upload
# every asset with the signed envelope LAST, then flip the draft live in a
# single PATCH with explicit make_latest (docs/RELEASE_SIGNING_PLAN.md §6.2).
# Extracted from the workflow so the fake-Releases-API tests (§11.3,
# scripts/publisher_selftest.py) exercise the exact production logic.
#
# Env (required): GH_TOKEN, REPO (owner/name), REF_NAME (tag), VERSION
# Env (optional): DIST (default dist), INSTALLER (default scripts/get-ada.sh),
#                 GH_API_URL (default https://api.github.com),
#                 GH_UPLOADS_URL (default https://uploads.github.com)
#
# Exit 0 only when the release is CONFIRMED published (re-read from the API,
# draft=false). A publish PATCH that fails ambiguously is re-checked: if the
# release is live it is reported as such; if it is still a draft that is a
# reported failure and the draft is left for the next run's cleanup.
# The token is only ever placed in a request header, never echoed.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"
: "${REF_NAME:?REF_NAME is required}"
: "${VERSION:?VERSION is required}"
DIST="${DIST:-dist}"
INSTALLER="${INSTALLER:-scripts/get-ada.sh}"
API="${GH_API_URL:-https://api.github.com}"
UPLOADS="${GH_UPLOADS_URL:-https://uploads.github.com}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# curl wrapper: never fails the script by itself; returns the HTTP status in
# $STATUS and the body in $BODY_FILE. A transport failure yields STATUS=000.
api() {
    local method="$1" url="$2"; shift 2
    BODY_FILE="$WORK/body.$$.$RANDOM"
    STATUS="$(curl -sS -o "$BODY_FILE" -w '%{http_code}' -X "$method" \
        -H "Authorization: Bearer $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "$@" "$url" 2>/dev/null || echo 000)"
}
jget() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v=v[k]
print(v)' "$1" "$2"; }

# 1. A PUBLISHED release for this tag is immutable — republish is a hard
#    error, never a retry loop. (This endpoint never returns drafts.)
api GET "$API/repos/$REPO/releases/tags/$REF_NAME"
case "$STATUS" in
    200) echo "✖ a published release for $REF_NAME already exists — immutability forbids republish; cut a new version"; exit 1;;
    404) ;;
    *)   echo "✖ cannot determine whether $REF_NAME is already published (HTTP $STATUS) — refusing to guess"; exit 1;;
esac

# 2. Stale DRAFTS from a previously failed run are not immutable — remove
#    them so retries are idempotent.
page=1
while :; do
    api GET "$API/repos/$REPO/releases?per_page=100&page=$page"
    [ "$STATUS" = "200" ] || { echo "✖ listing releases failed (HTTP $STATUS)"; exit 1; }
    STALE="$(python3 -c 'import json,sys
rel=json.load(open(sys.argv[1])); tag=sys.argv[2]
print("\n".join(str(r["id"]) for r in rel if r.get("draft") and r.get("tag_name")==tag))
print("MORE" if len(rel)==100 else "END", file=sys.stderr)' "$BODY_FILE" "$REF_NAME" 2>"$WORK/more")"
    for stale in $STALE; do
        echo "deleting stale draft $stale"
        api DELETE "$API/repos/$REPO/releases/$stale"
        [ "$STATUS" = "204" ] || { echo "✖ deleting stale draft $stale failed (HTTP $STATUS)"; exit 1; }
    done
    [ "$(cat "$WORK/more")" = "MORE" ] || break
    page=$((page + 1))
done

# 3. Create the draft and address it by ID from here on (a draft cannot be
#    resolved by tag).
python3 -c 'import json,sys
print(json.dumps({"tag_name": sys.argv[1], "draft": True, "name": "Ada CLI " + sys.argv[2],
  "body": "Signed release " + sys.argv[2] + ". Clients authenticate manifest.sig.json with the pinned Ed25519 key before trusting any asset."}))' \
    "$REF_NAME" "$VERSION" > "$WORK/create.json"
api POST "$API/repos/$REPO/releases" -H "Content-Type: application/json" --data-binary @"$WORK/create.json"
[ "$STATUS" = "201" ] || { echo "✖ creating the draft release failed (HTTP $STATUS)"; exit 1; }
RELEASE_ID="$(jget "$BODY_FILE" id)"
[ "$(jget "$BODY_FILE" draft)" = "True" ] || { echo "✖ created release is not a draft — refusing to continue"; exit 1; }
echo "draft release $RELEASE_ID created for $REF_NAME"

# 4. Assets first, the signed envelope LAST — stable metadata cannot precede
#    what it describes even inside the draft. The public installer ships as
#    `install.sh` (byte-identical to the repo's get-ada.sh).
upload() {
    local file="$1" name
    name="$(basename "$file")"
    [ -f "$file" ] || { echo "✖ asset missing: $file"; exit 1; }
    api POST "$UPLOADS/repos/$REPO/releases/$RELEASE_ID/assets?name=$name" \
        -H "Content-Type: application/octet-stream" --data-binary @"$file"
    [ "$STATUS" = "201" ] || {
        echo "✖ uploading $name failed (HTTP $STATUS) — draft $RELEASE_ID left unpublished; the old release stays latest"; exit 1; }
    echo "  ↑ $name"
}
mkdir -p "$WORK/installer"
cp "$INSTALLER" "$WORK/installer/install.sh"
for asset in "$DIST/ada-macos-arm64.tar.gz" "$DIST/ada-linux-x64.tar.gz" "$DIST/ada-linux-arm64.tar.gz" \
             "$DIST/ada-macos-arm64.tar.gz.sha256" "$DIST/ada-linux-x64.tar.gz.sha256" "$DIST/ada-linux-arm64.tar.gz.sha256" \
             "$DIST/manifest.json" "$WORK/installer/install.sh"; do
    upload "$asset"
done
upload "$DIST/manifest.sig.json"

# 5. Atomic go-live; immutability locks at this moment. make_latest is
#    explicit (§6.2) — never GitHub's default.
api PATCH "$API/repos/$REPO/releases/$RELEASE_ID" -H "Content-Type: application/json" \
    --data-binary '{"draft":false,"make_latest":"true"}'
PATCH_STATUS="$STATUS"

# 6. Confirm from the API, whatever the PATCH said: only an observed
#    draft=false is success. (A PATCH can time out AFTER GitHub applied it.)
api GET "$API/repos/$REPO/releases/$RELEASE_ID"
if [ "$STATUS" = "200" ] && [ "$(jget "$BODY_FILE" draft)" = "False" ] \
   && [ "$(jget "$BODY_FILE" tag_name)" = "$REF_NAME" ]; then
    if [ "$PATCH_STATUS" != "200" ]; then
        echo "⚠ publish PATCH answered HTTP $PATCH_STATUS but the release IS published (confirmed by re-read)"
    fi
    echo "✔ published immutable release $REF_NAME (id $RELEASE_ID)"
    exit 0
fi
echo "✖ draft publication FAILED (PATCH HTTP $PATCH_STATUS, re-read HTTP $STATUS) — release $RELEASE_ID remains a draft; the old release stays latest"
exit 1
