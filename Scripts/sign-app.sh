#!/bin/bash
#
# Sign a patched Final Cut Pro: SpliceKit's plugin bundles, the SpliceKit
# framework, then the app itself with entitlements.plist. Used by `make deploy`,
# which `make install` (patcher/patch_fcp.sh) runs too.
#
# Apple's own frameworks and helpers keep their original signatures. Re-signing
# them trips Final Cut Pro's internal integrity checks (ProAppSupport's
# +[PCApp isiMovie], for one) and the app aborts on launch.
#
# Usage: Scripts/sign-app.sh <patched app> [entitlements.plist]

set -u

APP="${1:?usage: sign-app.sh <patched app> [entitlements.plist]}"
ENTITLEMENTS="${2:-$(cd "$(dirname "$0")/.." && pwd)/entitlements.plist}"

if [[ ! -d "$APP" ]]; then
    echo "[X] No app at $APP" >&2
    exit 1
fi

# An Apple Development identity if there is one, else a Developer ID, else any
# codesigning identity; empty when the keychain has none.
detect_sign_identity() {
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null | \
        awk '
            /"Apple Development:/ { print $2; exit }
            /"Developer ID Application:/ && developer == "" { developer = $2 }
            /[0-9]+\) [0-9A-F]+ "/ && first == "" { first = $2 }
            END {
                if (developer != "") print developer;
                else if (first != "") print first;
            }'
}

sign_all() {
    local identity="$1"

    # Copies made by earlier installs can carry extended attributes that make
    # codesign refuse the bundle ("resource fork, Finder information, or
    # similar detritus not allowed").
    xattr -cr "$APP" 2>/dev/null || true

    local bundle
    for bundle in "$APP/Contents/PlugIns/Codecs/SpliceKitVP9Decoder.bundle" \
                  "$APP/Contents/PlugIns/FormatReaders/SpliceKitMKVImport.bundle"; do
        if [[ -e "$bundle" ]]; then
            codesign --force --options runtime --sign "$identity" "$bundle" || return 1
        fi
    done
    codesign --force --options runtime --sign "$identity" \
        "$APP/Contents/Frameworks/SpliceKit.framework" || return 1
    codesign --force --options runtime --sign "$identity" \
        --entitlements "$ENTITLEMENTS" "$APP" || return 1
}

IDENTITY="$(detect_sign_identity || true)"
if [[ -n "$IDENTITY" ]]; then
    echo "[i] Using signing identity: $IDENTITY"
else
    IDENTITY="-"
    echo "[i] No local codesigning identity found; signing ad-hoc (macOS may be stricter about launching it)"
fi

if ! sign_all "$IDENTITY"; then
    if [[ "$IDENTITY" == "-" ]]; then
        echo "[X] Signing failed" >&2
        exit 1
    fi
    echo "[!] Developer signing failed; retrying with an ad-hoc signature"
    sign_all "-" || { echo "[X] Signing failed" >&2; exit 1; }
fi

# Mixed signatures (Apple's frameworks + ours) can make --verify complain even
# though the app launches, because library validation is disabled; report it.
VERIFY_OUT="$(codesign --verify --verbose "$APP" 2>&1)"
if grep -qE "valid on disk|satisfies" <<<"$VERIFY_OUT"; then
    echo "[+] Signature valid"
else
    echo "[i] Signature note: $VERIFY_OUT"
fi

if codesign -d --entitlements - "$APP" 2>&1 | grep -q "disable-library-validation"; then
    echo "[+] Entitlements applied (no sandbox, library validation disabled)"
else
    echo "[X] Entitlements not applied correctly" >&2
    exit 1
fi
