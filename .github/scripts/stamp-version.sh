#!/bin/bash
# Stamp the release version into the adaCLIVersion constant before building.
# Accepts "v0.1.0" or "0.1.0".
set -euo pipefail
VERSION="${1#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$ ]] || {
    echo "✖ '$VERSION' is not a valid version"; exit 1; }
FILE="TelegramConcierge/CLI/AdaMain.swift"
sed -i.bak "s/^let adaCLIVersion = .*/let adaCLIVersion = \"$VERSION\"/" "$FILE"
rm -f "$FILE.bak"
grep -q "^let adaCLIVersion = \"$VERSION\"$" "$FILE" || {
    echo "✖ version stamp failed — adaCLIVersion line changed shape?"; exit 1; }
echo "Stamped version $VERSION"
