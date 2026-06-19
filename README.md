# zellij-spiral

A [zellij](https://zellij.dev) plugin: **the focused pane takes the dominant slot of a recursive golden spiral, and the rest fill the spiral inward by how recently they were focused.**

zellij tracks panes in creation order with no notion of "most recently used", so this plugin keeps that ordering itself — it watches focus changes and, on each one, rebuilds the tab as a golden spiral with the focused pane in the big dominant slot and the others spiraling toward the corner by recency.

> **Status: v0.2.** Validated headlessly — focus A→A, B→B, C→C dominant, plus the
> recursive spiral structure (see `test/headless-test.sh`). Requires the forked
> zellij below.

## Requires a forked zellij

Stock zellij (0.44/0.45) binds retained panes to layout slots by its own internal
pane order, with no plugin lever to override it — so the spiral geometry is right
but the *wrong* pane ends up dominant. This plugin therefore depends on a small
fork of zellij that adds `override_layout_with_pane_ordering` (an explicit
pane-id → leaf-slot binding) to `zellij-tile`, and must run under the matching
forked `zellij` binary.

The fork is [`bddap-bot/zellij`, branch `pane-slot-binding`](https://github.com/bddap-bot/zellij/tree/pane-slot-binding)
— one commit over upstream 0.45 adding that command. `Cargo.toml` already pins
`zellij-tile` to it, so the plugin build (below) pulls the right library with no
extra steps. The **runtime** binary, though, you build yourself and run the plugin
under — a stock `zellij` won't do:

```sh
git clone -b pane-slot-binding https://github.com/bddap-bot/zellij
cd zellij
cargo xtask build --release   # zellij's own build system; needs `protoc` installed
# -> target/release/zellij
```

## Install

Build the plugin against the fork's `zellij-tile` (the `Cargo.toml` path), then run
it under the forked `zellij` binary:

```sh
cargo build --release --target wasm32-wasip1
# -> target/wasm32-wasip1/release/zellij-spiral.wasm
```

(With Nix: `nix-shell` in this repo gives a toolchain that includes the
`wasm32-wasip1` target.)

## Use

Launch it as a background plugin (it draws nothing of its own):

```sh
zellij action launch-or-focus-plugin --floating file:/abs/path/zellij-spiral.wasm
```

The first launch prompts to grant **ReadApplicationState** (to see pane focus) and **ChangeApplicationState** (to restack) — press `y`. After that, move focus between panes and the focused one takes the big slot while the others stack by recency.

To load it automatically, add it to a layout:

```kdl
layout {
    pane
    pane borderless=true {
        plugin location="file:/abs/path/zellij-spiral.wasm"
    }
}
```

## Configuration

Pass config as plugin key/values (`--configuration k=v,k=v` on the CLI, or a
`plugin { … }` block in a layout):

| key | values | default | meaning |
|-----|--------|---------|---------|
| `start` | `Top` `Bottom` `Left` `Right` | `Right` | which side the focused/dominant pane occupies |
| `spin` | `PinwheelCw` `PinwheelCcw` `StaircaseCw` `StaircaseCcw` | `PinwheelCw` | how the spiral moves inward — a pattern × turn (see `screenshots/INDEX.md`) |
| `master_size` | a percentage, e.g. `62%` | `62%` | the dominant pane's share at each level |

`spin` is a **pattern × turn**: `Pinwheel` rotates the dominant side a quarter-turn
per level (a rotating golden spiral); `Staircase` alternates it between `start` and
the single perpendicular side one quarter-turn away (a stepping zig-zag). `Cw`/`Ccw`
set the chirality. So `start (4) × spin (4) = 16` layouts, every one a valid spiral —
catalogued as ASCII screenshots in [`screenshots/`](screenshots/INDEX.md).

> The spin key is **`spin`**, not `direction`: zellij reserves `direction` as a
> built-in plugin-pane attribute and strips it from plugin config, so it never
> reaches the plugin.

## License

MIT OR Apache-2.0.
