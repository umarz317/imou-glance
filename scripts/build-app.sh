#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
export CLANG_MODULE_CACHE_PATH="$repo_dir/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_dir/.build/ModuleCache"
export XDG_CACHE_HOME="$repo_dir/.build/cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$XDG_CACHE_HOME"
swift build -c release -debug-info-format none --disable-sandbox --cache-path "$XDG_CACHE_HOME" --config-path "$repo_dir/.build/config" --security-path "$repo_dir/.build/security"
app_dir="$repo_dir/build/Imou Glance.app"
# Start clean so a previous release's stapled ticket or signature never carries over.
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
cp .build/release/ImouPeek "$app_dir/Contents/MacOS/ImouPeek"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Resources"
cp -R .build/release/ImouPeek_ImouMac.bundle "$app_dir/Contents/Resources/"
cp Resources/AppIcon.icns "$app_dir/Contents/Resources/"

# Local builds are ad hoc signed. For a release, set SIGN_IDENTITY to a "Developer ID Application" identity
# and NOTARY_PROFILE to a `xcrun notarytool store-credentials` profile name.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --identifier local.imou.peek --sign "$SIGN_IDENTITY" "$app_dir"
else
    codesign --force --sign - --identifier local.imou.peek "$app_dir"
fi
codesign --verify --strict "$app_dir"
printf '\nBuilt %s\n' "$app_dir"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ -n "${SIGN_IDENTITY:-}" ]] || { echo "NOTARY_PROFILE needs SIGN_IDENTITY" >&2; exit 1; }
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
    archive="$repo_dir/build/Imou-Glance-$version-arm64.zip"
    rm -f "$archive"
    ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive"
    xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app_dir"
    spctl --assess --type execute "$app_dir"
    # Re-zip so the download carries the stapled ticket.
    rm -f "$archive"
    ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive"
    printf 'Notarized %s\nSHA-256 %s\n' "$archive" "$(shasum -a 256 "$archive" | cut -d' ' -f1)"
fi
