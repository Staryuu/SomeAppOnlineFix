#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/out/7zip"
mkdir -p "$DEST"
TEMP=$(mktemp -d "$DEST/.fetch-XXXXXX")
trap 'rm -rf "$TEMP"' EXIT
curl --fail --location --retry 2 https://github.com/ip7z/7zip/releases/download/26.04/7z2604-mac.tar.xz --output "$TEMP/archive.tar.xz"
echo "bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578  $TEMP/archive.tar.xz" | shasum -a 256 -c -
tar -xf "$TEMP/archive.tar.xz" -C "$TEMP" 7zz License.txt
mv "$TEMP/7zz" "$DEST/7zz"
mv "$TEMP/License.txt" "$DEST/License.txt"
touch "$DEST/7zz"
