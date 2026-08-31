# Sourced by the release scripts: resolves an Ed25519-capable openssl into
# $OPENSSL, PROVEN by the RFC 8032 §7.1 TEST 2 known vector (deterministic
# signature must match exactly; the vector must verify; a tampered copy must
# be rejected). Nothing is trusted from `openssl version` strings — a
# LibreSSL or OpenSSL 1.1.1 in PATH ahead of a capable build is exactly the
# CI failure this replaces (macOS runner: keygen picked Homebrew's OpenSSL 3,
# the signer took the 1.1.1 in PATH).
#
# Also provides hex helpers so no script depends on xxd (absent in the Swift
# CI container): python3 is already a hard requirement of every caller.
#
#   OPENSSL_BIN set   → only that binary is probed; failure is fatal.
#   OPENSSL_BIN unset → PATH openssl, then the Homebrew/usr-local locations.

ossl_hex() { od -An -v -tx1 "$1" | tr -d ' \n'; }
ossl_unhex() { python3 -c 'import sys; sys.stdout.buffer.write(bytes.fromhex(sys.argv[1]))' "$1"; }

# RFC 8032 §7.1 TEST 2 (one-byte message 0x72). TEST 1 is unusable here:
# pkeyutl refuses a zero-length input file.
OSSL_KV_SEED="4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"
OSSL_KV_SIG="92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"

# Explicit && chain, NOT `set -e`: callers run this inside `if`, where bash
# suspends errexit for the whole function body (subshells included).
ossl_probe_in() {
    local ossl="$1" d="$2"
    ossl_unhex "302e020100300506032b657004220420$OSSL_KV_SEED" > "$d/kv.der" \
    && "$ossl" pkey -inform DER -in "$d/kv.der" -out "$d/kv.pem" 2>/dev/null \
    && "$ossl" pkey -in "$d/kv.pem" -pubout -out "$d/kv.pub.pem" 2>/dev/null \
    && printf '\x72' > "$d/kv.msg" \
    && "$ossl" pkeyutl -sign -rawin -inkey "$d/kv.pem" -in "$d/kv.msg" -out "$d/kv.sig" 2>/dev/null \
    && [ -s "$d/kv.sig" ] \
    && [ "$(ossl_hex "$d/kv.sig")" = "$OSSL_KV_SIG" ] \
    && "$ossl" pkeyutl -verify -rawin -pubin -inkey "$d/kv.pub.pem" \
           -in "$d/kv.msg" -sigfile "$d/kv.sig" >/dev/null 2>&1 \
    && ossl_unhex "01${OSSL_KV_SIG:2}" > "$d/bad.sig" \
    && ! "$ossl" pkeyutl -verify -rawin -pubin -inkey "$d/kv.pub.pem" \
           -in "$d/kv.msg" -sigfile "$d/bad.sig" >/dev/null 2>&1
}

ossl_probe() {
    local d rc
    d="$(mktemp -d)" || return 1
    ossl_probe_in "$1" "$d"
    rc=$?
    rm -rf "$d"
    return $rc
}

resolve_openssl() {
    local candidate candidates
    if [ -n "${OPENSSL_BIN:-}" ]; then
        candidates=("$OPENSSL_BIN")
    else
        candidates=(openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl
                    /opt/homebrew/bin/openssl /usr/local/bin/openssl /usr/bin/openssl)
    fi
    for candidate in "${candidates[@]}"; do
        command -v "$candidate" >/dev/null 2>&1 || continue
        if ossl_probe "$candidate"; then
            OPENSSL="$candidate"
            return 0
        fi
    done
    echo "✖ no Ed25519-capable openssl passed the RFC 8032 known-vector probe (tried: ${candidates[*]}; set OPENSSL_BIN)" >&2
    return 1
}
