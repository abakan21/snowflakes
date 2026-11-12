#!/bin/bash
# Builds Sugrob.app and Sugrob.zip (for sharing) into build/
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install the Apple developer tools:"
  echo "  xcode-select --install"
  echo "then run this script again."
  exit 1
fi

NAME="Sugrob"
OUT="build"
APP="$OUT/$NAME.app"

mkdir -p "$OUT"
if [ -d "$APP" ]; then
  mv "$APP" "$OUT/old-$(date +%s).app"
fi
mkdir -p "$APP/Contents/MacOS"

build_arch() {
  xcrun swiftc -O -target "$1-apple-macos12.0" Sources/main.swift -o "$OUT/$NAME-$1"
}

echo "Building for Apple Silicon..."
build_arch arm64
echo "Building for Intel..."
if build_arch x86_64; then
  lipo -create "$OUT/$NAME-arm64" "$OUT/$NAME-x86_64" -output "$APP/Contents/MacOS/$NAME"
else
  echo "Intel build failed; the app will be Apple Silicon only."
  cp "$OUT/$NAME-arm64" "$APP/Contents/MacOS/$NAME"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Sugrob</string>
  <key>CFBundleIdentifier</key><string>local.sugrob.app</string>
  <key>CFBundleName</key><string>Sugrob</string>
  <key>CFBundleDisplayName</key><string>Sugrob</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" "$OUT/$NAME.zip"

echo
echo "Done: $APP"
echo "Archive for sharing: $OUT/$NAME.zip"
echo "Run: open \"$APP\""
