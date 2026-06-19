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

/// The side of its rectangle a dominant pane occupies at one spiral level; the
/// remainder takes the opposite side and the spiral recurses into it. The side
/// alone determines the split: Left/Right ⇒ a vertical split (dominant is the
/// left/right child), Top/Bottom ⇒ a horizontal split (top/bottom child).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Side {
    Top,
    Bottom,
    Left,
    Right,
}

impl Side {
    /// zellij's `split_direction` for a split that places the dominant on this side.
    fn split_direction(self) -> &'static str {
        match self {
            Side::Left | Side::Right => "vertical",
            Side::Top | Side::Bottom => "horizontal",
        }
    }
    /// Whether the dominant child is the *trailing* child of the split (right of a
    /// vertical split, bottom of a horizontal one). zellij orders a split's children
    /// leading→trailing = left→right / top→bottom, so this fixes child order.
    fn dominant_is_trailing(self) -> bool {
        matches!(self, Side::Right | Side::Bottom)
    }
    /// One clockwise quarter-turn of the side (Right→Bottom→Left→Top→Right): the
    /// remainder pinwheels clockwise as the spiral recurses.
    fn turn_clockwise(self) -> Side {
        match self {
            Side::Right => Side::Bottom,
            Side::Bottom => Side::Left,
            Side::Left => Side::Top,
            Side::Top => Side::Right,
        }
    }
    fn turn_counter(self) -> Side {
        // Counter-clockwise is the inverse; three clockwise turns = one counter turn.
        self.turn_clockwise().turn_clockwise().turn_clockwise()
    }
    /// The opposite side (Right↔Left, Top↔Bottom) — a half-turn.
    fn opposite(self) -> Side {
        self.turn_clockwise().turn_clockwise()
    }
}

/// How the dominant side rotates as the spiral recurses inward — the plugin's
/// `spin` config (the model calls this "direction"; the key is `spin` because
/// zellij reserves `direction` — see `load`). Two families:
/// - **Diagonal** (`UpLeft`/`UpRight`/`DownLeft`/`DownRight`): the remainder marches
///   monotonically toward one corner by *alternating* the two dominant sides that
///   bracket that corner (e.g. UpLeft pushes the remainder toward the top-left by
///   taking Right then Bottom, repeating).
/// - **Rotational** (`InClock`/`InCounter`/`OutClock`/`OutCounter`): the dominant
///   side turns 90° every level, cycling all four sides — a pinwheel. Clock/Counter
///   pick the turn direction; In/Out pick travel forward vs backward along that
///   cycle (the two distinct pinwheels a 4-cycle admits from a given start).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Spin {
    UpLeft,
    UpRight,
    DownLeft,
    DownRight,
    InClock,
    InCounter,
    OutClock,
    OutCounter,
}

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
    /// Side the dominant (focused) pane occupies at the outermost level — the
    /// plugin's `start` config. The owner-reference spiral is `Right`.
    start: Side,
    /// How the dominant side rotates inward — the plugin's `spin` config (the model
    /// calls this "direction", but zellij reserves that config key; see `load`). The
    /// owner-reference spiral is `UpLeft` (remainder spirals toward the top-left).
    spin: Spin,
}

// A default `Side`/`Spin` is needed only so `#[derive(Default)] State` works; the
// real values always come from config in `load`. Pick the owner-reference pair.
impl Default for Side {
    fn default() -> Self {
        Side::Right
    }
}
impl Default for Spin {
    fn default() -> Self {
        Spin::UpLeft
    }
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
        // `start` / `spin` shape the spiral (see Side/Spin). Unknown or missing values
        // fall back to the owner-reference spiral rather than failing, so a typo
        // degrades to a sensible layout instead of no layout.
        //
        // The rotation key is `spin`, NOT `direction`: zellij reserves `direction` as
        // a built-in plugin-pane attribute and silently strips it from a plugin's user
        // configuration (PluginUserConfiguration::new), so a `direction=…` would never
        // reach this `load`. `start` is not reserved and passes through normally.
        self.start = configuration
            .get("start")
            .and_then(|s| parse_side(s))
            .unwrap_or_default();
        self.spin = configuration
            .get("spin")
            .and_then(|s| parse_spin(s))
            .unwrap_or_default();
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
        // Build the spiral tree once; emit its KDL and the flatten order from it, so
        // the MRU->slot binding can never drift from the geometry (the previous code
        // hand-derived the flatten index, valid only for the one hardcoded spiral).
        let spiral = Spiral::build(n, self.start, self.spin);
        let layout = format!("layout {{\n{}}}\n", spiral.to_kdl(&self.master_size));

        // Bind MRU -> slots. `override_layout_with_pane_ordering` assigns each layout
        // leaf a logical position in zellij's breadth-first slot order, then matches
        // retained panes to leaves by it (TiledPaneLayout::split_space; see
        // `flatten_ranks`). `flatten_ranks()` returns, for each leaf in that exact
        // order, the MRU rank (0 = focused/dominant) the geometry assigns it; map
        // rank -> mru id to get the per-leaf pane ordering.
        let pane_id_ordering: Vec<u32> = spiral
            .flatten_ranks()
            .into_iter()
            .map(|rank| self.mru[rank])
            .collect();

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

/// A fully-determined spiral for `n` panes: the ordered list of dominant `sides`,
/// one per split level. `sides[0]` is the outermost (the focused/dominant pane's
/// side), `sides[n-2]` the innermost. `n` panes need `n-1` splits.
///
/// This is the single source of truth: both the layout KDL and the MRU→leaf
/// ordering are derived from the same `sides`, so they cannot disagree.
struct Spiral {
    sides: Vec<Side>,
}

impl Spiral {
    /// Generate the side sequence for `(start, spin)`. `n >= 2`.
    fn build(n: usize, start: Side, spin: Spin) -> Spiral {
        let levels = n - 1;
        let mut sides = Vec::with_capacity(levels);
        for i in 0..levels {
            sides.push(side_at(i, start, spin));
        }
        Spiral { sides }
    }

    /// Emit the body of `layout { … }` (the children), indented one level.
    ///
    /// The spiral is a caterpillar: every level is a split of { remainder, dominant }
    /// where the dominant is a single `pane size=master` leaf on `sides[level]` and
    /// the remainder recurses. Child order within each split follows
    /// `Side::dominant_is_trailing` so the dominant lands on the correct side. The
    /// base case is a bare `pane`. Every leaf is a plain `pane` (no `{ children; }`
    /// placeholder), which keeps re-applying the layout idempotent rather than
    /// compounding the nesting on each focus change.
    fn to_kdl(&self, master: &str) -> String {
        fn go(out: &mut String, depth: usize, sides: &[Side], master: &str) {
            let pad = "    ".repeat(depth + 1);
            let Some((&side, rest)) = sides.split_first() else {
                // No splits left: the innermost remainder is a single bare pane.
                out.push_str(&pad);
                out.push_str("pane\n");
                return;
            };
            out.push_str(&pad);
            out.push_str(&format!(
                "pane split_direction=\"{}\" {{\n",
                side.split_direction()
            ));
            let dom_pad = "    ".repeat(depth + 2);
            let dominant = format!("{dom_pad}pane size=\"{master}\"\n");
            if side.dominant_is_trailing() {
                go(out, depth + 1, rest, master); // remainder (leading)
                out.push_str(&dominant); // dominant (trailing)
            } else {
                out.push_str(&dominant); // dominant (leading)
                go(out, depth + 1, rest, master); // remainder (trailing)
            }
            out.push_str(&pad);
            out.push_str("}\n");
        }
        let mut out = String::new();
        go(&mut out, 0, &self.sides, master);
        out
    }

    /// For each leaf, in the order zellij fills slots, the MRU rank assigned to it:
    /// 0 = focused/dominant, 1 = next-most-recent, …, n-1 = innermost corner.
    ///
    /// Slot order is *not* the textual leaf order. zellij walks the layout
    /// breadth-first (TiledPaneLayout::split_space): at each split it takes the first
    /// leaf of the first child's subtree, then defers that subtree's remaining leaves
    /// until after the other children. So a caterpillar's order is
    /// `[corner, dominant₀, dominant₁, …]` — the outermost dominant lands in slot 1,
    /// not last. We mirror that exact walk here so the binding can never drift from
    /// what the engine does (the previous closed-form was correct only for the one
    /// hardcoded spiral). `apply_pane_id_ordering` then maps slot k ← ordering[k].
    fn flatten_ranks(&self) -> Vec<usize> {
        self.to_node().breadth_first()
    }

    /// Build the explicit { dominant-leaf, remainder } caterpillar as a `Node` tree,
    /// each leaf tagged with its MRU rank (dominant at level d ⇒ rank d; the
    /// innermost remainder ⇒ the last rank). `to_kdl` and this share the same shape.
    fn to_node(&self) -> Node {
        fn build(depth: usize, sides: &[Side], corner_rank: usize) -> Node {
            let Some((&side, rest)) = sides.split_first() else {
                return Node::Leaf(corner_rank); // innermost remainder = least-recent
            };
            let dominant = Box::new(Node::Leaf(depth));
            let remainder = Box::new(build(depth + 1, rest, corner_rank));
            // Child order matches the split: dominant leading or trailing.
            let children = if side.dominant_is_trailing() {
                [remainder, dominant]
            } else {
                [dominant, remainder]
            };
            Node::Split(children)
        }
        build(0, &self.sides, self.sides.len())
    }
}

/// A node of the spiral's binary split tree: a leaf carrying its MRU rank, or a
/// split with its two children in leading→trailing order.
enum Node {
    Leaf(usize),
    Split([Box<Node>; 2]),
}

impl Node {
    /// The leaf ranks in zellij's slot-fill order — a faithful port of
    /// `TiledPaneLayout::split_space`'s breadth-first traversal: for each child, push
    /// the first leaf of its subtree now and defer the subtree's remaining leaves
    /// until all children's first leaves have been pushed.
    fn breadth_first(&self) -> Vec<usize> {
        match self {
            Node::Leaf(rank) => vec![*rank],
            Node::Split(children) => {
                let mut firsts = Vec::new();
                let mut deferred = Vec::new();
                for child in children {
                    let mut sub = child.breadth_first();
                    firsts.push(sub.remove(0));
                    deferred.extend(sub);
                }
                firsts.extend(deferred);
                firsts
            }
        }
    }
}

/// The dominant side at recursion level `i` for `(start, spin)`. Level 0 (the
/// focused pane) lands on `start` in every well-formed case.
///
/// - Diagonal spins alternate the two sides bracketing the target corner; if `start`
///   is one of that pair (the well-formed case) it leads, otherwise level 0 honours
///   `start` (degenerate) and the alternation resumes from the pair afterward.
/// - Rotational spins turn one quarter per level from `start` (Clock/Counter
///   chirality); `Out` adds a half-turn from level 1 on (see the arm comment).
fn side_at(i: usize, start: Side, spin: Spin) -> Side {
    use Spin::*;
    // The unordered pair of dominant sides for each diagonal's target corner.
    let diagonal_pair = |corner: Spin| -> (Side, Side) {
        match corner {
            UpLeft => (Side::Right, Side::Bottom),   // remainder → top-left
            UpRight => (Side::Left, Side::Bottom),   // remainder → top-right
            DownLeft => (Side::Right, Side::Top),    // remainder → bottom-left
            DownRight => (Side::Left, Side::Top),    // remainder → bottom-right
            _ => unreachable!("not a diagonal"),
        }
    };
    match spin {
        UpLeft | UpRight | DownLeft | DownRight => {
            let (a, b) = diagonal_pair(spin);
            // Order the alternation so `start` leads when it is one of the pair;
            // otherwise level 0 is `start` (degenerate) and the pair alternates after.
            let (first, second) = if start == b { (b, a) } else { (a, b) };
            if i == 0 && start != a && start != b {
                start
            } else if i % 2 == 0 {
                first
            } else {
                second
            }
        }
        InClock | InCounter | OutClock | OutCounter => {
            // A pinwheel: the dominant side turns one quarter per level, `Clock` vs
            // `Counter` setting the chirality. Level 0 is ALWAYS `start` so the
            // focused pane lands where asked regardless of spin.
            //
            // In/Out: a pure quarter-turn pinwheel from a fixed start has only two
            // forms (CW, CCW), so a *fourth* distinct rotational layout can't also be
            // a pure pinwheel that honours `start`. `Out` is the deliberate variant:
            // same start and chirality as `In`, but with a half-turn (180°) offset on
            // every level past the first — a distinct, start-respecting layout. (This
            // In/Out reading is the genuinely ambiguous axis of the model; see
            // screenshots/INDEX.md.)
            let clockwise = matches!(spin, InClock | OutClock);
            let outward = matches!(spin, OutClock | OutCounter);
            let mut s = start;
            for _ in 0..i {
                s = if clockwise {
                    s.turn_clockwise()
                } else {
                    s.turn_counter()
                };
            }
            if outward && i >= 1 {
                s = s.opposite();
            }
            s
        }
    }
}

/// Parse a `start` config value (case-insensitive) into a `Side`.
fn parse_side(s: &str) -> Option<Side> {
    match s.to_ascii_lowercase().as_str() {
        "top" => Some(Side::Top),
        "bottom" => Some(Side::Bottom),
        "left" => Some(Side::Left),
        "right" => Some(Side::Right),
        _ => None,
    }
}

/// Parse a `spin` config value (case-insensitive) into a `Spin`.
fn parse_spin(s: &str) -> Option<Spin> {
    match s.to_ascii_lowercase().as_str() {
        "upleft" => Some(Spin::UpLeft),
        "upright" => Some(Spin::UpRight),
        "downleft" => Some(Spin::DownLeft),
        "downright" => Some(Spin::DownRight),
        "inclock" => Some(Spin::InClock),
        "incounter" => Some(Spin::InCounter),
        "outclock" => Some(Spin::OutClock),
        "outcounter" => Some(Spin::OutCounter),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sides(n: usize, start: Side, dir: Spin) -> Vec<Side> {
        Spiral::build(n, start, dir).sides
    }

    #[test]
    fn owner_reference_is_right_upleft() {
        // The owner's reference: dominant right, then bottom, then right, then bottom.
        assert_eq!(
            sides(5, Side::Right, Spin::UpLeft),
            vec![Side::Right, Side::Bottom, Side::Right, Side::Bottom]
        );
    }

    #[test]
    fn diagonal_alternates_its_pair() {
        // DownRight heads to the bottom-right corner: dominant alternates Left/Top.
        assert_eq!(
            sides(5, Side::Left, Spin::DownRight),
            vec![Side::Left, Side::Top, Side::Left, Side::Top]
        );
    }

    #[test]
    fn diagonal_with_off_pair_start_is_degenerate_then_snaps() {
        // start=Top is not in UpLeft's pair {Right,Bottom}: level 0 honours Top,
        // then the pair alternation resumes at parity i%2 over (first,second) =
        // (Right,Bottom) — i=1→Bottom, i=2→Right, i=3→Bottom.
        assert_eq!(
            sides(5, Side::Top, Spin::UpLeft),
            vec![Side::Top, Side::Bottom, Side::Right, Side::Bottom]
        );
    }

    #[test]
    fn rotational_clockwise_turns_a_quarter_each_level() {
        assert_eq!(
            sides(5, Side::Right, Spin::InClock),
            vec![Side::Right, Side::Bottom, Side::Left, Side::Top]
        );
    }

    #[test]
    fn rotational_honours_start_at_level_zero() {
        // The focused pane must land on `start` for EVERY spin, In and Out alike.
        for spin in [Spin::InClock, Spin::InCounter, Spin::OutClock, Spin::OutCounter] {
            for start in [Side::Top, Side::Bottom, Side::Left, Side::Right] {
                assert_eq!(sides(3, start, spin)[0], start, "{start:?}/{spin:?} level 0");
            }
        }
    }

    #[test]
    fn rotational_out_matches_in_at_level_zero_then_half_turn_offset() {
        // Out = In at level 0 (so start is honoured), then the 180° opposite of In
        // from level 1 on — a distinct, start-respecting layout.
        let inn = sides(5, Side::Right, Spin::InClock);
        let out = sides(5, Side::Right, Spin::OutClock);
        assert_eq!(out[0], inn[0]);
        for k in 1..inn.len() {
            assert_eq!(out[k], inn[k].opposite(), "level {k}");
        }
    }

    #[test]
    fn flatten_order_is_corner_then_dominants_outermost_first() {
        // zellij's breadth-first slot order for the caterpillar: corner (least-recent)
        // in slot 0, then the dominants outermost→innermost (ranks 0,1,…,n-2). This
        // is the order apply_pane_id_ordering expects; getting it backwards puts the
        // wrong pane in the big slot.
        let ranks = Spiral::build(5, Side::Right, Spin::UpLeft).flatten_ranks();
        assert_eq!(ranks, vec![4, 0, 1, 2, 3]);
    }

    #[test]
    fn flatten_ranks_covers_all_panes_once() {
        // For any (start, spin) the flatten must be a permutation of 0..n.
        let dirs = [
            Spin::UpLeft,
            Spin::UpRight,
            Spin::DownLeft,
            Spin::DownRight,
            Spin::InClock,
            Spin::InCounter,
            Spin::OutClock,
            Spin::OutCounter,
        ];
        let starts = [Side::Top, Side::Bottom, Side::Left, Side::Right];
        for &n in &[2usize, 3, 5, 8] {
            for &start in &starts {
                for &dir in &dirs {
                    let mut ranks = Spiral::build(n, start, dir).flatten_ranks();
                    assert_eq!(ranks.len(), n, "leaf count for n={n}");
                    ranks.sort_unstable();
                    assert_eq!(
                        ranks,
                        (0..n).collect::<Vec<_>>(),
                        "ranks must be a permutation of 0..{n} for {start:?}/{dir:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn outermost_split_places_dominant_on_the_start_side() {
        // The focused pane is the outermost dominant master leaf; it must sit on
        // `start`. Check the KDL: the outermost split's direction follows the start
        // axis, and the master leaf is the trailing child for Right/Bottom (appears
        // after the recursion block) or the leading child for Left/Top (before it).
        for start in [Side::Top, Side::Bottom, Side::Left, Side::Right] {
            let kdl = Spiral::build(3, start, Spin::InClock).to_kdl("62%");
            let lines: Vec<&str> = kdl.lines().map(str::trim).collect();
            // First non-empty line is the outermost split opener.
            let opener = lines.iter().find(|l| !l.is_empty()).unwrap();
            assert!(
                opener.contains(&format!("split_direction=\"{}\"", start.split_direction())),
                "{start:?}: outermost split axis"
            );
            // The dominant master leaf is `pane size="62%"` with no children. Its
            // position relative to the recursion opener (a `pane split_direction…{`)
            // tells which side it took.
            let master_idx = lines.iter().position(|l| *l == "pane size=\"62%\"").unwrap();
            let recursion_idx = lines
                .iter()
                .skip(1)
                .position(|l| l.starts_with("pane split_direction") && l.ends_with('{'))
                .map(|i| i + 1);
            if start.dominant_is_trailing() {
                assert!(
                    recursion_idx.map_or(true, |r| master_idx > r),
                    "{start:?}: dominant should trail the recursion"
                );
            } else {
                assert!(
                    recursion_idx.map_or(true, |r| master_idx < r),
                    "{start:?}: dominant should lead the recursion"
                );
            }
        }
    }
}
