#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/vendor/dobby"
REV=5dfc8546954ce3b3198132ab13fddb89ee92cdd7
[[ ! -d $DEST ]] || { echo 'Dobby directory already exists; refusing to overwrite it.' >&2; exit 1; }
mkdir -p "$ROOT/vendor"
TEMP=$(mktemp -d "$ROOT/vendor/.dobby-XXXXXX")
trap 'rm -rf "$TEMP"' EXIT
curl --fail --location --retry 2 "https://github.com/jmpews/Dobby/archive/$REV.tar.gz" --output "$TEMP/source.tar.gz"
mkdir "$TEMP/source"
tar -xzf "$TEMP/source.tar.gz" --strip-components=1 -C "$TEMP/source"
[[ -f $TEMP/source/include/dobby.h && -f $TEMP/source/CMakeLists.txt && -f $TEMP/source/LICENSE ]]
mv "$TEMP/source" "$DEST"
