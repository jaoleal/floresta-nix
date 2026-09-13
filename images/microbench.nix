# SPDX-License-Identifier: MIT OR Apache-2.0
#
# The ./bench crate, built with a board's toolchain.
#
# Shared machinery, like ./flash.nix and ./qemu-test.nix: the crate is
# board-agnostic on purpose — the numbers are only comparable across
# boards because the code is byte-identical — so the only thing a board
# contributes is how to compile for it.
#
# Two shapes, picked from the toolchain rather than from a flag:
#
#   toolchain.rustTarget set    cross build, driven by hand.  The stock
#                               cargo hooks mishandle an explicit
#                               --target, so build and install phases are
#                               spelled out (rasp-pi-zero, ARMv6 musl).
#   rustTarget absent/null      native build.  buildRustPackage's own
#                               hooks do the right thing and there is
#                               nothing to work around (orange-pi, aarch64).
#
# The cross branch is byte-sensitive: its phase strings are part of the
# derivation hash, so reflowing a comment inside them costs a full cross
# rebuild.  Do not rewrap.
#
# It lives here rather than inside ./bench/ so that editing this file
# cannot change the crate's `src` and rebuild it.
{ pkgs, toolchain }:

let
  inherit (pkgs) lib;
  rustTarget = toolchain.rustTarget or null;
in
toolchain.rustPlatform.buildRustPackage (
  {
    pname = "floresta-microbench-${toolchain.shortName}";
    version = "0.1.0";
    src = pkgs.lib.cleanSource ./bench;
    cargoLock.lockFile = ./bench/Cargo.lock;

    meta = {
      description = "CPU microbenchmarks for the Floresta SBC bench lab";
      mainProgram = "floresta-microbench";
    };
  }
  // lib.optionalAttrs (rustTarget != null) {
    nativeBuildInputs = [ toolchain.crossCc ];

    # The stock cargo hooks mishandle an explicit --target; drive it by
    # hand, exactly as ./rasp-pi-zero/node.nix does.
    dontCargoBuild = true;
    dontCargoInstall = true;
    buildPhase = ''
      runHook preBuild
      cargo build --target ${rustTarget} --offline --release
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -D -m 0755 target/${rustTarget}/release/floresta-microbench $out/bin/floresta-microbench
      runHook postInstall
    '';
  }
  // toolchain.env
)
