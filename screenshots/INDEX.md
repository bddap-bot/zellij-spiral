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

### `spin` ∈ { InClock, InCounter, OutClock, OutCounter }

> **Config key gotcha:** the model calls this "direction", but **zellij reserves the
> plugin-config key `direction`** and silently strips it (`PluginUserConfiguration::
> new` removes it), so it would never reach the plugin. The plugin therefore reads
> the key **`spin`**. `start` is not reserved and passes through normally.

All four spins are **rotational** pinwheels: the dominant side turns a quarter-turn
(90°) per level, cycling all four sides. Level 0 is always `start` (so the focused
pane lands where asked), which is why every `start × spin` pair is a valid spiral.
`Clock`/`Counter` set the turn chirality:
- clockwise side cycle: Right → Bottom → Left → Top → Right
- counter-clockwise:    Right → Top → Left → Bottom → Right

`In` vs `Out`: a pure quarter-turn pinwheel from a *fixed* start has only two
distinct forms (CW and CCW), so a third/fourth distinct rotational layout cannot
also be a pure pinwheel that still honours `start`. The interpretation implemented:
`Out` = same start and chirality as `In`, but with a half-turn (180°) offset applied
from level 1 onward — i.e. the In/Out distinction *is* that +180°-from-level-1
definition. It is a distinct, start-respecting layout (compare `Right-InClock` vs
`Right-OutClock`).

## Full side-sequence table (5 panes ⇒ 4 splits)

Dominant side per level, level 0 = the focused pane's side:

```
Top    InClock     Top, Right, Bottom, Left
Top    InCounter   Top, Left, Bottom, Right
Top    OutClock    Top, Left, Top, Right
Top    OutCounter  Top, Right, Top, Left
Bottom InClock     Bottom, Left, Top, Right
Bottom InCounter   Bottom, Right, Top, Left
Bottom OutClock    Bottom, Right, Bottom, Left
Bottom OutCounter  Bottom, Left, Bottom, Right
Left   InClock     Left, Top, Right, Bottom
Left   InCounter   Left, Bottom, Right, Top
Left   OutClock    Left, Bottom, Left, Top
Left   OutCounter  Left, Top, Left, Bottom
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
# All 16 into screenshots/:       test/gen-matrix.sh [n_panes]
```

Pure-logic unit tests (side sequences, flatten order, start-honouring, all-16-build)
live in the `#[cfg(test)]` module of `src/main.rs` and document the invariants.
