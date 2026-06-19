//! zellij-spiral — arrange the terminal panes of the active tab into a recursive
//! golden spiral, re-keyed on every focus change so the focused (most-recently-
//! focused) pane occupies the dominant slot.
//!
//! The spiral peels one pane per level into the trailing (right, then bottom,
//! alternating) side and recurses into the remainder, so the dominant slot is the
//! full-height pane on the right and the least-dominant pane ends alone in the
//! innermost corner:
//!
//! ```text
//!  +-------------+--------+
//!  |             |        |
//!  +------+------+ domin- |
//!  |      |      |  ant   |
//!  | …    |      |        |
//!  +------+------+--------+
//! ```
//!
//! Panes are bound to slots by most-recently-focused order: the focused pane gets
//! the dominant slot, the next-most-recent the next slot, and so on down to the
//! innermost corner. This requires the forked zellij's
//! `override_layout_with_pane_ordering`, which lets the plugin pass an explicit
//! pane-id -> leaf-slot binding. Stock `override_layout` binds retained panes to
//! slots by zellij's internal pane-id order, which the plugin cannot influence —
//! so without the fork the geometry is right but the wrong pane is dominant.

use std::collections::BTreeMap;
use zellij_tile::prelude::*;

/// The default master share — the golden ratio's larger part (φ⁻¹ ≈ 0.618). The
/// dominant pane at each level gets this fraction; the recursion gets the rest.
const DEFAULT_MASTER_SIZE: &str = "62%";

#[derive(Default)]
struct State {
    /// Terminal pane ids in most-recently-focused order: `mru[0]` is the currently
    /// focused pane, `mru[1]` the previously focused, and so on. Drives both when we
    /// relayout (only on a focus change) and which pane lands in which slot.
    mru: Vec<u32>,
    /// The focused pane as of our last relayout, or `None` before the first. The
    /// change-guard keys off this rather than `mru.first()` so the FIRST relayout
    /// still fires when the focused pane is already first in the freshly-built MRU
    /// (e.g. it has the lowest pane id) — otherwise that pane never gets its spiral.
    last_focused: Option<u32>,
    /// Each dominant pane's share of its split, e.g. `"62%"`. From the plugin's
    /// `master_size` config; the recursion gets the complement.
    master_size: String,
}

register_plugin!(State);

impl ZellijPlugin for State {
    fn load(&mut self, configuration: BTreeMap<String, String>) {
        // Only accept a well-formed percentage (e.g. "62%"); anything else falls
        // back to the default. This keeps a typo'd config from silently breaking
        // every relayout (a malformed `size=` makes the whole layout fail to
        // parse) and keeps the value from injecting arbitrary KDL into the layout.
        self.master_size = configuration
            .get("master_size")
            .filter(|s| is_percentage(s))
            .cloned()
            .unwrap_or_else(|| DEFAULT_MASTER_SIZE.to_string());
        // Hide from the tiled grid: this plugin renders nothing, and staying out
        // of the layout keeps it from being arranged into the spiral and lets the
        // relayout drop tiled plugin panes (see override below) without ever
        // closing us.
        hide_self();
        // ReadApplicationState → receive PaneUpdate; ChangeApplicationState →
        // issue override_layout. Granted once by the user (or pre-seeded in
        // permissions.kdl for headless tests).
        request_permission(&[
            PermissionType::ReadApplicationState,
            PermissionType::ChangeApplicationState,
        ]);
        subscribe(&[EventType::PaneUpdate]);
    }

    fn update(&mut self, event: Event) -> bool {
        if let Event::PaneUpdate(manifest) = event {
            self.on_pane_update(manifest);
        }
        false // this plugin draws nothing
    }

    fn render(&mut self, _rows: usize, _cols: usize) {}
}

impl State {
    fn on_pane_update(&mut self, manifest: PaneManifest) {
        // Collect the live terminal panes of the tab and find the focused one
        // (ignore plugin panes — including our own).
        let mut focused: Option<u32> = None;
        let mut live: Vec<u32> = Vec::new();
        for panes in manifest.panes.values() {
            for pane in panes {
                if pane.is_plugin {
                    continue;
                }
                live.push(pane.id);
                if pane.is_focused {
                    focused = Some(pane.id);
                }
            }
        }

        let Some(focused) = focused else {
            return;
        };

        // Reconcile the MRU with the live set: forget panes that closed, append
        // panes we've never seen (a new pane is least-recent until focused). This
        // keeps the MRU a permutation of exactly the live terminal panes.
        self.mru.retain(|id| live.contains(id));
        for id in &live {
            if !self.mru.contains(id) {
                self.mru.push(*id);
            }
        }

        // Relayout only when focus actually changes since our last relayout — both
        // to avoid needless relayouts and so we ignore the PaneUpdate our own
        // relayout emits (focus stays put, so it won't re-trigger one). Keyed off
        // `last_focused`, not `mru.first()`: on the very first PaneUpdate the MRU is
        // freshly built in live order, so a focused pane that happens to sort first
        // would match `mru.first()` and wrongly skip its initial layout.
        if self.last_focused == Some(focused) {
            return;
        }
        self.last_focused = Some(focused);
        // Promote the focused pane to the front (most-recent).
        self.mru.retain(|id| *id != focused);
        self.mru.insert(0, focused);

        // A spiral needs at least a dominant pane plus a remainder.
        if self.mru.len() < 2 {
            return;
        }

        let n = self.mru.len();
        let layout = format!("layout {{\n{}}}\n", spiral_kdl(n, &self.master_size));

        // Bind MRU -> slots so the focused pane is dominant, then by recency.
        //
        // `override_layout_with_pane_ordering` places `ordering[i]` in the i-th leaf
        // of the layout's *flattened* (breadth-first) order — the order zellij walks
        // leaves when applying a layout (TiledPaneLayout::extract_run_instructions:
        // each node yields its first child's first leaf, then the rest after).
        //
        // The spiral is a caterpillar — every split is { recursion, dominant_leaf } —
        // so that breadth-first flatten is, for n panes:
        //   index 0           = the innermost corner leaf (smallest, least dominant)
        //   index 1           = the outermost dominant leaf (the big full-height slot)
        //   index 2 .. n-1    = the remaining dominant leaves, outer -> inner
        // i.e. dominance by flatten index is  1 > 2 > … > n-1 > 0.
        //
        // So most-recent -> index 1, next -> 2, …, least-recent -> index 0: a
        // right-rotation of the MRU by one (least-recent moves to the front).
        let mut pane_id_ordering: Vec<u32> = Vec::with_capacity(n);
        pane_id_ordering.push(self.mru[n - 1]); // least-recent -> index 0 (corner)
        pane_id_ordering.extend_from_slice(&self.mru[..n - 1]); // focused -> index 1 (dominant)

        override_layout_with_pane_ordering(
            LayoutInfo::Stringified(layout),
            true,  // retain existing terminal panes (rearrange, don't spawn)
            false, // drop retained tiled plugin panes: the default ui bars re-home
                   // to the tab frame instead of polluting a spiral slot, and we
                   // hid ourselves so we are never a casualty
            true,  // active tab only
            BTreeMap::new(),
            pane_id_ordering,
        );
    }
}

/// A non-empty run of ASCII digits followed by `%` (e.g. `"62%"`) — the only
/// shape zellij's layout parser accepts for a percentage `size`.
fn is_percentage(s: &str) -> bool {
    s.strip_suffix('%')
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

/// Render the body of the spiral layout (the children of `layout { … }`) for
/// `n` panes (`n >= 1`), indented one level.
///
/// Each level splits off one dominant `pane size=master` on the trailing (right,
/// then bottom, alternating) side and recurses into the rest on the leading side;
/// the base case is a single bare `pane`. Every leaf is a plain `pane` slot, which
/// makes repeated application idempotent — a `{ children; }` placeholder would
/// reinsert the existing (already-split) subtree and compound the nesting on each
/// focus change.
fn spiral_kdl(n: usize, master: &str) -> String {
    fn go(out: &mut String, depth: usize, remaining: usize, master: &str, vertical: bool) {
        let pad = "    ".repeat(depth + 1);
        if remaining <= 1 {
            out.push_str(&pad);
            out.push_str("pane\n");
            return;
        }
        let dir = if vertical { "vertical" } else { "horizontal" };
        out.push_str(&pad);
        out.push_str(&format!("pane split_direction=\"{dir}\" {{\n"));
        // Leading side: the remainder, recursed with the split direction flipped.
        go(out, depth + 1, remaining - 1, master, !vertical);
        // Trailing side: the dominant pane for this level, at the master share.
        out.push_str(&"    ".repeat(depth + 2));
        out.push_str(&format!("pane size=\"{master}\"\n"));
        out.push_str(&pad);
        out.push_str("}\n");
    }
    let mut out = String::new();
    go(&mut out, 0, n, master, true);
    out
}
