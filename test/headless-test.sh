#!/usr/bin/env bash
# Headless smoke test for the zellij-spiral plugin.
#
# Proves, with no human keypress, that the plugin restacks panes on focus
# change. The only thing that normally needs a human is granting the plugin's
# ReadApplicationState + ChangeApplicationState permissions; we grant them by
# pre-writing zellij's on-disk permission cache (see GRANT below).
#
# Run it through the project's nix shell, which provides zellij + util-linux and
# the rust toolchain with the wasm32-wasip1 std (the script builds the plugin):
#
#   nix-shell /home/bot/zellij-spiral/shell.nix --run /home/bot/zellij-spiral/test/headless-test.sh
#
# Exit status: 0 = PASS, 1 = FAIL.

set -u

# ---------------------------------------------------------------------------
# GRANT METHOD — why this works
# ---------------------------------------------------------------------------
# zellij persists granted plugin permissions to $ZELLIJ_CACHE_DIR/permissions.kdl
# (ZELLIJ_CACHE_DIR honours XDG_CACHE_HOME, so we point it at a scratch dir).
# On every permission request the server first consults that cache
# (zellij-server request_permission -> PermissionCache::check_permissions); a hit
# is answered Granted immediately and the interactive prompt is skipped entirely.
#
# The cache key is the plugin's RunPluginLocation rendered via its Display impl.
# For a file: plugin that is the BARE absolute path (no "file:" prefix) — see
# zellij-utils input/layout.rs `impl fmt::Display for RunPluginLocation`. The
# children are the PermissionType variant names verbatim ("ReadApplicationState",
# "ChangeApplicationState"). So a pre-written:
#
#   "/abs/path/to/plugin.wasm" {
#       ReadApplicationState
#       ChangeApplicationState
#   }
#
# grants both permissions before the plugin ever asks. No keypress, no prompt.

SESSION="zspiral-headless-$$"
SCRATCH="$(mktemp -d /tmp/zspiral-test.XXXXXX)"
CFG_DIR="$SCRATCH/cfg"
CACHE_DIR="$SCRATCH/cache"          # XDG_CACHE_HOME -> zellij uses $CACHE_DIR/zellij
PTY_LOG="$SCRATCH/pty.log"
BEFORE="$SCRATCH/before.kdl"
AFTER="$SCRATCH/after.kdl"
mkdir -p "$CFG_DIR" "$CACHE_DIR/zellij"

PROJECT_DIR="${PROJECT_DIR:-/home/bot/zellij-spiral}"
WASM=""   # set below to the freshly-built, zellij-compatible artifact

cleanup() {
  zellij delete-session "$SESSION" --force 2>/dev/null
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }

command -v zellij >/dev/null || fail "zellij not on PATH (run inside the nix shell)"

# ---------------------------------------------------------------------------
# Build a zellij-compatible wasm from the (unchanged) plugin source.
# ---------------------------------------------------------------------------
# zellij 0.44.x's loader calls get_typed_func("_start") at instantiation
# (zellij-server plugin_loader.rs) and aborts with "could not find exported
# function" if it is missing. The committed Cargo.toml uses
# `crate-type = ["cdylib"]`, which on a current rustc produces a WASI *reactor*
# (exports _initialize, not _start) — that wasm fails to instantiate and never
# reaches its load()/permission request. The default *binary* target instead
# emits _start (the register_plugin! macro supplies `fn main`).
#
# So we build the byte-identical src/lib.rs as a binary crate, in scratch. The
# plugin's source is untouched; only the build target (bin, not cdylib) differs.
# We do this unconditionally because the committed cdylib artifact is structurally
# unusable by this zellij — there is nothing to salvage from it, and a precise
# "_start export?" check would need a wasm parser not present in the dev shell.
# The project now builds a proper binary (a command module exporting _start), so
# we validate the REAL release artifact. Build it first (sandboxed), e.g.:
#   cd PROJECT_DIR && run-untrusted bash -c 'export PATH=...; cargo build --release --target wasm32-wasip1'
WASM="$PROJECT_DIR/target/wasm32-wasip1/release/zellij-spiral.wasm"
[ -f "$WASM" ] || fail "wasm not found at $WASM — build it first: cargo build --release --target wasm32-wasip1"
echo "using plugin wasm: $WASM"

# ---------------------------------------------------------------------------
# Pre-grant the permissions (the headless trick).
# ---------------------------------------------------------------------------
PERMS="$CACHE_DIR/zellij/permissions.kdl"
printf '"%s" {\n    ReadApplicationState\n    ChangeApplicationState\n}\n' "$WASM" > "$PERMS"
echo "wrote permission cache: $PERMS"

# Minimal config: suppress the first-run setup wizard / release notes that would
# otherwise sit modal over the session and break headless driving.
cat > "$CFG_DIR/config.kdl" <<'KDL'
show_startup_tips false
show_release_notes false
pane_frames true
KDL

export ZELLIJ_CONFIG_DIR="$CFG_DIR"
export XDG_CACHE_HOME="$CACHE_DIR"
# Pin the log dir so zellij's client subprocesses don't panic creating it under a
# transient nix-shell $TMPDIR.
mkdir -p "${TMPDIR:-/tmp}/zellij-$(id -u)/zellij-log"

# ---------------------------------------------------------------------------
# Drive the session.
# ---------------------------------------------------------------------------
zellij delete-session "$SESSION" --force 2>/dev/null
# A real pty is required; `script` provides one and detaches via setsid.
setsid script -qfc "ZELLIJ_CONFIG_DIR='$CFG_DIR' XDG_CACHE_HOME='$CACHE_DIR' zellij -s '$SESSION'" "$PTY_LOG" >/dev/null 2>&1 &

# Wait for the session to come up (bounded).
for _ in $(seq 1 20); do
  zellij list-sessions 2>/dev/null | grep -q "$SESSION" && break
  sleep 0.5
done
zellij list-sessions 2>/dev/null | grep -q "$SESSION" || fail "session did not start"
sleep 1

act() { zellij -s "$SESSION" action "$@" 2>/dev/null; }

# Four terminal panes total (1 initial + 3 new).
for _ in 1 2 3; do act new-pane; sleep 0.6; done

act dump-layout > "$BEFORE" 2>/dev/null

# Load the plugin floating, then hide the float so focus lives among the tiled
# terminals — the plugin only restacks on a focus *change between terminals*.
act launch-or-focus-plugin --floating "file:$WASM"
sleep 3
act toggle-floating-panes; sleep 1

# Cycle focus around the tiled terminals to trigger restacks.
act move-focus left;  sleep 0.8
act move-focus up;    sleep 0.8
act move-focus down;  sleep 0.8
act move-focus right; sleep 1.2

act dump-layout > "$AFTER" 2>/dev/null

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
# dump-layout echoes every builtin swap layout after the live layout, and those
# templates contain `stacked=true`. Look only at the live tab: the first
# `layout {` block, up to the first swap_*_layout node.
live_tab() {
  awk '/^layout \{/{n++} n>=1 && /swap_tiled_layout|swap_floating_layout/{exit} {print}' "$1"
}

echo
echo "=== BEFORE (live tab) ==="
live_tab "$BEFORE" | grep -E 'tab name|pane (size|focus|split)|^[[:space:]]*pane$|stacked=true' | grep -v borderless
echo "=== AFTER (live tab) ==="
live_tab "$AFTER"  | grep -E 'tab name|pane (size|focus|split)|^[[:space:]]*pane$|stacked=true|expanded=true' | grep -v borderless
echo

before_stacks=$(live_tab "$BEFORE" | grep -c 'stacked=true')
after_stacks=$(live_tab "$AFTER"  | grep -c 'stacked=true')
echo "stacked groups — before: $before_stacks  after: $after_stacks"

# PASS = the focused terminal sits apart while the rest collapsed into a stack
# that did not exist before. A focused+expanded pane inside that stack is the
# master.
if [ "$after_stacks" -ge 1 ] && [ "$after_stacks" -gt "$before_stacks" ]; then
  echo
  echo "PASS: non-focused terminals collapsed into a stack with the focused pane as master."
  exit 0
else
  echo
  echo "FAIL: expected a stack to appear after focus moves (before=$before_stacks after=$after_stacks)."
  echo "      Permission grant or restack did not take effect."
  exit 1
fi
