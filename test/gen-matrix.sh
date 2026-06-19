#!/usr/bin/env bash
# Generate one ASCII screenshot per (start, spin) combo — 4 starts × 4 spins = 16 —
# into screenshots/<start>-<spin>.txt, each prefixed with a header line naming the
# combo and the fixed 5-pane MRU order. spin is a pattern × turn:
# {Pinwheel,Staircase} × {Cw,Ccw}. Runs the combos sequentially (each is a fresh
# headless zellij session) so resource use stays bounded and every session is reaped.
#
# Usage:  test/gen-matrix.sh [n_panes]   (default 5)

set -u

PROJECT_DIR="${PROJECT_DIR:-/home/bot/zellij-spiral}"
OUT="${OUT:-$PROJECT_DIR/screenshots}"
SHOT="$PROJECT_DIR/test/screenshot.sh"
N="${1:-5}"
mkdir -p "$OUT"

STARTS=(Top Bottom Left Right)
SPINS=(PinwheelCw PinwheelCcw StaircaseCw StaircaseCcw)

count=0
for start in "${STARTS[@]}"; do
  for spin in "${SPINS[@]}"; do
    f="$OUT/${start}-${spin}.txt"
    echo ">>> $start / $spin -> $f"
    {
      echo "# zellij-spiral  start=$start  spin=$spin  (MRU 1=focused/dominant .. $N=corner)"
      bash "$SHOT" "$start" "$spin" "$N"
    } > "$f" 2>>"${MATRIX_ERR:-/dev/null}"
    # Sanity: EVERY pane 1..N must appear in the diagram (header line excluded). The
    # renderer once dropped children past the second of a zellij-flattened same-axis
    # split (the missing-pane bug); assert the full set so a regression — or a
    # scrambled-MRU headless race — is never silently trusted.
    present="$(tail -n +2 "$f" | grep -oE '[0-9]+' | sort -un | tr '\n' ' ')"
    miss=""
    for k in $(seq 1 "$N"); do case " $present " in *" $k "*) ;; *) miss="$miss $k";; esac; done
    [ -n "$miss" ] && echo "WARN: $f missing pane(s):$miss (present: $present)" >&2
    count=$((count + 1))
  done
done
echo "generated $count screenshots in $OUT"
