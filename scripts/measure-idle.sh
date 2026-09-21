#!/bin/bash
#
# What the menu-bar process costs while nobody is looking at it.
#
# Written after a claim that did not hold: two four-minute runs, 0.079 % of a
# core against 0.095, were read as one change costing a fifth of the budget.
# They were the two ends of the noise. An idle laptop is not idle — Spotlight
# indexes, the media analyser wakes, a browser tab animates — and a single
# window says less than it appears to.
#
# So: several windows, and the spread reported beside the middle value. A
# difference smaller than the spread is not a difference.
#
# Usage:  ./scripts/measure-idle.sh [runs] [seconds-per-run]
set -euo pipefail
cd "$(dirname "$0")/.."

RUNS="${1:-5}"
WINDOW="${2:-120}"
BIN="$(swift build -c release --show-bin-path)/Zephyr"
[ -x "$BIN" ] || { echo "build it first: swift build -c release" >&2; exit 1; }

echo "==> $RUNS runs of ${WINDOW}s"
# One launch for all of them: relaunching would measure the warm-up, which is
# the expensive part and not the thing being asked about.
"$BIN" >/dev/null 2>&1 &
AGENT=$!
trap 'kill $AGENT 2>/dev/null || true' EXIT
sleep 25   # long enough for the caches to settle; measured at about 20s

cpu_seconds() {
    python3 - "$(ps -o time= -p "$AGENT" | tr -d ' ')" <<'PY'
import sys
total = 0.0
for part in sys.argv[1].split(':'):
    total = total * 60 + float(part)
print(total)
PY
}

RESULTS=()
for i in $(seq 1 "$RUNS"); do
    BEFORE=$(cpu_seconds); START=$(date +%s)
    sleep "$WINDOW"
    AFTER=$(cpu_seconds); END=$(date +%s)
    PERCENT=$(python3 -c "print('%.3f' % (($AFTER - $BEFORE) / ($END - $START) * 100))")
    echo "   run $i: ${PERCENT}% of a core"
    RESULTS+=("$PERCENT")
done

FOOTPRINT=$(/usr/bin/vmmap -summary "$AGENT" 2>/dev/null | awk '/Physical footprint:/{print $3}')
python3 - "$FOOTPRINT" "${RESULTS[@]}" <<'PY'
import sys
footprint, values = sys.argv[1], sorted(float(v) for v in sys.argv[2:])
middle = values[len(values) // 2]
spread = values[-1] - values[0]
print()
print("   middle   %.3f %% of a core" % middle)
print("   spread   %.3f (%.3f to %.3f)" % (spread, values[0], values[-1]))
print("   memory   %s" % footprint)
print()
print("A change worth less than %.3f %% cannot be told apart from the machine's" % spread)
print("own background work by this method. Say so rather than reporting it.")
PY
