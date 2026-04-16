#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="SipTray"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
BUNDLE_DIR="$ROOT_DIR/.build/${APP_NAME}.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
ICONSET_DIR="$ROOT_DIR/.build/${APP_NAME}.iconset"
ICON_PATH="$RESOURCES_DIR/${APP_NAME}.icns"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"
ENTITLEMENTS_PATH="$ROOT_DIR/.build/${APP_NAME}.entitlements"
PJSIP_DIR="$ROOT_DIR/Vendor/pjproject"
PJSIP_BUILD_STAMP="$PJSIP_DIR/.codex-local-build-stamp"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: LimTec GmbH (BPPQ4T72QP)}"

prepare_pjsip() {
  if [[ -f "$PJSIP_BUILD_STAMP" ]] && [[ "$PJSIP_DIR/pjmedia/src/pjmedia-audiodev/coreaudio_dev.m" -nt "$PJSIP_BUILD_STAMP" ]]; then
    rm -f "$PJSIP_BUILD_STAMP"
  fi

  if [[ ! -f "$PJSIP_BUILD_STAMP" ]]; then
    echo "Preparing PJPROJECT..."
    (
      cd "$PJSIP_DIR"
      make distclean >/dev/null 2>&1 || true
      export MACOSX_DEPLOYMENT_TARGET=13.0
      ./configure \
        --disable-video \
        --disable-sdl \
        --disable-ffmpeg \
        --disable-openh264 \
        --disable-vpx \
        --prefix="$PJSIP_DIR/install"
      make EXCLUDE_APP=1 dep
      make EXCLUDE_APP=1 -j"$(sysctl -n hw.ncpu)"
      touch "$PJSIP_BUILD_STAMP"
    )
  fi

  echo "Refreshing generic PJPROJECT library names..."
  for dir in \
    "$PJSIP_DIR/pjsip/lib" \
    "$PJSIP_DIR/pjmedia/lib" \
    "$PJSIP_DIR/pjnath/lib" \
    "$PJSIP_DIR/pjlib-util/lib" \
    "$PJSIP_DIR/pjlib/lib" \
    "$PJSIP_DIR/third_party/lib"; do
    for lib in "$dir"/*-aarch64-apple-darwin*.a; do
      [[ -e "$lib" ]] || continue
      local base generic
      base="$(basename "$lib")"
      generic="${base%%-aarch64-apple-darwin*}.a"
      ln -sf "$base" "$dir/$generic"
    done
  done
}

generate_icon() {
  local source_png="$ROOT_DIR/.build/${APP_NAME}-1024.png"

  /usr/bin/swift - <<'SWIFT' "$source_png"
import AppKit

let outputPath = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()
let rect = NSRect(origin: .zero, size: size)
NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.16, alpha: 1).setFill()
NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220).fill()

let circleRect = NSRect(x: 112, y: 112, width: 800, height: 800)
NSColor(calibratedRed: 0.18, green: 0.70, blue: 0.43, alpha: 1).setFill()
NSBezierPath(ovalIn: circleRect).fill()

let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .black)
if let symbol = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let symbolRect = NSRect(x: 260, y: 260, width: 504, height: 504)
    symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
}

NSColor.systemRed.setFill()
NSBezierPath(ovalIn: NSRect(x: 714, y: 714, width: 170, height: 170)).fill()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fputs("Failed to render app icon\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
SWIFT

  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  cp "$source_png" "$ICONSET_DIR/icon_512x512@2x.png"
  /usr/bin/sips -z 512 512 "$source_png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  /usr/bin/sips -z 256 256 "$source_png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  /usr/bin/sips -z 512 512 "$source_png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  /usr/bin/sips -z 128 128 "$source_png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  /usr/bin/sips -z 256 256 "$source_png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  /usr/bin/sips -z 32 32 "$source_png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  /usr/bin/sips -z 64 64 "$source_png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  /usr/bin/sips -z 16 16 "$source_png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  /usr/bin/sips -z 32 32 "$source_png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  /usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$ROOT_DIR/.build/${APP_NAME}.icns"
}

echo "Building ${APP_NAME} (${BUILD_CONFIGURATION})..."
prepare_pjsip
MACOSX_DEPLOYMENT_TARGET=13.0 swift build -c "$BUILD_CONFIGURATION"

EXECUTABLE_PATH="$(
  find "$ROOT_DIR/.build" -type f -path "*/${BUILD_CONFIGURATION}/${APP_NAME}" | head -n 1
)"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Build artifact not found: $EXECUTABLE_PATH" >&2
  exit 1
fi

echo "Creating app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"
generate_icon
cp "$ROOT_DIR/.build/${APP_NAME}.icns" "$ICON_PATH"

cat > "$PLIST_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>de</string>
    <key>CFBundleExecutable</key>
    <string>SipTray</string>
    <key>CFBundleIdentifier</key>
    <string>de.limtec.siptray</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>SipTray</string>
    <key>CFBundleName</key>
    <string>SipTray</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Das Mikrofon wird fuer SIP-Telefonate verwendet.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Die Spracherkennung wird fuer lokale Transkription von Gespraechen verwendet.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Telefon</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>tel</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

mkdir -p "$INSTALL_DIR"
echo "Installing to $TARGET_APP..."
rm -rf "$TARGET_APP"
cp -R "$BUNDLE_DIR" "$TARGET_APP"

cat > "$ENTITLEMENTS_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.personal-information.speech-recognition</key>
    <true/>
</dict>
</plist>
EOF

echo "Signing with $SIGNING_IDENTITY..."
/usr/bin/codesign \
  --force \
  --deep \
  --options runtime \
  --entitlements "$ENTITLEMENTS_PATH" \
  --sign "$SIGNING_IDENTITY" \
  "$TARGET_APP"

echo "Installed: $TARGET_APP"
echo "Run with: open \"$TARGET_APP\""
pkill -f "$TARGET_APP/Contents/MacOS/$APP_NAME" || true
open "$TARGET_APP"

