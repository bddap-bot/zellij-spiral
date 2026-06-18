# Dev shell for the zellij golden-spiral plugin.
# Pinned bothouse nixpkgs + oxalica rust-overlay to get a rust toolchain that
# includes the wasm32-wasip1 std (the stock pinned rustc ships only
# wasm32-unknown-unknown, which zellij plugins can't use — they need WASI).
let
  rustOverlay = import (builtins.fetchTarball
    "https://github.com/oxalica/rust-overlay/archive/master.tar.gz");
  sources = import /home/bot/repos/bddap/bothouse/nix/nix/sources.nix;
  pkgs = import sources.nixpkgs { overlays = [ rustOverlay ]; };
  rust = pkgs.rust-bin.stable.latest.default.override {
    targets = [ "wasm32-wasip1" ];
  };
in
pkgs.mkShell {
  # gcc/pkg-config/protobuf are for build scripts in the dependency tree
  # (zellij-tile pulls prost & friends), compiled natively during the wasm build.
  buildInputs = [ rust pkgs.zellij pkgs.util-linux pkgs.gcc pkgs.pkg-config pkgs.protobuf ];
}
