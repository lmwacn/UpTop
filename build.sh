#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
app="UpTop.app"
staging=$(mktemp -d .build.XXXXXX)
trap 'rm -rf "$staging"' EXIT
bundle="$staging/$app"

mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Info.plist "$bundle/Contents/"
swift make-icon.swift "$bundle/Contents/Resources/AppIcon.icns"
swiftc -O -target "$(uname -m)-apple-macos14.0" HardwareMetrics.swift main.swift -o "$bundle/Contents/MacOS/UpTop"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
ditto "$bundle" "$app"
# 通知 Finder 应用包有更新，避免沿用旧图标。
touch "$app"
