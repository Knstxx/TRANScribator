#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
package_dir=${script_dir:h}
source_image="$package_dir/Resources/AppIcon.png"
output_dir="$package_dir/.build/branding"
iconset_dir="$output_dir/AppIcon.iconset"

mkdir -p "$iconset_dir"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source_image" \
        --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$source_image" \
        --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset_dir" -o "$output_dir/AppIcon.icns"
printf '%s\n' "$output_dir/AppIcon.icns"
