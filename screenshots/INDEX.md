# zellij-spiral — configurable direction: screenshot matrix

16 ASCII "screenshots", one per `(start, spin)` combo, rendered from a real headless
run of the plugin under the forked zellij. Each `<start>-<spin>.txt` is a top-down
view of the tab; every box is a pane labelled with its **MRU rank** — `1` = the
focused/dominant pane (the big slot), `2` the next-most-recent, … up to the
innermost corner. The MRU is fixed (panes focused `5,4,3,2,1` so `1` is most recent)
so every combo is directly comparable.

> Proportions: the dominant pane at each level gets **62%** (golden ratio), the
> remainder 38%. The boxes are drawn at those true proportions (the headless dump
> reports flat 50% sizes, so the renderer re-derives proportions from the split
> topology — see `test/render-ascii.js`).

## The model — exactly 16 valid states

The layout config is `start (4) × spin (4) = 16`, plus a separate `master_size`
percentage. Every one of the 16 pairs is a clean spiral: there are no invalid or
degenerate combinations (the type admits none).

The spiral is built as a sequence of **dominant sides**, one per recursion level.
At each level the dominant pane takes one side of the current rectangle and the
remainder takes the opposite side; the spiral recurses into the remainder. A side
is `Top | Bottom | Left | Right`, and it alone fixes the split: `Left`/`Right` ⇒ a
vertical split (dominant left/right), `Top`/`Bottom` ⇒ a horizontal split
(dominant top/bottom).

Two config knobs shape that side sequence:

### `start` ∈ { Top, Bottom, Left, Right }
Which side the **dominant (focused) pane** occupies at the outermost level. Pane `1`
(the big slot) always sits on the named side — see `Top-*`, `Bottom-*`, `Left-*`,
`Right-*`.

### `spin` ∈ { PinwheelCw, PinwheelCcw, StaircaseCw, StaircaseCcw }

> **Config key gotcha:** the model calls this "direction", but **zellij reserves the
> plugin-config key `direction`** and silently strips it (`PluginUserConfiguration::
> new` removes it), so it would never reach the plugin. The plugin therefore reads
> the key **`spin`**. `start` is not reserved and passes through normally.

`spin` is a **pattern × turn**. Level 0 is always `start` (so the focused pane lands
where asked), which is why every `start × spin` pair is a clean, distinct spiral.

**Pattern:**
- **Pinwheel** — the dominant side turns a quarter-turn (90°) per level, cycling all
  four sides: a rotating golden spiral.
- **Staircase** — the dominant side alternates between `start` (even levels) and the
  *single* perpendicular side one quarter-turn away (odd levels): a stepping zig-zag
  that never crosses to the opposite side.

**Turn** — `Cw`/`Ccw` set the chirality (which way Pinwheel rotates, and which of the
two perpendicular sides Staircase steps to):
- clockwise side cycle: Right → Bottom → Left → Top → Right
- counter-clockwise:    Right → Top → Left → Bottom → Right

## Full side-sequence table (5 panes ⇒ 4 splits)

Dominant side per level, level 0 = the focused pane's side:

```
Top    PinwheelCw    Top, Right, Bottom, Left
Top    PinwheelCcw   Top, Left, Bottom, Right
Top    StaircaseCw   Top, Right, Top, Right
Top    StaircaseCcw  Top, Left, Top, Left
Bottom PinwheelCw    Bottom, Left, Top, Right
Bottom PinwheelCcw   Bottom, Right, Top, Left
Bottom StaircaseCw   Bottom, Left, Bottom, Left
Bottom StaircaseCcw  Bottom, Right, Bottom, Right
Left   PinwheelCw    Left, Top, Right, Bottom
Left   PinwheelCcw   Left, Bottom, Right, Top
Left   StaircaseCw   Left, Top, Left, Top
Left   StaircaseCcw  Left, Bottom, Left, Bottom
Right  PinwheelCw    Right, Bottom, Left, Top
Right  PinwheelCcw   Right, Top, Left, Bottom
Right  StaircaseCw   Right, Bottom, Right, Bottom
Right  StaircaseCcw  Right, Top, Right, Top
```

## Reproducing

```sh
# Build the plugin wasm (from the repo root):
nix-shell --run 'cargo build --release --target wasm32-wasip1'

# One screenshot:                 test/screenshot.sh <start> <spin> [n_panes]
# All 16 into screenshots/:       test/gen-matrix.sh [n_panes]
```

Pure-logic unit tests (side sequences, flatten order, start-honouring, all-16-build)
live in the `#[cfg(test)]` module of `src/main.rs` and document the invariants.
