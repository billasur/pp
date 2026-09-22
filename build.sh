#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Use the installed Xcode for XCTest and native SDKs without changing xcode-select.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
elif [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk && ! -f /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi

if pgrep -x PpDesktop >/dev/null || pgrep -x JevDesktop >/dev/null; then
  echo 'Quit pp before building and installing.' >&2
  exit 1
fi

xcrun swift build -c release
PP_BIN_DIR="$(xcrun swift build -c release --show-bin-path)"
PP_APP_DIR="$PWD/.build/app/pp.app"
PP_INSTALL_DIR="$HOME/Applications/pp.app"
mkdir -p "$PP_APP_DIR/Contents/MacOS" "$PP_APP_DIR/Contents/Resources"
cp "$PP_BIN_DIR/PpDesktop" "$PP_APP_DIR/Contents/MacOS/PpDesktop"
cp Resources/Info.plist "$PP_APP_DIR/Contents/Info.plist"

# Copy SwiftPM resource bundles (including MLX Metal shaders) into app bundle
for bundle in "$PP_BIN_DIR"/*.bundle; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$PP_APP_DIR/Contents/Resources/"
  fi
done

# Ensure colocated default.metallib is directly discoverable by Cmlx
if [ -f "$PP_APP_DIR/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]; then
  cp "$PP_APP_DIR/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$PP_APP_DIR/Contents/Resources/default.metallib"
fi

python3 scripts/sign-local.py "$PP_APP_DIR"
if pgrep -x PpDesktop >/dev/null || pgrep -x JevDesktop >/dev/null; then
  echo 'pp was opened during the build. Quit it, then run the build again.' >&2
  exit 1
fi
mkdir -p "$HOME/Applications"
rm -rf "$PP_INSTALL_DIR"
ditto "$PP_APP_DIR" "$PP_INSTALL_DIR"
codesign --verify --strict "$PP_INSTALL_DIR"
printf 'Installed: %s\n' "$PP_INSTALL_DIR"

# Generate slim distribution DMG with Applications symlink
DMG_PATH="$PWD/.build/pp.dmg"
DMG_STAGE="$PWD/.build/dmg_stage"
rm -rf "$DMG_STAGE" "$DMG_PATH"
mkdir -p "$DMG_STAGE"
cp -R "$PP_APP_DIR" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
if [ -f THIRD_PARTY_NOTICES.md ]; then
  cp THIRD_PARTY_NOTICES.md "$DMG_STAGE/"
fi
hdiutil create -volname "pp" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGE"
DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
APP_SIZE=$(du -sh "$PP_APP_DIR" | cut -f1)
printf 'Generated slim distribution DMG: %s (%s, App: %s)\n' "$DMG_PATH" "$DMG_SIZE" "$APP_SIZE"

