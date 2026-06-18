# zellij-spiral

A [zellij](https://zellij.dev) plugin: **the focused pane keeps the big slot; every other pane collapses into a stack ordered by how recently it was focused.**

zellij tracks panes in creation order and has no notion of "most recently used", so this plugin keeps that ordering itself — it watches focus changes and, on each one, promotes the newly-focused pane to master and re-stacks the rest by recency (newest nearest the top).

> **Status: early WIP (v0.1).** Compiles and loads; the focus→restack behavior is being validated interactively. Feedback welcome.

## Install

Grab `zellij-spiral.wasm` from the [latest release](../../releases/latest), or build it yourself:

```sh
rustup target add wasm32-wasip1
cargo build --release --target wasm32-wasip1
# -> target/wasm32-wasip1/release/zellij-spiral.wasm
```

(With Nix: `nix-shell` in this repo gives a toolchain that includes the `wasm32-wasip1` target.)

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

## License

MIT OR Apache-2.0.
