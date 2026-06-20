#!/usr/bin/env bash
# Headless self-test for the zellij-spiral plugin, run against the FORKED zellij
# binary (the fork adds override_layout_with_pane_ordering — the per-slot pane
# binding stock zellij lacks).
#
# Proves, with no human keypress, two things:
#   1. STRUCTURE — on a focus change the plugin arranges the tab's terminal panes
#      into the recursive golden spiral it emits for N panes.
#   2. IDENTITY (the point of the fork) — the FOCUSED pane lands in the dominant
#      slot, and that re-keys with focus: focus a different pane and a different
#      pane becomes dominant.
#
# The only thing that normally needs a human is granting the plugin's
# ReadApplicationState + ChangeApplicationState permissions; we grant them by
# pre-writing zellij's on-disk permission cache (see GRANT below).
#
# Point it at the forked binary (built per the project README), e.g.:
#   ZELLIJ_BIN=/tmp/ws/zellij/target/release/zellij \
#     /home/bot/zellij-spiral/test/headless-test.sh
# Defaults to $ZELLIJ_BIN, else a `zellij` on PATH.
#
# Exit status: 0 = PASS, 1 = FAIL.
#
# ---------------------------------------------------------------------------
# One harness reality this test works around
# ---------------------------------------------------------------------------
# * Real pane sizes need a real pty size. dump-layout reconstructs split sizes
#   from live geometry; with a zero/tiny pty the 62% master split reads back as an
#   even 50%. We force `stty rows 50 cols 200` inside the session so the spiral
#   renders at its true proportions and the dominant pane is unambiguous. (The
#   structural skeleton check is size-agnostic and so is robust either way.)
#
# The re-keying check (check 2) changes focus inside ONE live session (focus-pane-id)
# and asserts the dominant pane follows. This requires the fork to keep delivering
# PaneUpdate to a self-hidden plugin: hide_self() suppresses the plugin pane, and
# stock zellij drops suppressed plugins from the active-tab event broadcast, so the
# spiral would go deaf the moment it hid and never re-tile on a later focus change.
# The fork includes suppressed plugins in that broadcast (Screen::targeted_plugin_ids
# via Tab::get_all_plugin_ids), so a pure focus change alone re-keys the spiral.

set -u

ZJ="${ZELLIJ_BIN:-$(command -v zellij || true)}"
[ -n "$ZJ" ] && [ -x "$ZJ" ] || { echo "FAIL: no zellij binary (set ZELLIJ_BIN to the forked ./target/release/zellij)"; exit 1; }
echo "using zellij: $ZJ ($("$ZJ" --version 2>/dev/null))"

PROJECT_DIR="${PROJECT_DIR:-/home/bot/zellij-spiral}"
WASM="$PROJECT_DIR/target/wasm32-wasip1/release/zellij-spiral.wasm"
[ -f "$WASM" ] || { echo "FAIL: wasm not found at $WASM — build it: cargo build --release --target wasm32-wasip1"; exit 1; }
echo "using plugin wasm: $WASM"

fail() { echo "FAIL: $*"; cleanup; exit 1; }

# Per-test scratch + a private TMPDIR so the zellij server log is isolated.
ROOT="$(mktemp -d /tmp/zspiral-test.XXXXXX)"
CFG="$ROOT/cfg"; CACHE="$ROOT/cache"
mkdir -p "$CFG" "$CACHE/zellij"
export ZELLIJ_CONFIG_DIR="$CFG" XDG_CACHE_HOME="$CACHE"
export TMPDIR="$ROOT/tmp"; mkdir -p "$TMPDIR/zellij-$(id -u)/zellij-log"

SESSIONS=()
cleanup() {
  for s in "${SESSIONS[@]:-}"; do "$ZJ" delete-session "$s" --force >/dev/null 2>&1; done
  rm -rf "$ROOT"
}
trap cleanup EXIT

# Pre-write the permission grant so the interactive prompt is skipped (the cache
# key is the plugin's file path; children are the PermissionType variant names).
printf '"%s" {\n    ReadApplicationState\n    ChangeApplicationState\n}\n' "$WASM" \
  > "$CACHE/zellij/permissions.kdl"
# Minimal config: suppress the first-run wizard / release notes (modal, breaks
# headless driving).
printf 'show_startup_tips false\nshow_release_notes false\npane_frames true\n' > "$CFG/config.kdl"

# Start a session in a real pty (script provides one; stty gives it a real size so
# the 62% master split renders true). Returns once the session is listed.
start_session() {
  local s="$1"; SESSIONS+=("$s")
  setsid script -qfc \
    "stty rows 50 cols 200; TMPDIR='$TMPDIR' ZELLIJ_CONFIG_DIR='$CFG' XDG_CACHE_HOME='$CACHE' '$ZJ' -s '$s'" \
    "$ROOT/$s.pty" >/dev/null 2>&1 &
  local up=
  for _ in $(seq 1 20); do "$ZJ" list-sessions 2>/dev/null | grep -q "$s" && { up=1; break; }; sleep 0.5; done
  [ -n "$up" ] || fail "session $s did not start"
  sleep 1
}
act() { "$ZJ" -s "$1" action "${@:2}" 2>/dev/null; }

# Isolate the live tab's tiled-pane block (dump-layout emits the live layout first,
# then new_tab_template + swap_* templates we must ignore).
live_tab() {
  awk '
    /^[[:space:]]*tab name=/ { intab=1; next }
    intab && /^[[:space:]]*(floating_panes|new_tab_template|swap_tiled_layout|swap_floating_layout)/ { exit }
    intab { print }'
}

# Reduce the live tab to a structural skeleton (one token/line): split openers with
# direction, leaves, closing braces — sizes/names/UI-bars dropped. split_direction
# defaults to horizontal when omitted.
skeleton() {
  live_tab \
    | grep -vE 'borderless|plugin |floating_panes|tab name=|^layout |^\}' \
    | sed -E '
        s/^[[:space:]]+//
        /^pane[[:space:]].*split_direction="vertical".*\{$/   { s/.*/V{/; b }
        /^pane[[:space:]].*split_direction="horizontal".*\{$/ { s/.*/H{/; b }
        /^pane.*\{$/                                          { s/.*/H{/; b }
        /^pane([[:space:]].*)?$/                              { s/.*/leaf/; b }
        /^\}$/                                                { s/.*/}/;    b }
        d'
}

# The exact skeleton the plugin must produce for N panes (mirrors spiral_kdl() in
# src/main.rs, skeleton only): outermost split vertical, peel one leaf off the
# trailing side per level, recurse on the leading side flipping direction, base
# case a single leaf.
expected_skeleton() {
  local n="$1" vertical=1 k="$n" d
  while [ "$k" -gt 1 ]; do
    [ "$vertical" -eq 1 ] && echo "V{" || echo "H{"
    vertical=$((1 - vertical)); k=$((k - 1))
  done
  echo leaf
  d=$((n - 1))
  while [ "$d" -gt 0 ]; do echo leaf; echo "}"; d=$((d - 1)); done
}

# The DOMINANT spiral leaf from a live tab: the LAST named pane leaf in textual
# order. The caterpillar spiral nests { recursion, dominant } at every level, so
# the root's dominant — the full-height trailing pane — is always the final leaf.
# Size-agnostic (robust whether the split reads back as 62% or an even 50%); the
# earlier depth-tracking awk was fragile and could misread the dominant.
dominant_leaf() {
  live_tab | grep -v 'split_direction' | grep -oE 'pane name="[A-Za-z0-9]+"' \
    | tail -1 | grep -oE '"[A-Za-z0-9]+"' | tr -d '"'
}

# ===========================================================================
# Check 1 — STRUCTURE: the spiral skeleton for N panes.
# ===========================================================================
run_structure() {
  local n="$1"; local s="zspiral-skel-$$-$n"; local after
  start_session "$s"
  local i; for i in $(seq 1 $((n - 1))); do act "$s" new-pane; sleep 0.6; done
  act "$s" launch-or-focus-plugin --floating "file:$WASM"; sleep 3
  act "$s" toggle-floating-panes; sleep 1
  act "$s" move-focus left; sleep 1.5
  after="$(act "$s" dump-layout)"

  local got want leaves
  got="$(printf '%s\n' "$after" | skeleton)"
  want="$(expected_skeleton "$n")"
  echo; echo "--- N=$n live spiral skeleton ---"; echo "$got"

  leaves="$(printf '%s\n' "$got" | grep -c '^leaf$')"
  [ "$leaves" -eq "$n" ] || fail "expected $n leaves, found $leaves (N=$n)"
  [ "$(printf '%s\n' "$got" | head -1)" = "V{" ] || fail "outermost split not vertical (N=$n)"
  [ "$got" = "$want" ] || { echo "--- expected ---"; echo "$want"; fail "skeleton mismatch (N=$n)"; }
  echo "PASS structure: N=$n is the recursive golden spiral ($leaves leaves, vertical root)."
  "$ZJ" delete-session "$s" --force >/dev/null 2>&1; sleep 0.5
}

# ===========================================================================
# Check 2 — IDENTITY + RE-KEYING: the focused pane is the dominant pane, and the
# dominant pane follows focus *live* — a pure `move-focus` within one session
# re-tiles so the newly-focused pane takes the dominant slot. This is the whole
# point of the plugin (focused == most-recently-focused == dominant) and exercises
# the fork's suppressed-plugin event delivery: the spiral hides itself, yet must
# keep getting PaneUpdate on every focus move (see header).
# ===========================================================================
# Three plain shells named A,B,C (pane ids terminal_0..2). After load, focus each
# by id and assert the focused pane is the dominant (outermost full-height trailing)
# pane — the spiral re-keys to whatever pane currently holds focus. We assert the
# invariant directly (focused-name == dominant-name) rather than hardcoding which
# name a given id carries, so it can't drift with pane-creation order; and we
# require all three distinct panes to take a turn as dominant, so a plugin that
# froze on one pane (the pre-fix deaf-after-hide bug) still fails.
run_identity() {
  local s="zspiral-id-$$"; local tid focused dom; local -A seen=()
  start_session "$s"
  act "$s" rename-pane "A"; sleep 0.3
  act "$s" new-pane; sleep 0.5; act "$s" rename-pane "B"; sleep 0.3
  act "$s" new-pane; sleep 0.5; act "$s" rename-pane "C"; sleep 0.3
  act "$s" launch-or-focus-plugin --floating "file:$WASM"; sleep 3
  act "$s" toggle-floating-panes; sleep 1.5
  for tid in terminal_0 terminal_1 terminal_2; do
    # A pure focus change — no pane opened or closed. The dominant slot must follow.
    act "$s" focus-pane-id "$tid"; sleep 1.5
    local dump; dump="$(act "$s" dump-layout)"
    focused="$(printf '%s\n' "$dump" | live_tab | grep 'focus=true' \
      | grep -oE 'name="[A-Za-z0-9]+"' | grep -oE '"[A-Za-z0-9]+"' | tr -d '"' | head -1)"
    dom="$(printf '%s\n' "$dump" | dominant_leaf)"
    echo "  focus $tid -> focused=${focused:-<none>} dominant=${dom:-<none>}"
    [ -n "$focused" ] || fail "no focused pane after focus-pane-id $tid"
    [ "$dom" = "$focused" ] || fail "focused pane $focused is not dominant (got '${dom:-<none>}') after focusing $tid"
    seen["$dom"]=1
  done
  [ "${#seen[@]}" -eq 3 ] || fail "expected 3 distinct panes to take the dominant slot, saw ${#seen[@]} (${!seen[*]})"
  echo "  3 distinct panes each became dominant when focused: ${!seen[*]}"
  "$ZJ" delete-session "$s" --force >/dev/null 2>&1; sleep 0.5
}

echo
echo "########## Check 1: spiral structure ##########"
run_structure 4
run_structure 3

echo
echo "########## Check 2: focused pane is dominant, and re-keys with focus ##########"
run_identity
echo "PASS identity: a pure focus change re-keys the dominant slot to the focused pane."

echo
echo "PASS: zellij-spiral builds the recursive golden spiral AND puts the focused pane in the dominant slot, re-keyed by focus (forked override_layout_with_pane_ordering)."
exit 0
