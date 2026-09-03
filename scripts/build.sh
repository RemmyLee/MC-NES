#!/bin/sh
# Compile MC-NES with Quartus Prime Lite 17.0.2 and stamp the output.
# Usage: scripts/build.sh [YYYYMMDD]
set -eu

cd "$(dirname "$0")/.."
DATE="${1:-$(date +%Y%m%d)}"
QUARTUS="${QUARTUS:-$HOME/intelFPGA_lite/17.0/quartus/bin}"
export PATH="$QUARTUS:$PATH"

UPSTREAM="$(git rev-parse --short HEAD)"
START="$(date +%s)"

quartus_sh --flow compile NES > build.log 2>&1 || {
    echo "build failed, see build.log" >&2
    grep -n "^Error" build.log | head -20 >&2
    exit 1
}

END="$(date +%s)"
mkdir -p out
cp output_files/NES.rbf "out/MC-NES_$DATE.rbf"
{
    echo "MC-NES_$DATE.rbf"
    echo "commit: $UPSTREAM"
    echo "wall: $((END - START)) s"
    echo "critical warnings: $(grep -c "Critical Warning" build.log || true)"
    echo
    cat output_files/NES.fit.summary
    echo
    cat output_files/NES.sta.summary
} > "out/MC-NES_$DATE.txt"

# Quartus rewrites the project file on every run; keep the tree clean.
git checkout NES.qsf

sha256sum "out/MC-NES_$DATE.rbf"
grep -n "Slack" "out/MC-NES_$DATE.txt" | head -3
