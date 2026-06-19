# zellij-spiral

A [zellij](https://zellij.dev) plugin: **the focused pane takes the dominant slot of a recursive golden spiral; the rest fill inward by how recently they were focused.**

zellij has no notion of "most recently used", so the plugin keeps that order itself — on every focus change it rebuilds the tab with the focused pane in the big slot and the others spiraling toward the corner by recency.

Two of the sixteen (`1` = focused/dominant … `5` = the oldest, tucked in the corner):

```
start=Right  spin=PinwheelCw  (the default)
+----------+------+----------------------------+
|          |      |                            |
|          |  4   |                            |
|    3     |      |                            |
|          +------+                            |
|          |  5   |                            |
|          |      |                            |
+----------+------+                            |
|                 |                            |
|                 |             1              |
|                 |                            |
|                 |                            |
|        2        |                            |
|                 |                            |
|                 |                            |
|                 |                            |
|                 |                            |
|                 |                            |
+-----------------+----------------------------+
```

```
start=Right  spin=StaircaseCw
+------+----------+----------------------------+
|      |          |                            |
|  5   |          |                            |
|      |    3     |                            |
+------+          |                            |
|  4   |          |                            |
|      |          |                            |
+------+----------+                            |
|                 |                            |
|                 |             1              |
|                 |                            |
|                 |                            |
|        2        |                            |
|                 |                            |
|                 |                            |
|                 |                            |
|                 |                            |
|                 |                            |
+-----------------+----------------------------+
```

Same focused pane (`1`, the big slot on the right); Pinwheel spins `3/4/5` around it, Staircase steps them up one side. Focus another pane and it slides into slot `1` and the spiral redraws. All 16 `start × spin` layouts are in [`screenshots/`](screenshots/INDEX.md).

## Try it

```sh
nix run github:bddap-bot/zellij-spiral
```

Drops you into a live session (the forked zellij + plugin + a few panes). The first launch prompts to grant **ReadApplicationState** + **ChangeApplicationState** — press `y`, then move focus around.

> First run builds a patched zellij from source (~10 min), then caches.

## Configuration

Pass as plugin key/values (`--configuration k=v` on the CLI, or a `plugin { … }` block in a layout):

| key | values | default | meaning |
|-----|--------|---------|---------|
| `start` | `Top` `Bottom` `Left` `Right` | `Right` | which side the focused pane occupies |
| `spin` | `PinwheelCw` `PinwheelCcw` `StaircaseCw` `StaircaseCcw` | `PinwheelCw` | how the spiral steps inward |
| `master_size` | a percentage, e.g. `62%` | `62%` | the dominant pane's share at each level |

`spin` is a **pattern × turn**: **Pinwheel** turns the dominant side a quarter-turn per level (a rotating spiral); **Staircase** alternates between `start` and one perpendicular side (a zig-zag). `Cw`/`Ccw` set the chirality. That's `start (4) × spin (4) = 16` layouts, every one a valid spiral — [`screenshots/INDEX.md`](screenshots/INDEX.md) has the full matrix and the side-sequence model.

> It's `spin`, not `direction`: zellij reserves `direction` as a built-in plugin-pane attribute and strips it from plugin config before it reaches the plugin.

## Why a forked zellij

Stock zellij binds retained panes to layout slots by its own internal order, with no plugin lever to override it — so the geometry is right but the *wrong* pane lands in the dominant slot. The plugin needs [`bddap-bot/zellij` @ `pane-slot-binding`](https://github.com/bddap-bot/zellij/tree/pane-slot-binding) (one commit over upstream 0.45), which adds an `override_layout_with_pane_ordering` command to `zellij-tile`. `nix run` above builds and runs it for you; the rest of this section is for building by hand.

## Building by hand

```sh
# plugin wasm — nix-shell gives a toolchain with the wasm32-wasip1 target
# (stock rustc ships only wasm32-unknown-unknown; zellij plugins are WASI):
nix-shell --run 'cargo build --release --target wasm32-wasip1'
# -> target/wasm32-wasip1/release/zellij-spiral.wasm

# the forked runtime (needs protoc):
git clone -b pane-slot-binding https://github.com/bddap-bot/zellij && cd zellij
cargo xtask build --release   # -> target/release/zellij
```

Then load the plugin under the forked binary — ad-hoc:

```sh
zellij action launch-or-focus-plugin --floating file:/abs/path/zellij-spiral.wasm
```

or from a layout:

```kdl
layout {
    pane
    pane borderless=true {
        plugin location="file:/abs/path/zellij-spiral.wasm"
    }
}
```

## License

MIT OR Apache-2.0.
