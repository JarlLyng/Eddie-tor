#!/bin/sh

# Xcode Cloud runs this before building; it looks for ci_scripts next to Edwell.xcodeproj.
# Sets a unique, incrementing build number from the Cloud build number so every TestFlight
# upload is accepted. A no-op outside Xcode Cloud (CI_BUILD_NUMBER is unset).

set -e

if [ -n "$CI_BUILD_NUMBER" ] && [ -n "$CI_PRIMARY_REPOSITORY_PATH" ]; then
    echo "Setting build number to $CI_BUILD_NUMBER"
    cd "$CI_PRIMARY_REPOSITORY_PATH/App"
    agvtool new-version -all "$CI_BUILD_NUMBER"
else
    echo "Not in Xcode Cloud, leaving the build number unchanged."
fi
