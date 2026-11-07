#!/bin/bash
# Spike only: wraps vmctl in a minimal .app so macOS can ask for the
# "System Audio Recording" permission for THIS tool only (CLI tools without an
# Info.plist are silently denied and taps deliver pure silence).
set -euo pipefail
cd "$(dirname "$0")"
swift build
APP=build/vmctl-test.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/vmctl "$APP/Contents/MacOS/vmctl"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.volumemanager.vmctl-test</string>
  <key>CFBundleName</key><string>vmctl-test</string>
  <key>CFBundleExecutable</key><string>vmctl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>Teste do Volume: ajustar o volume de um app. Nada é gravado.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "ok: $APP"
