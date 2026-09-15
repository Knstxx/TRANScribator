#!/bin/zsh
# Source-only real-menu rendering. Never runs or contacts the installed app.
set -euo pipefail

script_dir=${0:A:h}
package_dir=${script_dir:h}
preview_dir="$package_dir/.build/menu-preview"
preview_bundle="$preview_dir/MenuPreview.app"
mkdir -p "$preview_bundle/Contents/MacOS" "$preview_bundle/Contents/Resources"

# Compile only pure display types; production AppState/auth/capture are excluded.
swiftc -swift-version 5 -parse-as-library \
    -emit-module -emit-library -module-name TranscribatorCore \
    "$package_dir/Sources/TranscribatorCore/AppStatus.swift" \
    "$package_dir/Sources/TranscribatorCore/APIKeyStatus.swift" \
    "$package_dir/Sources/TranscribatorCore/TranscriptionModel.swift" \
    "$package_dir/Sources/TranscribatorCore/AudioQuality.swift" \
    -emit-module-path "$preview_dir/TranscribatorCore.swiftmodule" \
    -o "$preview_dir/libTranscribatorCore.dylib"

swiftc -swift-version 5 -parse-as-library \
    -I "$preview_dir" -L "$preview_dir" -lTranscribatorCore \
    -Xlinker -rpath -Xlinker "$preview_dir" \
    "$script_dir/MenuPreviewState.swift" \
    "$package_dir/Sources/TranscribatorMac/AppBranding.swift" \
    "$package_dir/Sources/TranscribatorMac/StatusViews.swift" \
    "$package_dir/Sources/TranscribatorMac/MenuBarContentView.swift" \
    "$package_dir/Sources/TranscribatorMac/SettingsView.swift" \
    "$script_dir/MenuPreview.swift" \
    -o "$preview_bundle/Contents/MacOS/MenuPreview"

cat > "$preview_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.transcribator.menu-preview</string>
<key>CFBundleExecutable</key><string>MenuPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
icon_path=$("$script_dir/build-icon.sh")
cp "$icon_path" "$preview_bundle/Contents/Resources/AppIcon.icns"
"$preview_bundle/Contents/MacOS/MenuPreview" "$preview_dir"
