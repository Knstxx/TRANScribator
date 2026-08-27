#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
package_dir=${script_dir:h}
configuration=${1:-release}
arm64_scratch="$package_dir/.build/universal-arm64"
x86_64_scratch="$package_dir/.build/universal-x86_64"

swift build \
    --package-path "$package_dir" \
    --scratch-path "$arm64_scratch" \
    -c "$configuration" \
    --arch arm64
arm64_bin_dir=$(
    swift build \
        --package-path "$package_dir" \
        --scratch-path "$arm64_scratch" \
        -c "$configuration" \
        --arch arm64 \
        --show-bin-path
)

swift build \
    --package-path "$package_dir" \
    --scratch-path "$x86_64_scratch" \
    -c "$configuration" \
    --arch x86_64
x86_64_bin_dir=$(
    swift build \
        --package-path "$package_dir" \
        --scratch-path "$x86_64_scratch" \
        -c "$configuration" \
        --arch x86_64 \
        --show-bin-path
)

app_dir="$package_dir/dist/Transcribator.app"
contents_dir="$app_dir/Contents"
executable_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

rm -rf "$app_dir"
mkdir -p "$executable_dir" "$resources_dir"
lipo -create \
    "$arm64_bin_dir/TranscribatorMac" \
    "$x86_64_bin_dir/TranscribatorMac" \
    -output "$executable_dir/TranscribatorMac"
cp "$package_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$package_dir/THIRD_PARTY_NOTICES.md" "$resources_dir/THIRD_PARTY_NOTICES.md"

signing_identity=${TRANSCRIBATOR_SIGNING_IDENTITY:--}
if [[ "$signing_identity" == "-" ]]; then
    codesign \
        --force \
        --entitlements "$package_dir/Resources/Transcribator.entitlements" \
        --sign - \
        "$app_dir"
    printf 'Created an ad-hoc signed development build.\n' >&2
else
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --entitlements "$package_dir/Resources/Transcribator.entitlements" \
        --sign "$signing_identity" \
        "$app_dir"
    printf 'Signed with Developer ID identity: %s\n' "$signing_identity" >&2
fi
codesign --verify --deep --strict --verbose=2 "$app_dir"

architectures=$(lipo -archs "$executable_dir/TranscribatorMac")
[[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]] || {
    printf 'Universal binary verification failed: %s\n' "$architectures" >&2
    exit 1
}

printf '%s\n' "$app_dir"
