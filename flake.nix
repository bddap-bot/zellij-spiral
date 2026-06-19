{
  description = "zellij-spiral — a zellij plugin where the focused pane takes the dominant slot of a recursive golden spiral";

  inputs = {
    # nixpkgs pin: this rev's zellij-unwrapped builds upstream 0.44.3 with
    # rustPlatform.buildRustPackage; we override its src to the 0.45-based fork.
    nixpkgs.url = "github:NixOS/nixpkgs/567a49d1913ce81ac6e9582e3553dd90a955875f";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        # The plugin and the fork's zellij-tile share this rev; importCargoLock
        # needs the source hash for every git crate it resolves (zellij-tile and
        # its zellij-utils dep both come from this one fork checkout).
        forkRev = "119b86e52e8145eecf7f43970ac3af13b30db629";
        forkSrc = pkgs.fetchFromGitHub {
          owner = "bddap-bot";
          repo = "zellij";
          rev = forkRev;
          hash = "sha256-W9fjq34c0Omgr7lZsLLQg6DtpbGyB9pYXMpGN4nGc+s=";
        };

        # A rust toolchain that includes the wasm32-wasip1 std. The stock pinned
        # rustc ships only wasm32-unknown-unknown, which zellij plugins can't use
        # — zellij plugins are WASI modules.
        rustWasm = pkgs.rust-bin.stable.latest.default.override {
          targets = [ "wasm32-wasip1" ];
        };

        # ---- the WASM plugin ----
        zellij-spiral = pkgs.stdenv.mkDerivation {
          pname = "zellij-spiral";
          version = "0.3.0";
          src = self;

          cargoDeps = pkgs.rustPlatform.importCargoLock {
            lockFile = ./Cargo.lock;
            # zellij-tile and zellij-utils are git crates from the fork; key by
            # "name-version" (both 0.45.0 at forkRev) to the unpacked source hash.
            outputHashes = {
              "zellij-tile-0.45.0" = "sha256-W9fjq34c0Omgr7lZsLLQg6DtpbGyB9pYXMpGN4nGc+s=";
              "zellij-utils-0.45.0" = "sha256-W9fjq34c0Omgr7lZsLLQg6DtpbGyB9pYXMpGN4nGc+s=";
            };
          };

          nativeBuildInputs = [
            rustWasm
            pkgs.rustPlatform.cargoSetupHook
            pkgs.pkg-config
            pkgs.protobuf
          ];
          # gcc/protobuf are for build scripts in the dependency tree (prost &
          # friends), compiled natively during the otherwise-wasm build.
          buildInputs = [ pkgs.gcc ];

          buildPhase = ''
            runHook preBuild
            cargo build --release --target wasm32-wasip1 --offline
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            cp target/wasm32-wasip1/release/zellij-spiral.wasm "$out/zellij-spiral.wasm"
            runHook postInstall
          '';

          doCheck = false;
        };

        # ---- the forked zellij binary ----
        # Reuse nixpkgs' whole zellij build (protoc, embedded assets, plugin
        # bundling, manpage, completions) and only repoint src + cargo deps at
        # the fork. zellij is a wrapper over zellij-unwrapped; override the latter.
        #
        # We supply cargoDeps directly rather than overriding cargoHash:
        # buildRustPackage reads the hash from `args.cargoHash`, the raw
        # function argument, which overrideAttrs (a fixpoint over the *result*)
        # cannot reach — so an overridden cargoHash is silently ignored and the
        # vendor FOD checks against the stale upstream hash. Passing a prebuilt
        # cargoDeps takes the recipe's `cargoDeps != null` branch instead, which
        # never consults args.cargoHash.
        zellij-fork-deps = pkgs.rustPlatform.fetchCargoVendor {
          name = "zellij-fork-deps";
          src = forkSrc;
          hash = "sha256-PLHoJcjyjd1jX/ZPf/Mh6n5VEQ2/Q4RZrZShm8yAeDM=";
        };
        zellij-forked-unwrapped = pkgs.zellij-unwrapped.overrideAttrs (_: {
          version = "0.45.0-pane-slot-binding";
          src = forkSrc;
          cargoDeps = zellij-fork-deps;
          # The upstream --version install check expects a plain semver; our
          # version string carries the fork suffix, so skip it.
          doInstallCheck = false;
        });
        zellij-forked = pkgs.zellij.override {
          zellij-unwrapped = zellij-forked-unwrapped;
        };

        # ---- one-command launcher ----
        # Writes a layout KDL (two normal panes + a borderless plugin pane loading
        # the spiral wasm) to a temp file and launches a fresh session under the
        # fork. Two panes so the spiral has something to arrange on first focus.
        spiral-session = pkgs.writeShellApplication {
          name = "zellij-spiral";
          runtimeInputs = [ zellij-forked pkgs.coreutils ];
          text = ''
            layout="$(mktemp --suffix=.kdl)"
            trap 'rm -f "$layout"' EXIT
            cat > "$layout" <<EOF
            layout {
                pane
                pane
                pane borderless=true {
                    plugin location="file:${zellij-spiral}/zellij-spiral.wasm"
                }
            }
            EOF
            exec zellij --layout "$layout"
          '';
        };
      in
      {
        packages = {
          inherit zellij-spiral zellij-forked;
          default = spiral-session;
        };

        apps.default = {
          type = "app";
          program = "${spiral-session}/bin/zellij-spiral";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            rustWasm
            zellij-forked
            pkgs.gcc
            pkgs.pkg-config
            pkgs.protobuf
          ];
        };
      }
    );
}
