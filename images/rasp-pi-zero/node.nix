# SPDX-License-Identifier: MIT OR Apache-2.0
#
# THE NODE: florestad + floresta-cli, cross-compiled for this board.
#
# The whole point of this file existing on its own is that the node is
# not the image.  It builds, tests and versions independently: iterate
# on it with `nix build .#florestad-rasp-pi-zero` and never wait for
# Buildroot; it only meets the OS in ./payload.nix.
#
# Source patches come from ./patches.nix, cross-compilation from
# ./toolchain.nix.  This file knows only how to drive the build.
{
  pkgs,
  toolchain,
  patches,
  # The Floresta tree to build — the flake's `floresta-master` input.
  florestaSrc,
}:

let
  inherit (toolchain) rustTarget;
in
(import ../../lib/floresta-build.nix {
  inherit pkgs;
  inherit (pkgs) lib;
  defaultSrc = florestaSrc;
  inherit (toolchain) rustPlatform;
  pnameSuffix = "-${toolchain.shortName}";

  # The stock cargo hooks mishandle explicit cross targets; same
  # workaround as the Android builds.  The phase bodies below are
  # byte-sensitive: they are part of the derivation hash, so reflowing a
  # comment inside them costs a full ARMv6 rebuild.  Do not rewrap.
  dontCargoBuild = true;
  customBuildPhase = ''
    runHook preBuild
    # The full story of getting a static binary out of this
    # workspace, learned failure by failure:
    #  * libbitcoinkernel-sys' build.rs emits
    #    `rustc-link-lib=dylib=stdc++`; that one dylib request is
    #    enough for rustc to emit a dynamically-linked binary
    #    (NEEDED libstdc++.so.6 + an interpreter the image does
    #    not have) despite musl's crt-static default.
    #  * CARGO_TARGET_<T>_RUSTFLAGS and plain RUSTFLAGS were both
    #    observed NOT reaching the final link here.
    #    CARGO_ENCODED_RUSTFLAGS is cargo's highest-precedence
    #    rustflags source — nothing outranks or merges over it.
    #  * -C link-arg=-static hands gcc the final word: ld resolves
    #    -lstdc++ to libstdc++.a and emits no INTERP.
    # With an explicit --target these flags reach target
    # artifacts only; host build scripts/proc macros stay dynamic.
    CARGO_ENCODED_RUSTFLAGS="$(printf -- '-C\x1ftarget-feature=+crt-static\x1f-C\x1flink-arg=-static')"
    export CARGO_ENCODED_RUSTFLAGS
    cargo build \
      $cargoBuildFlags \
      --target ${rustTarget} \
      --offline \
      --release
    runHook postBuild
  '';
  customInstallPhase = ''
    runHook preInstall
    # A dynamically-linked binary is dead on arrival on the target
    # (its interpreter does not exist there) — fail the BUILD, not
    # the flashed card.  PT_INTERP present == dynamic.
    for bin in florestad floresta-cli; do
      if readelf -l "target/${rustTarget}/release/$bin" | grep -q INTERP; then
        echo "FATAL: $bin is dynamically linked; the static-link flags did not take effect"
        readelf -d "target/${rustTarget}/release/$bin" | head -5
        exit 1
      fi
    done
    install -D -m 0755 target/${rustTarget}/release/florestad $out/bin/florestad
    install -D -m 0755 target/${rustTarget}/release/floresta-cli $out/bin/floresta-cli
    runHook postInstall
  '';

  extraEnvVars = toolchain.env // {
    inherit (patches) postPatch;
  };
  extraNativeBuildInputsGlobal = [ toolchain.crossCc ];
}).default
