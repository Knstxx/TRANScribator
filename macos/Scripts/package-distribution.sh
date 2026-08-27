#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
package_dir=${script_dir:h}
dist_dir="$package_dir/dist"
notarize=false

if [[ ${1:-} == "--notarize" ]]; then
    notarize=true
    shift
fi
if (( $# > 0 )); then
    printf 'Usage: %s [--notarize]\n' "$0" >&2
    exit 2
fi

if $notarize; then
    : "${TRANSCRIBATOR_SIGNING_IDENTITY:?Set TRANSCRIBATOR_SIGNING_IDENTITY to a Developer ID Application identity}"
    : "${TRANSCRIBATOR_NOTARY_PROFILE:?Set TRANSCRIBATOR_NOTARY_PROFILE to a notarytool Keychain profile}"
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$package_dir/Resources/Info.plist")
artifact_stem="Transcribator-$version-macOS-universal"
zip_path="$dist_dir/$artifact_stem.zip"
dmg_path="$dist_dir/$artifact_stem.dmg"
checksums_path="$dist_dir/SHA256SUMS"

app_dir="$dist_dir/Transcribator.app"
if $notarize; then
    "$script_dir/build-app.sh" release
    signature_details=$(codesign -dvv "$app_dir" 2>&1)
    [[ "$signature_details" == *"Authority=Developer ID Application:"* ]] || {
        printf 'The app is not signed with a Developer ID Application certificate.\n' >&2
        exit 1
    }
    [[ "$signature_details" == *"runtime"* ]] || {
        printf 'The app signature does not enable Hardened Runtime.\n' >&2
        exit 1
    }
else
    TRANSCRIBATOR_SIGNING_IDENTITY=- "$script_dir/build-app.sh" release
fi

rm -f "$zip_path" "$dmg_path" "$checksums_path"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/TranscribatorDistribution.XXXXXX")
dmg_staging_dir="$work_dir/dmg"
mkdir -p "$dmg_staging_dir"
trap 'rm -rf "$work_dir"' EXIT

if $notarize; then
    notary_zip="$work_dir/Transcribator-notary.zip"
    ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$notary_zip"
    xcrun notarytool submit "$notary_zip" \
        --keychain-profile "$TRANSCRIBATOR_NOTARY_PROFILE" \
        --wait \
        --timeout 30m
    xcrun stapler staple "$app_dir"
    xcrun stapler validate "$app_dir"
    if command -v syspolicy_check >/dev/null 2>&1; then
        syspolicy_check distribution "$app_dir"
    fi
fi

ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$zip_path"
ditto "$app_dir" "$dmg_staging_dir/Transcribator.app"
ln -s /Applications "$dmg_staging_dir/Applications"
hdiutil create \
    -quiet \
    -volname "Transcribator" \
    -srcfolder "$dmg_staging_dir" \
    -format UDZO \
    -ov \
    "$dmg_path"

if $notarize; then
    codesign \
        --force \
        --timestamp \
        --sign "$TRANSCRIBATOR_SIGNING_IDENTITY" \
        "$dmg_path"
    xcrun notarytool submit "$dmg_path" \
        --keychain-profile "$TRANSCRIBATOR_NOTARY_PROFILE" \
        --wait \
        --timeout 30m
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
    spctl --assess \
        --type open \
        --context context:primary-signature \
        --verbose=4 \
        "$dmg_path"
fi

hdiutil verify -quiet "$dmg_path"

(
    cd "$dist_dir"
    shasum -a 256 "${zip_path:t}" "${dmg_path:t}" > "${checksums_path:t}"
)

printf '%s\n%s\n%s\n' "$zip_path" "$dmg_path" "$checksums_path"
