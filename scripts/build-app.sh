#!/bin/bash
# Builds dist/Hog.app (menu bar app + the hog CLI inside it), ad-hoc signed. Does not install anything.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/HogCore/Hog.swift)
swift build -c release --product HogBar
swift build -c release --product hog
BIN=$(swift build -c release --show-bin-path)

APP=dist/Hog.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HogBar" "$APP/Contents/MacOS/HogBar"
cp "$BIN/hog" "$APP/Contents/MacOS/hog"
cp -R "$BIN/hog_HogCore.bundle" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Hog</string>
  <key>CFBundleDisplayName</key><string>hog</string>
  <key>CFBundleIdentifier</key><string>io.github.linhh-phv.hog</string>
  <key>CFBundleExecutable</key><string>HogBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT</string>
  <key>NSDesktopFolderUsageDescription</key><string>hog reads package.json / .git in a process's folder to tell which project it belongs to. Nothing is changed or sent anywhere.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>hog reads package.json / .git in a process's folder to tell which project it belongs to. Nothing is changed or sent anywhere.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>hog reads package.json / .git in a process's folder to tell which project it belongs to. Nothing is changed or sent anywhere.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP ($VERSION)"
