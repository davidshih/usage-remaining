#!/usr/bin/env bash
# Builds dist/UsageWidget.app (release, ad-hoc signed). With --install, copies it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

install=false
for arg in "$@"; do
  case "$arg" in
    --install) install=true ;;
    *) echo "usage: $0 [--install]" >&2; exit 2 ;;
  esac
done

swift build -c release
BIN=$(swift build -c release --show-bin-path)

APP=dist/UsageWidget.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/UsageWidget" "$APP/Contents/MacOS/UsageWidget"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.davidshih.usagewidget</string>
  <key>CFBundleName</key><string>UsageWidget</string>
  <key>CFBundleExecutable</key><string>UsageWidget</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if $install; then
  pkill -x UsageWidget || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/UsageWidget.app"
  cp -R "$APP" "$HOME/Applications/UsageWidget.app"
  echo "Installed $HOME/Applications/UsageWidget.app"
fi
