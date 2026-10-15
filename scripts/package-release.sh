#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' OnlineFixManager/Info.plist)
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
if [[ ${RELEASE_VERSION:-$VERSION} != "$VERSION" ]]; then
    echo "Release version must match app version $VERSION." >&2
    exit 1
fi
PROFILE_BUILDS=""
for PROFILE in out/OnlineFixManager.app/Contents/Resources/runtime/*.json; do
    BUILD=$(/usr/bin/plutil -extract steam_build raw -o - "$PROFILE")
    [[ $BUILD =~ ^[1-9][0-9]*$ && ${PROFILE##*/} == "$BUILD.json" ]] || { echo "Invalid Steam profile: $PROFILE" >&2; exit 1; }
    PROFILE_BUILDS="${PROFILE_BUILDS:+$PROFILE_BUILDS }$BUILD"
done
if [[ -n ${STEAM_VERSION:-} && " $PROFILE_BUILDS " != *" $STEAM_VERSION "* ]]; then
    echo "Target Steam version must be a bundled build: $PROFILE_BUILDS." >&2
    exit 1
fi
if [[ ${GITHUB_REF_TYPE:-} == tag && ${GITHUB_REF_NAME:-} != "v$VERSION" ]]; then
    echo "Tag must match app version v$VERSION." >&2
    exit 1
fi
mkdir -p out/release
awk -v heading="## v$VERSION" '
    $0 == heading { found = 1; next }
    found && /^## / { exit }
    found { print }
' CHANGELOG.md > out/release/notes.md
[[ -s out/release/notes.md ]] || { echo "Missing changelog for v$VERSION." >&2; exit 1; }
NOTES=$(cat out/release/notes.md)
printf 'OnlineFixManager %s.\n\nSupported Steam builds: %s.\n\n%s\n' \
    "$VERSION" "$PROFILE_BUILDS" "$NOTES" > out/release/notes.md
codesign --verify --deep --strict out/OnlineFixManager.app
ARCHIVE="OnlineFixManager-v$VERSION-macos-arm64.zip"
ditto -c -k --norsrc --keepParent out/OnlineFixManager.app "out/release/$ARCHIVE"
cd out/release
shasum -a 256 "$ARCHIVE" > SHA256SUMS
