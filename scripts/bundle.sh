#!/bin/bash
# Packages Eden. Build tooling only; the app itself is all Swift.
#
#   ./scripts/bundle.sh            build/Eden.app, named "Eden Dev" (com.phantasyco.eden.dev)
#   ./scripts/bundle.sh --install  /Applications/Eden.app, the Eden you use day to day
#
# Dev builds get their own bundle ID. Otherwise every build/Eden.app, including
# the ones agents make in their worktrees, registers as "Eden", and macOS may
# open a stale one when you launch the app. The ID also gives dev builds their
# own settings and threads, so testing never touches your real ones.
set -euo pipefail
cd "$(dirname "$0")/.."

install=false
[ "${1:-}" = "--install" ] && install=true

swift build -c release

if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

if $install; then
  name="Eden"; id="com.phantasyco.eden"
  app="$(mktemp -d)/Eden.app"
else
  name="Eden Dev"; id="com.phantasyco.eden.dev"
  app="build/Eden.app"
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Eden "$app/Contents/MacOS/Eden"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier $id" \
  -c "Set :CFBundleName $name" \
  -c "Set :CFBundleDisplayName $name" \
  "$app/Contents/Info.plist"
codesign --force --sign - "$app" >/dev/null 2>&1

if $install; then
  rm -rf /Applications/Eden.app
  mv "$app" /Applications/Eden.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Eden.app
  echo "Installed /Applications/Eden.app"
  if pgrep -fq "^/Applications/Eden.app/"; then echo "Eden is running. Quit and reopen it to use this build."; fi
else
  echo "Built $app (Eden Dev)"
fi
