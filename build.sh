#!/bin/zsh
# Builds Eddie.app in ./build. Only needs the Xcode Command Line Tools.
#   ./build.sh            build
#   ./build.sh --install  build and copy to /Applications
#   ./build.sh --open     build and open the app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Eddie"

APP=build/Eddie.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Eddie"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Eddie</string>
    <key>CFBundleDisplayName</key><string>Eddie</string>
    <key>CFBundleIdentifier</key><string>dk.eddie-tor.Eddie</string>
    <key>CFBundleExecutable</key><string>Eddie</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDevelopmentRegion</key><string>da</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>dk.eddie-tor.project</string>
            <key>UTTypeDescription</key><string>Eddie-projekt</string>
            <key>UTTypeConformsTo</key><array><string>public.json</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>eddie</string></array></dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Eddie-projekt</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>dk.eddie-tor.project</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Bygget: $PWD/$APP"

case "${1:-}" in
    --install)
        rm -rf /Applications/Eddie.app
        cp -R "$APP" /Applications/
        echo "Installeret i /Applications"
        ;;
    --open)
        open "$APP"
        ;;
esac
