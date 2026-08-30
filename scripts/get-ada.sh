#!/bin/bash
# Public Ada CLI installer — prebuilt binaries, no GitHub account, no Swift.
#
#   curl -fsSL https://ada-app-psi.vercel.app/cli/install.sh | bash
#   wget -qO-  https://ada-app-psi.vercel.app/cli/install.sh | bash   (no curl)
#
# Downloads the prebuilt tarball for this OS/arch from the Ada release CDN,
# verifies its SHA-256, and installs `ada` + its resource bundle.
#   ADA_INSTALL_DIR=/some/bin      install location. Default: ~/.local/bin
#                                  (user-writable, so remote /upgrade from
#                                  Telegram never needs a sudo password);
#                                  /usr/local/bin when running as root.
#   ADA_BASE_URL=…                 alternate release CDN (testing)
#
# This script is published to the CDN by .github/workflows/release.yml;
# scripts/get-ada.sh in the repo is the source of truth. Artifacts download
# straight from the Blob CDN (not proxied through the website) — only this
# script's memorable URL lives on the ada domain.
set -euo pipefail

BASE_URL="${ADA_BASE_URL:-https://z3hrivnareyralos.public.blob.vercel-storage.com/cli}"

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS-$ARCH" in
    Darwin-arm64)           PLATFORM="macos-arm64";  BUNDLE_NAME="ada-cli_ada.bundle" ;;
    Darwin-x86_64)
        echo "✖ Intel Macs are not supported yet — Ada CLI ships for Apple Silicon (M1+)."
        exit 1 ;;
    Linux-x86_64)           PLATFORM="linux-x64";    BUNDLE_NAME="ada-cli_ada.resources" ;;
    Linux-aarch64|Linux-arm64) PLATFORM="linux-arm64"; BUNDLE_NAME="ada-cli_ada.resources" ;;
    *)
        echo "✖ Unsupported platform: $OS $ARCH"
        exit 1 ;;
esac

# curl when available, wget otherwise (Ubuntu Touch and other minimal
# systems ship wget but no curl — and their tiny read-only root fs makes
# "just apt install curl" a trap, so the installer must not require it).
if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fSL --retry 3 -o "$1" "$2"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -q -O "$1" "$2"; }
else
    echo "✖ Neither curl nor wget is available — one of them is required."
    exit 1
fi
command -v tar  >/dev/null 2>&1 || { echo "✖ tar is required.";  exit 1; }

# The prebuilt Linux binary statically links the Swift runtime but still
# needs the system's libcurl and libxml2 (Foundation's networking/XML).
if [ "$OS" = "Linux" ]; then
    missing=""
    if command -v ldconfig >/dev/null 2>&1; then
        ldconfig -p 2>/dev/null | grep -q 'libcurl\.so\.4'  || missing="$missing libcurl4"
        ldconfig -p 2>/dev/null | grep -q 'libxml2\.so\.2'  || missing="$missing libxml2"
    fi
    if [ -n "$missing" ]; then
        echo "✖ Missing system libraries:$missing"
        if command -v apt-get >/dev/null 2>&1; then
            # On systems with a tiny root filesystem (e.g. Ubuntu Touch's
            # ~3 GB read-only image) `apt update` alone can fill the disk.
            ROOT_FREE_KB="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
            if [ -n "${ROOT_FREE_KB:-}" ] && [ "$ROOT_FREE_KB" -lt 512000 ] 2>/dev/null; then
                echo "  ⚠ Your root filesystem has <500 MB free — 'apt update' may fill it."
                echo "    Clean up afterwards with: sudo rm -rf /var/lib/apt/lists/* && sudo apt-get clean"
            fi
            echo "  Install them with: sudo apt-get install -y$missing"
        elif command -v dnf >/dev/null 2>&1; then
            echo "  Install them with: sudo dnf install -y libcurl libxml2"
        elif command -v pacman >/dev/null 2>&1; then
            echo "  Install them with: sudo pacman -S curl libxml2"
        fi
        echo "  Then re-run this installer."
        exit 1
    fi
fi

TARBALL="ada-$PLATFORM.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Ada CLI ($PLATFORM)…"
fetch "$TMP/$TARBALL"        "$BASE_URL/latest/$TARBALL"
fetch "$TMP/$TARBALL.sha256" "$BASE_URL/latest/$TARBALL.sha256"

echo "Verifying checksum…"
EXPECTED="$(awk '{print $1}' "$TMP/$TARBALL.sha256")"
if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "$TMP/$TARBALL" | awk '{print $1}')"
else
    ACTUAL="$(shasum -a 256 "$TMP/$TARBALL" | awk '{print $1}')"
fi
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "✖ Checksum mismatch — download corrupted or tampered with. Aborting."
    exit 1
fi

tar -xzf "$TMP/$TARBALL" -C "$TMP"
[ -f "$TMP/ada" ] && [ -d "$TMP/$BUNDLE_NAME" ] || {
    echo "✖ Unexpected tarball layout — expected ada + $BUNDLE_NAME."
    exit 1
}

# Default to a user-writable location: Ada self-updates (remote /upgrade
# from Telegram), and a root-owned install would make every upgrade need a
# sudo password typed at a real keyboard. Root installs keep /usr/local/bin.
if [ -n "${ADA_INSTALL_DIR:-}" ]; then
    DEST_DIR="$ADA_INSTALL_DIR"
elif [ "$(id -u)" = "0" ]; then
    DEST_DIR="/usr/local/bin"
else
    DEST_DIR="$HOME/.local/bin"
fi

# A leftover root-owned install would shadow the new one in most PATHs.
if [ "$DEST_DIR" != "/usr/local/bin" ] && [ -e "/usr/local/bin/ada" ]; then
    echo "⚠ An older Ada install exists at /usr/local/bin/ada and may shadow this one."
    echo "  Remove it with:  sudo rm -rf /usr/local/bin/ada /usr/local/bin/$BUNDLE_NAME"
fi

mkdir -p "$DEST_DIR" 2>/dev/null || true
if [ -w "$DEST_DIR" ]; then
    SUDO=""
else
    echo "Installing to $DEST_DIR (may ask for your password)…"
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
        sudo mkdir -p "$DEST_DIR"
    else
        echo "✖ $DEST_DIR is not writable and sudo is unavailable."
        echo "  Re-run with: ADA_INSTALL_DIR=\$HOME/.local/bin"
        exit 1
    fi
fi
$SUDO install -m 755 "$TMP/ada" "$DEST_DIR/ada"
$SUDO rm -rf "${DEST_DIR:?}/$BUNDLE_NAME"
$SUDO cp -R "$TMP/$BUNDLE_NAME" "$DEST_DIR/$BUNDLE_NAME"

echo "Installed: $DEST_DIR/ada"
"$DEST_DIR/ada" --version
# Smoke-test the installed copy from a neutral cwd (catches a missing bundle).
(cd / && "$DEST_DIR/ada" bundle-check)

ON_PATH=1
case ":$PATH:" in
    *":$DEST_DIR:"*) ;;
    *)
        ON_PATH=0
        # For the default user dir, wire up PATH automatically so `ada` just
        # works in the next terminal. Custom dirs stay the user's business.
        if [ "$DEST_DIR" = "$HOME/.local/bin" ]; then
            PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
            case "${SHELL:-}" in
                */zsh)  RC_FILES="$HOME/.zshrc" ;;
                # bash: interactive terminals read .bashrc, but LOGIN shells
                # (Ubuntu Touch's Terminal app, ssh) read .profile instead —
                # wire both so a new terminal works on every setup.
                *)      RC_FILES="$HOME/.bashrc $HOME/.profile" ;;
            esac
            WROTE=""
            for RC_FILE in $RC_FILES; do
                if [ -f "$RC_FILE" ] && grep -qF '.local/bin' "$RC_FILE"; then
                    WROTE="$WROTE $RC_FILE"
                elif printf '\n%s\n' "$PATH_LINE" >> "$RC_FILE" 2>/dev/null; then
                    WROTE="$WROTE $RC_FILE"
                fi
            done
            if [ -n "$WROTE" ]; then
                echo "PATH configured in:$WROTE — new terminals will find \`ada\`."
            else
                echo "⚠ $DEST_DIR is not in your PATH — add this line to your shell profile:"
                echo "    $PATH_LINE"
            fi
        else
            echo "⚠ $DEST_DIR is not in your PATH — add it to your shell profile."
        fi
        ;;
esac
echo
# Always end with a command that works VERBATIM in this very terminal:
# a piped installer cannot export PATH into the parent shell, so `ada`
# alone would fail right now even when future terminals are fine.
if [ "$ON_PATH" = "1" ]; then
    echo "✔ Ada CLI is installed. Next step:  ada setup"
else
    echo "✔ Ada CLI is installed. Next step (copy-paste exactly):"
    echo
    echo "    $DEST_DIR/ada setup"
    echo
    echo "  (plain \`ada\` works in new terminals from now on)"
fi
