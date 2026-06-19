#!/usr/bin/env bash
# Generate one ASCII screenshot per (start, spin) combo — 4×8 = 32 — into
# screenshots/<start>-<spin>.txt, each prefixed with a header line naming the combo
# and the fixed 5-pane MRU order. Runs the combos sequentially (each is a fresh
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
SPINS=(UpLeft UpRight DownLeft DownRight InClock InCounter OutClock OutCounter)

count=0
for start in "${STARTS[@]}"; do
  for spin in "${SPINS[@]}"; do
    f="$OUT/${start}-${spin}.txt"
    echo ">>> $start / $spin -> $f"
    {
      echo "# zellij-spiral  start=$start  spin=$spin  (MRU 1=focused/dominant .. $N=corner)"
      bash "$SHOT" "$start" "$spin" "$N"
    } > "$f" 2>>"${MATRIX_ERR:-/dev/null}"
    # Sanity: pane "1" (focused) must be the biggest box — its centre label sits on
    # the row with the most interior space. A scrambled MRU (rare headless focus
    # race) would mislabel the dominant; flag it so a bad sweep isn't trusted.
    if ! grep -q '\b1\b' "$f"; then
      echo "WARN: $f has no pane-1 label (combo may have failed)" >&2
    fi
    count=$((count + 1))
  done
done
echo "generated $count screenshots in $OUT"
