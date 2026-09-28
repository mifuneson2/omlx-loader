#!/usr/bin/env bash
# Builds "oMLX Loader.app" into build/. Pass --install to copy it to ~/Applications.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/oMLX Loader.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -o "$APP/Contents/MacOS/oMLXLoader" \
    Sources/*.swift

cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough to run locally and to register as a login item.
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/oMLX Loader.app"
    mkdir -p "$HOME/Applications"
    # Quit a running copy so the new build replaces it cleanly.
    pkill -x oMLXLoader 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "Installed $DEST"
    open "$DEST"
fi
