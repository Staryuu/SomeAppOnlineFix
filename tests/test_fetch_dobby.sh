#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/project/scripts" "$TEMP/bin" "$TEMP/fixture/dobby/include"
cp "$ROOT/scripts/fetch-dobby.sh" "$TEMP/project/scripts/"
touch "$TEMP/fixture/dobby/include/dobby.h" "$TEMP/fixture/dobby/CMakeLists.txt" "$TEMP/fixture/dobby/LICENSE"
tar -czf "$TEMP/source.tar.gz" -C "$TEMP/fixture" dobby
cat > "$TEMP/bin/curl" <<'SH'
#!/bin/bash
[[ ${FETCH_FAIL:-0} == 0 ]] || exit 22
cp "$FETCH_FIXTURE" "${!#}"
SH
chmod +x "$TEMP/bin/curl"
export PATH="$TEMP/bin:$PATH" FETCH_FIXTURE="$TEMP/source.tar.gz"
if FETCH_FAIL=1 bash "$TEMP/project/scripts/fetch-dobby.sh"; then exit 1; fi
[[ ! -e $TEMP/project/vendor/dobby ]]
[[ -z $(find "$TEMP/project/vendor" -name '.dobby-*' -print) ]]
bash "$TEMP/project/scripts/fetch-dobby.sh"
[[ -f $TEMP/project/vendor/dobby/include/dobby.h ]]
echo preserved > "$TEMP/project/vendor/dobby/local-change"
if bash "$TEMP/project/scripts/fetch-dobby.sh"; then exit 1; fi
[[ $(cat "$TEMP/project/vendor/dobby/local-change") == preserved ]]
echo 'Dobby fetch checks passed: extraction, failure cleanup, existing directory preservation.'
