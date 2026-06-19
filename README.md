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
forked `zellij` binary. `Cargo.toml` points `zellij-tile` at that fork.

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
| `spin` | `UpLeft` `UpRight` `DownLeft` `DownRight` `InClock` `InCounter` `OutClock` `OutCounter` | `UpLeft` | how the spiral rotates inward (see `screenshots/INDEX.md`) |
| `master_size` | a percentage, e.g. `62%` | `62%` | the dominant pane's share at each level |

`start=Right, spin=UpLeft` is the reference spiral. The 32 `(start, spin)` layouts
are catalogued as ASCII screenshots in [`screenshots/`](screenshots/INDEX.md).

> The rotation key is **`spin`**, not `direction`: zellij reserves `direction` as a
> built-in plugin-pane attribute and strips it from plugin config, so it never
> reaches the plugin.

## License

MIT OR Apache-2.0.
