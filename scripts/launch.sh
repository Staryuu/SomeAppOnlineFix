#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "onlinefix: $*" >&2; exit 1; }
[[ $(uname -m) == arm64 ]] || fail 'Requires Apple Silicon.'
if pgrep -u "$(id -u)" -x steam_osx >/dev/null; then
    fail 'Quit Steam first, then run this launcher again.'
fi
if [[ -z ${STEAM_EXE:-} ]]; then
    STEAM_EXE="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx"
    [[ -x $STEAM_EXE ]] || STEAM_EXE=/Applications/Steam.app/Contents/MacOS/steam_osx
fi
[[ -x $STEAM_EXE ]] || fail 'Steam executable not found. Set STEAM_EXE.'
[[ -f $ROOT/out/onlinefix.dylib ]] || fail 'Run make first.'
[[ -z ${DYLD_INSERT_LIBRARIES:-} ]] || fail 'Unset DYLD_INSERT_LIBRARIES before launching standalone OnlineFix.'
[[ $ROOT != *:* ]] || fail 'Project path cannot contain a colon.'
export ONLINEFIX_SIG=${ONLINEFIX_SIG:-"$ROOT/signatures/macos.arm64"}
[[ -r $ONLINEFIX_SIG ]] || fail "Cannot read signature profile: $ONLINEFIX_SIG"
export ONLINEFIX_LOG=${ONLINEFIX_LOG:-"$ROOT/out/onlinefix.log"}
CONFIG_DEFAULT="$HOME/Library/Application Support/OnlineFixManager/games.json"
if [[ -z ${ONLINEFIX_CONFIG:-} && -f $CONFIG_DEFAULT ]]; then
    export ONLINEFIX_CONFIG="$CONFIG_DEFAULT"
fi
export DYLD_INSERT_LIBRARIES="$ROOT/out/onlinefix.dylib"
cd "$(dirname "$STEAM_EXE")"
exec "$STEAM_EXE" "$@"
