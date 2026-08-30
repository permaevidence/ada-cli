#!/bin/bash
# Build Ada CLI in release mode and install the `ada` command.
# Usage: ./scripts/install.sh            → installs to ~/.local/bin (no sudo;
#                                          /usr/local/bin when run as root)
#        ADA_INSTALL_DIR=/some/bin ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swift >/dev/null 2>&1; then
    echo "✖ Swift toolchain not found."
    case "$(uname -s)" in
        Darwin) echo "  Install Xcode or the Command Line Tools: xcode-select --install" ;;
        Linux)  echo "  Install Swift 6+ via swiftly (recommended): https://www.swift.org/install/linux/"
                echo "  e.g. curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz && tar xzf swiftly-*.tar.gz && ./swiftly init" ;;
    esac
    exit 1
fi

echo "Building Ada CLI (release)…"
swift build -c release

BIN=".build/release/ada"
# SwiftPM puts bundled resources (skills, WhatsApp bridge, toolchain scripts)
# in a separate artifact that MUST travel with the binary — without it the
# installed executable traps (exit 133) on first resource access. The
# artifact name is platform-specific: .bundle on macOS, .resources on Linux.
case "$(uname -s)" in
    Darwin) BUNDLE_NAME="ada-cli_ada.bundle" ;;
    *)      BUNDLE_NAME="ada-cli_ada.resources" ;;
esac
BUNDLE=".build/release/$BUNDLE_NAME"
if [ ! -d "$BUNDLE" ]; then
    echo "✖ build output missing $BUNDLE — SwiftPM layout changed?"
    exit 1
fi
# User-writable default: Ada self-updates (remote /upgrade from Telegram),
# and a root-owned install would make every upgrade need a sudo password.
if [ -n "${ADA_INSTALL_DIR:-}" ]; then
    DEST_DIR="$ADA_INSTALL_DIR"
elif [ "$(id -u)" = "0" ]; then
    DEST_DIR="/usr/local/bin"
else
    DEST_DIR="$HOME/.local/bin"
fi
mkdir -p "$DEST_DIR" 2>/dev/null || true

if [ -w "$DEST_DIR" ]; then
    cp "$BIN" "$DEST_DIR/ada"
    rm -rf "${DEST_DIR:?}/$BUNDLE_NAME"
    cp -R "$BUNDLE" "$DEST_DIR/$BUNDLE_NAME"
else
    echo "Installing to $DEST_DIR (may ask for your password)…"
    sudo cp "$BIN" "$DEST_DIR/ada"
    sudo rm -rf "${DEST_DIR:?}/$BUNDLE_NAME"
    sudo cp -R "$BUNDLE" "$DEST_DIR/$BUNDLE_NAME"
fi

echo "Installed: $DEST_DIR/ada"
"$DEST_DIR/ada" --version
# Smoke-test the INSTALLED copy from a neutral cwd so it cannot lean on the
# build directory: verifies the resource bundle deployed correctly.
(cd / && "$DEST_DIR/ada" bundle-check)
case ":$PATH:" in
    *":$DEST_DIR:"*) ;;
    *) echo "⚠ $DEST_DIR is not in your PATH — add it to your shell profile." ;;
esac
