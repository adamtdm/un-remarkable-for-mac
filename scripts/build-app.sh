#!/bin/zsh
# Builds Unremarkable.app into ./dist. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
# Optional local settings (update feed etc.): see config.example.env.
[[ -f config.local.env ]] && source config.local.env
DOWNLOAD_URL="${DOWNLOAD_URL:-}"
COMPANION_URL="${COMPANION_URL:-}"

CONFIG=${1:-release}
swift build -c "$CONFIG" --product Unremarkable
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Unremarkable"

APP=dist/Unremarkable.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Unremarkable"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

SHORT_VERSION=$(cat VERSION 2>/dev/null || echo 0.1)
VERSION=$(git describe --tags --always 2>/dev/null || echo "$SHORT_VERSION")
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Un-remarkable</string>
  <key>CFBundleDisplayName</key><string>Un-remarkable</string>
  <key>CFBundleIdentifier</key><string>com.unremarkable.mac</string>
  <key>CFBundleExecutable</key><string>Unremarkable</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>UnremarkableUpdateFeed</key><string>${DOWNLOAD_URL}</string>
  <key>UnremarkableCompanionURL</key><string>${COMPANION_URL}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSMicrophoneUsageDescription</key><string>Un-remarkable records your side of meetings to transcribe them on this Mac.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Un-remarkable records the other people on your calls to transcribe meetings on this Mac.</string>
  <key>UTExportedTypeDeclarations</key>
  <array><dict>
    <key>UTTypeIdentifier</key><string>com.unremarkable.mac.document</string>
    <key>UTTypeDescription</key><string>Un-remarkable library item</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict></array>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Un-remarkable reminds you to record meetings as they start and fills in their titles and attendees.</string>
  <key>NSCalendarsUsageDescription</key><string>Un-remarkable reminds you to record meetings as they start and fills in their titles and attendees.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Meetings are transcribed on this Mac with Apple's on-device speech recognition.</string>
</dict>
</plist>
PLIST

# Sign with the stable local identity (scripts/setup-signing.sh) so macOS keeps microphone and
# system-audio permissions across rebuilds; fall back to ad-hoc signing.
SIGN_DIR="$HOME/Library/Application Support/Unremarkable/signing"
if [[ -f "$SIGN_DIR/signing.keychain-db" ]] && security list-keychains -d user | grep -q "signing.keychain-db"; then
  security unlock-keychain -p "$(cat "$SIGN_DIR/keychain-password")" "$SIGN_DIR/signing.keychain-db"
  codesign --force --sign "Unremarkable Local Signing" "$APP" >/dev/null 2>&1
  echo "Signed with Unremarkable Local Signing"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Ad-hoc signed (run scripts/setup-signing.sh to keep permissions across rebuilds)"
fi
echo "Built $APP"
