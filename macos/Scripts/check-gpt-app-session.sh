#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
package_dir=${script_dir:h}
checks_binary="$package_dir/.build/gpt-app-session-checks"

mkdir -p "$package_dir/.build"
swiftc -parse-as-library \
    "$package_dir/Sources/TranscribatorCore/ChatGPTAppSession.swift" \
    "$package_dir/Checks/ChatGPTAppSessionChecks.swift" \
    -o "$checks_binary" \
    -framework AppKit -framework Security
"$checks_binary"
