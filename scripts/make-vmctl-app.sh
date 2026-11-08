#!/usr/bin/env bash
# Development only: wraps vmctl in build/vmctl-dev.app so macOS can ask for the "System Audio
# Recording" permission for this tool. A command line tool without an Info.plist never gets the
# request: taps are created without any error and deliver only zeros (SPEC 4.6).
# vmctl is NEVER part of Volume.app or the DMG (SPEC 12.9.6); this bundle lives in build/ only.
#
# Usage: scripts/make-vmctl-app.sh
# Then:  open -W --stdout "$PWD/build/vmctl-dev.out" --stderr "$PWD/build/vmctl-dev.out" \
#             build/vmctl-dev.app --args set <bundleID|pid:N> --volume 0.3 --duration 20
#        cat build/vmctl-dev.out
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/vmctl-dev.app"
IGNORED_WARNING='ld: warning: search path .* not found'

echo "==> swift build --product vmctl"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
if ! swift build --product vmctl >"$LOG" 2>&1; then
  grep -Ev "$IGNORED_WARNING" "$LOG" >&2
  exit 1
fi
BIN_DIR="$(swift build --show-bin-path 2>/dev/null)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/vmctl" "$APP/Contents/MacOS/vmctl"
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.volumemanager.vmctl-dev</string>
	<key>CFBundleName</key>
	<string>vmctl-dev</string>
	<key>CFBundleExecutable</key>
	<string>vmctl</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAudioCaptureUsageDescription</key>
	<string>Ferramenta de desenvolvimento do Volume: ajustar o volume de um app. Nada é gravado ou enviado.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "ok: $APP (bundle ID com.volumemanager.vmctl-dev, ad-hoc signature)"
