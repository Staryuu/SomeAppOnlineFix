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
PROFILE_BUILD=$(/usr/bin/plutil -extract steam_build raw -o - out/OnlineFixManager.app/Contents/Resources/runtime/1791918634.json)
if [[ ${STEAM_VERSION:-$PROFILE_BUILD} != "$PROFILE_BUILD" ]]; then
    echo "Target Steam version must match bundled profile build $PROFILE_BUILD." >&2
    exit 1
fi
STEAM_VERSION=$PROFILE_BUILD
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
if [[ -n ${STEAM_VERSION:-} ]]; then
    NOTES=$(cat out/release/notes.md)
    printf 'OnlineFixManager %s.\n\nTarget Steam version: `%s`.\n\n%s\n' \
        "$VERSION" "$STEAM_VERSION" "$NOTES" > out/release/notes.md
fi
codesign --verify --deep --strict out/OnlineFixManager.app
STAGE=$(mktemp -d "$ROOT/out/package-XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/OnlineFixManager"
ditto out/OnlineFixManager.app "$STAGE/OnlineFixManager/OnlineFixManager.app"
cp README.md CHANGELOG.md LICENSE "$STAGE/OnlineFixManager/"
cp vendor/dobby/LICENSE "$STAGE/OnlineFixManager/Dobby-LICENSE"
python3 - "$STAGE/OnlineFixManager/cJSON-LICENSE" <<'PY'
from pathlib import Path
import sys
license_text = Path('vendor/cJSON.c').read_text().split('*/', 1)[0] + '*/\n'
Path(sys.argv[1]).write_text(license_text)
PY
ARCHIVE="OnlineFixManager-v$VERSION-macos-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/OnlineFixManager" "out/release/$ARCHIVE"
cd out/release
shasum -a 256 "$ARCHIVE" > SHA256SUMS
