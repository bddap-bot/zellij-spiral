# zellij-spiral — configurable direction: screenshot matrix

32 ASCII "screenshots", one per `(start, spin)` combo, rendered from a real headless
run of the plugin under the forked zellij. Each `<start>-<spin>.txt` is a top-down
view of the tab; every box is a pane labelled with its **MRU rank** — `1` = the
focused/dominant pane (the big slot), `2` the next-most-recent, … up to the
innermost corner. The MRU is fixed (panes focused `5,4,3,2,1` so `1` is most recent)
so every combo is directly comparable.

> Proportions: the dominant pane at each level gets **62%** (golden ratio), the
> remainder 38%. The boxes are drawn at those true proportions (the headless dump
> reports flat 50% sizes, so the renderer re-derives proportions from the split
> topology — see `test/render-ascii.js`).

## The model

The spiral is built as a sequence of **dominant sides**, one per recursion level.
At each level the dominant pane takes one side of the current rectangle and the
remainder takes the opposite side; the spiral recurses into the remainder. A side
is `Top | Bottom | Left | Right`, and it alone fixes the split: `Left`/`Right` ⇒ a
vertical split (dominant left/right), `Top`/`Bottom` ⇒ a horizontal split
(dominant top/bottom).

Two config knobs shape that side sequence:

### `start` ∈ { Top, Bottom, Left, Right }
Which side the **dominant (focused) pane** occupies at the outermost level. This is
unambiguous and works for all four values — see `Top-*`, `Bottom-*`, `Left-*`,
`Right-*`: pane `1` (the big slot) always sits on the named side.

### `spin` — how the spiral rotates inward (8 values)

> **Config key gotcha:** the model calls this "direction", but **zellij reserves the
> plugin-config key `direction`** and silently strips it (`PluginUserConfiguration::
> new` removes it), so it would never reach the plugin. The plugin therefore reads
> the key **`spin`**. `start` is not reserved and passes through normally.

Two families:

**Diagonal — `UpLeft`, `UpRight`, `DownLeft`, `DownRight`.** The remainder marches
monotonically toward one corner by *alternating* the two dominant sides that bracket
that corner. The corner names the direction the *remainder* (the shrinking spiral)
heads:

| spin | remainder heads to | dominant sides alternate |
|------|--------------------|--------------------------|
| `UpLeft`    | top-left     | Right, Bottom |
| `UpRight`   | top-right    | Left, Bottom |
| `DownLeft`  | bottom-left  | Right, Top |
| `DownRight` | bottom-right | Left, Top |

The **owner-reference spiral is `start=Right, spin=UpLeft`** ("dominant on right,
rest on left; then 2nd MRU on bottom, rest on top; then 3rd MRU on right, …") — see
`Right-UpLeft.txt`. That is the anchor everything else is derived from by
rotation/reflection.

**Rotational — `InClock`, `InCounter`, `OutClock`, `OutCounter`.** A pinwheel: the
dominant side turns one quarter-turn per level. Level 0 is always `start` (so the
focused pane lands where asked). `Clock`/`Counter` set the turn chirality:
- clockwise side cycle: Right → Bottom → Left → Top → Right
- counter-clockwise:    Right → Top → Left → Bottom → Right

`In` vs `Out`: **this is the genuinely ambiguous axis of the model — flagged for you
to confirm or redefine.** A pure quarter-turn pinwheel from a *fixed* start has only
two distinct forms (CW and CCW), so a third/fourth distinct rotational layout cannot
also be a pure pinwheel that still honours `start`. The interpretation implemented:
`Out` = same start and chirality as `In`, but with a half-turn (180°) offset applied
from level 1 onward — a distinct, start-respecting layout (compare `Right-InClock`
vs `Right-OutClock`). If you meant something else by In/Out (e.g. the spiral
unwinding outward, or master share inverting), say so and I'll re-derive.

## Degenerate combos (8)

A diagonal spin only fully determines the alternation when `start` is one of the two
sides bracketing its corner. When it is **not**, level 0 still honours `start`
(off-pattern), then the alternation resumes from the corner's pair. These render
fine but the outermost step doesn't match the clean diagonal — they're the ragged
corners of the model, surfaced rather than hidden:

| combo | sides (dominant per level) | why degenerate |
|-------|----------------------------|----------------|
| `Top-UpLeft`     | Top, Bottom, Right, Bottom | start Top ∉ {Right, Bottom} |
| `Top-UpRight`    | Top, Bottom, Left, Bottom  | start Top ∉ {Left, Bottom} |
| `Bottom-DownLeft`  | Bottom, Top, Right, Top  | start Bottom ∉ {Right, Top} |
| `Bottom-DownRight` | Bottom, Top, Left, Top   | start Bottom ∉ {Left, Top} |
| `Left-UpLeft`    | Left, Bottom, Right, Bottom | start Left ∉ {Right, Bottom} |
| `Left-DownLeft`  | Left, Top, Right, Top       | start Left ∉ {Right, Top} |
| `Right-UpRight`  | Right, Bottom, Left, Bottom | start Right ∉ {Left, Bottom} |
| `Right-DownRight`| Right, Top, Left, Top       | start Right ∉ {Left, Top} |

(The "well-formed" diagonal for each start is the one whose corner-pair contains the
start side: e.g. for `start=Right` the clean diagonals are `UpLeft` and `DownLeft`.)

## Full side-sequence table (5 panes ⇒ 4 splits)

Dominant side per level, level 0 = the focused pane's side:

```
Top    UpLeft      Top, Bottom, Right, Bottom    (degenerate)
Top    UpRight     Top, Bottom, Left, Bottom     (degenerate)
Top    DownLeft    Top, Right, Top, Right
Top    DownRight   Top, Left, Top, Left
Top    InClock     Top, Right, Bottom, Left
Top    InCounter   Top, Left, Bottom, Right
Top    OutClock    Top, Left, Top, Right
Top    OutCounter  Top, Right, Top, Left
Bottom UpLeft      Bottom, Right, Bottom, Right
Bottom UpRight     Bottom, Left, Bottom, Left
Bottom DownLeft    Bottom, Top, Right, Top       (degenerate)
Bottom DownRight   Bottom, Top, Left, Top        (degenerate)
Bottom InClock     Bottom, Left, Top, Right
Bottom InCounter   Bottom, Right, Top, Left
Bottom OutClock    Bottom, Right, Bottom, Left
Bottom OutCounter  Bottom, Left, Bottom, Right
Left   UpLeft      Left, Bottom, Right, Bottom   (degenerate)
Left   UpRight     Left, Bottom, Left, Bottom
Left   DownLeft    Left, Top, Right, Top          (degenerate)
Left   DownRight   Left, Top, Left, Top
Left   InClock     Left, Top, Right, Bottom
Left   InCounter   Left, Bottom, Right, Top
Left   OutClock    Left, Bottom, Left, Top
Left   OutCounter  Left, Top, Left, Bottom
Right  UpLeft      Right, Bottom, Right, Bottom   <-- owner reference
Right  UpRight     Right, Bottom, Left, Bottom    (degenerate)
Right  DownLeft    Right, Top, Right, Top
Right  DownRight   Right, Top, Left, Top          (degenerate)
Right  InClock     Right, Bottom, Left, Top
Right  InCounter   Right, Top, Left, Bottom
Right  OutClock    Right, Top, Right, Bottom
Right  OutCounter  Right, Bottom, Right, Top
```

## Reproducing

```sh
# Build the plugin wasm (from the repo root):
nix-shell --run 'cargo build --release --target wasm32-wasip1'

# One screenshot:                 test/screenshot.sh <start> <spin> [n_panes]
# All 32 into screenshots/:       test/gen-matrix.sh [n_panes]
```

Pure-logic unit tests (side sequences, flatten order, start-honouring) run without
the zellij dep tree via `rustc --test` on the extracted `src/main.rs` items; the
`#[cfg(test)]` module documents the invariants.
