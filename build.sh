#!/bin/bash
# Build Dimmer.app with swiftc (no Xcode project), sign it, install to ~/Applications and relaunch.
set -euo pipefail
cd "$(dirname "$0")"

NAME=Dimmer
BUNDLE_ID=com.jayden.dimmer
VERSION=1.1.0
BUILD=$(date +%Y%m%d%H%M)
MIN_OS=14.0
IDENTITY="Dimmer Dev"
APP="build/$NAME.app"

echo "==> Compiling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos$MIN_OS" \
  -sdk "$(xcrun --show-sdk-path)" \
  -framework AppKit -framework Carbon -framework ServiceManagement -framework ApplicationServices \
  Sources/*.swift -o "$APP/Contents/MacOS/$NAME"

# The icon is drawn by icon.swift; regenerate only when that file changes.
ICON=build/AppIcon.icns
if [ ! -f "$ICON" ] || [ icon.swift -nt "$ICON" ]; then
  echo "==> Drawing icon"
  rm -rf build/AppIcon.iconset
  swift icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o "$ICON"
  rm -rf build/AppIcon.iconset
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# A stable self-signed identity keeps the Accessibility grant valid across rebuilds
# (TCC matches the certificate, not the binary hash).
has_identity() { security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; }

create_identity() {
  echo "==> Creating self-signed code signing certificate \"$IDENTITY\" in the login keychain"
  local tmp; tmp=$(mktemp -d)
  cat > "$tmp/cert.cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
  # /usr/bin/openssl is LibreSSL; its PKCS#12 output is what `security import` expects.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cfg" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$IDENTITY" \
    -out "$tmp/id.p12" -passout pass:dimmer
  security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P dimmer -T /usr/bin/codesign >/dev/null
  rm -rf "$tmp"
}

echo "==> Signing"
echo "    (first time: macOS may ask to let codesign use the \"$IDENTITY\" key — enter your login password, choose Always Allow)"
if ! has_identity; then
  create_identity || true
fi
if has_identity && codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" 2>/dev/null; then
  echo "    signed with \"$IDENTITY\""
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "    !! \"$IDENTITY\" unavailable — ad-hoc signed."
  echo "    !! Accessibility permission will NOT survive rebuilds: re-enable Dimmer in"
  echo "    !! System Settings › Privacy & Security › Accessibility after each build."
  echo "    !! To create the identity by hand: Keychain Access › Certificate Assistant ›"
  echo "    !! Create a Certificate… › Name \"$IDENTITY\", Self Signed Root, Code Signing."
fi

echo "==> Installing to ~/Applications"
pkill -x "$NAME" 2>/dev/null || true
for _ in $(seq 50); do pgrep -x "$NAME" >/dev/null || break; sleep 0.1; done
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$NAME.app"
ditto "$APP" "$HOME/Applications/$NAME.app"
# LaunchServices sometimes needs a moment to register the fresh copy (error -600).
for i in 1 2 3 4 5; do open "$HOME/Applications/$NAME.app" 2>/dev/null && break; sleep 0.5; done
echo "==> Done: $HOME/Applications/$NAME.app"
