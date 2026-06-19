#!/usr/bin/env bash
# Drive the forked zellij headless, load the spiral plugin with a given
# (start, direction) config, set a fixed 5-pane MRU order, dump the layout, and
# render it as ASCII via render-ascii.js. Prints the ASCII to stdout.
#
# Usage:  screenshot.sh <start> <direction> [n_panes]
#   e.g.  screenshot.sh Right InClock 5
# Env:    ZELLIJ_BIN  (default: the prebuilt fork)
#         WASM        (default: this repo's release wasm)
#
# MRU convention: panes are named "1".."N" and focused in REVERSE (N..1) so that
# pane "1" is focused last and therefore most-recent (dominant); "N" is the
# least-recent (innermost corner). That fixed order makes every combo's screenshot
# directly comparable.

set -u

ZJ="${ZELLIJ_BIN:-/home/bot/.local/state/zellij-fork/zellij}"
PROJECT_DIR="${PROJECT_DIR:-/home/bot/zellij-spiral}"
WASM="${WASM:-$PROJECT_DIR/target/wasm32-wasip1/release/zellij-spiral.wasm}"
RENDER="$PROJECT_DIR/test/render-ascii.js"

START="${1:?need start}"; DIRECTION="${2:?need direction}"; N="${3:-5}"

[ -x "$ZJ" ] || { echo "no zellij binary at $ZJ" >&2; exit 1; }
[ -f "$WASM" ] || { echo "no wasm at $WASM (build it first)" >&2; exit 1; }

ROOT="$(mktemp -d /tmp/zspiral-shot.XXXXXX)"
CFG="$ROOT/cfg"; CACHE="$ROOT/cache"
mkdir -p "$CFG" "$CACHE/zellij"
# Export the SAME private TMPDIR the server runs under, so the outer-shell client
# calls (`list-sessions`, `action …`) resolve the server socket zellij puts under
# $TMPDIR. Without this the client probes the default /tmp and never sees the
# session ("session did not start" despite a healthy server).
export ZELLIJ_CONFIG_DIR="$CFG" XDG_CACHE_HOME="$CACHE"
export TMPDIR="$ROOT/tmp"; mkdir -p "$TMPDIR/zellij-$(id -u)/zellij-log"

s="zspiral-shot-$$-$START-$DIRECTION"
cleanup() {
  "$ZJ" delete-session "$s" --force >/dev/null 2>&1
  # delete-session leaves the per-session server (its client pty is a stuck
  # `script`); reap both by matching this run's unique private $ROOT in their
  # argv (the server runs `--server $ROOT/tmp/…`, the pty `script … $ROOT/…`).
  # Substring match, so it never touches another run's or our own shell.
  for pid in $(pgrep -f "$ROOT" 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
  rm -rf "$ROOT"
}
trap cleanup EXIT

# Grant the plugin's permissions without the interactive prompt.
printf '"%s" {\n    ReadApplicationState\n    ChangeApplicationState\n}\n' "$WASM" \
  > "$CACHE/zellij/permissions.kdl"
printf 'show_startup_tips false\nshow_release_notes false\npane_frames true\n' > "$CFG/config.kdl"

setsid script -qfc \
  "stty rows 50 cols 200; TMPDIR='$TMPDIR' ZELLIJ_CONFIG_DIR='$CFG' XDG_CACHE_HOME='$CACHE' '$ZJ' -s '$s'" \
  "$ROOT/$s.pty" >/dev/null 2>&1 &
up=
for _ in $(seq 1 40); do "$ZJ" list-sessions 2>/dev/null | grep -q "$s" && { up=1; break; }; sleep 0.5; done
[ -n "$up" ] || { echo "session did not start" >&2; exit 1; }
sleep 1.5

act() { "$ZJ" -s "$s" action "${@:2}" >/dev/null 2>&1; }

# N panes named 1..N (pane 1 already exists as the first pane).
act "$s" rename-pane "1"; sleep 0.3
for i in $(seq 2 "$N"); do act "$s" new-pane; sleep 0.5; act "$s" rename-pane "$i"; sleep 0.3; done

# Set the MRU: focus N, N-1, …, 1 so pane "1" is most-recent (dominant). Pane k is
# terminal_(k-1). Focus BEFORE the plugin loads so the first (reliably delivered)
# relayout keys on pane 1 — see headless-test.sh on why post-load focus is flaky.
#
# The plugin derives its MRU from the ORDER it observes focus events, so each
# focus-pane-id must settle (its PaneUpdate delivered) before the next, or the MRU
# scrambles and the geometry mirrors/rotates wrongly. Under load (a 32-combo sweep)
# a short sleep isn't enough, so confirm each focus actually landed by polling the
# dump's `focus=true` terminal before moving on — deterministic regardless of load.
# focus_pane NAME — focus the pane named NAME (its terminal id is NAME-1) and wait
# until the dump shows that pane as `focus=true` (a focused terminal renders as
# `pane name="NAME" focus=true …`).
focus_pane() {
  local name="$1"
  act "$s" focus-pane-id "terminal_$((name - 1))"
  for _ in $(seq 1 25); do
    "$ZJ" -s "$s" action dump-layout 2>/dev/null \
      | grep -qE "name=\"$name\" focus=true" && return 0
    sleep 0.2
  done
  sleep 0.3 # proceed anyway; an unconfirmed focus is rare and still recorded
}
for i in $(seq "$N" -1 1); do focus_pane "$i"; done

# Load the plugin with the (start, spin) config. zellij passes
# `--configuration k=v,k=v` through to the plugin's load() — but it RESERVES and
# strips the key `direction`, so the rotation is passed as `spin=` (the plugin reads
# `spin`; see src/main.rs load()).
act "$s" launch-or-focus-plugin --floating --skip-plugin-cache \
  --configuration "start=$START,spin=$DIRECTION" "file:$WASM"
sleep 3
act "$s" toggle-floating-panes; sleep 1.5

DUMP="$("$ZJ" -s "$s" action dump-layout 2>/dev/null)"
# Opt-in: stash the raw dump for debugging the renderer (set DUMP_FILE to a path).
[ -n "${DUMP_FILE:-}" ] && printf '%s\n' "$DUMP" > "$DUMP_FILE"
printf '%s\n' "$DUMP" | node "$RENDER"
