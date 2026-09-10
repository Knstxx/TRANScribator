#!/bin/zsh
# Renders source-only previews. Never launches, replaces, or communicates with the app.
set -euo pipefail

script_dir=${0:A:h}
package_dir=${script_dir:h}
preview_dir="$package_dir/.build/status-preview"
mkdir -p "$preview_dir"

# Deliberately build only the pure status model, excluding capture, storage, and AppState.
swiftc -swift-version 5 -parse-as-library \
    -emit-module -emit-library -module-name TranscribatorCore \
    "$package_dir/Sources/TranscribatorCore/AppStatus.swift" \
    -emit-module-path "$preview_dir/TranscribatorCore.swiftmodule" \
    -o "$preview_dir/libTranscribatorCore.dylib"

swiftc -swift-version 5 -parse-as-library \
    -I "$preview_dir" -L "$preview_dir" -lTranscribatorCore \
    -Xlinker -rpath -Xlinker "$preview_dir" \
    "$package_dir/Sources/TranscribatorMac/AppBranding.swift" \
    "$package_dir/Sources/TranscribatorMac/StatusViews.swift" \
    "$script_dir/StatusPreview.swift" \
    -o "$preview_dir/StatusPreview"

"$preview_dir/StatusPreview" "$preview_dir" "$package_dir/Resources/AppIcon.png"
