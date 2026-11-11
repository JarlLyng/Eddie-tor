#!/bin/zsh
# Builds build/Edwell.app from App/Edwell.xcodeproj: the Mac App Store app, sandboxed, signed to run locally.
# Needs Xcode. The self test needs only the Command Line Tools (see AGENTS.md).
#   ./build.sh            build
#   ./build.sh --install  build and copy to /Applications
#   ./build.sh --open     build and open the app
set -euo pipefail
cd "$(dirname "$0")"

xcodebuild -project App/Edwell.xcodeproj -scheme Edwell -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData -quiet \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build

APP=build/Edwell.app
rm -rf "$APP"
ditto build/DerivedData/Build/Products/Release/Edwell.app "$APP"
echo "Built: $PWD/$APP"

case "${1:-}" in
    --install)
        rm -rf /Applications/Edwell.app
        ditto "$APP" /Applications/Edwell.app
        echo "Installed in /Applications"
        ;;
    --open)
        open "$APP"
        ;;
esac
