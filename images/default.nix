# SPDX-License-Identifier: MIT OR Apache-2.0
#
# THE GATE for ./images.  Everything this directory offers the rest of
# the repo passes through here — the root flake.nix imports this file
# and nothing else under images/, so there is exactly one place to look
# to know what the directory exports.
#
# Two kinds of thing live here:
#
#   boards   — one directory per SBC.  Each returns the contract below.
#   shared   — board-agnostic machinery the boards (or this gate)
#              instantiate: ./flash.nix, ./qemu-test.nix,
#              ./microbench.nix, ./harness (the measurement harness).
#
# The board contract (see images/README.md):
#
#   { meta, packages ? {}, checks ? {}, apps ? {}, devShells ? {} }
#
# `meta` is the board *profile*: the hardware facts the shared tooling
# needs, so no board reimplements dd or a QEMU invocation.  A board that
# needs something the generic tool cannot express ships its own and
# exports it under `apps` (the Pi Zero's rpiboot flasher).
#
# Platform gating lives in each board, not here: a board that can only
# be BUILT on x86_64-linux returns empty `packages`/`checks` elsewhere
# while still exporting its host-side tooling everywhere.
{
  pkgs,
  inputs,
  system,
}:

let
  inherit (pkgs) lib;

  args = { inherit pkgs inputs system; };

  boards = {
    rasp-pi-zero = import ./rasp-pi-zero args;
    rasp-pi-zero-w = import ./rasp-pi-zero-w args;
    orange-pi-zero-2-W = import ./orange-pi-zero-2-W args;
    florestaos = import ./florestaos args;
  };

  # ---------------------------------------------------------- shared

  # bench-node: the measurement harness.  Host-side on every system —
  # the target only ever runs POSIX sh piped over SSH, so the lab host
  # can be a Mac or a NixOS laptop.  See harness/README.md.
  benchNode = import ./harness/nix { inherit pkgs; };

  # A board is benchmarkable when the harness carries a profile for it.
  # Deriving the alias from that file's existence keeps the two from
  # drifting: add harness/targets/<board>.nix and the runner appears.
  benchmarkable = lib.filterAttrs (
    name: _: builtins.pathExists (./harness/targets + "/${name}.nix")
  ) boards;

  # run-<board>-signet: a thin alias, and deliberately nothing more —
  # the moment this grows logic, two entry points can disagree about
  # what a run is.
  signetRunners = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "run-${name}-signet" (
      pkgs.writeShellApplication {
        name = "run-${name}-signet";
        runtimeInputs = [ benchNode ];
        text = ''
          exec bench-node --target ${name} --network signet "$@"
        '';
      }
    )
  ) benchmarkable;

  # Boards that actually produce a flashable image get the shared
  # host-side tooling.  Scaffolded boards (no `image` in their meta yet)
  # are skipped instead of failing to evaluate.
  flashable = lib.filterAttrs (_: board: board.meta ? image) boards;
  emulatable = lib.filterAttrs (_: board: board.meta ? qemu) flashable;

  instantiate =
    mod:
    lib.mapAttrs (
      _: board:
      import mod {
        inherit pkgs;
        device = board.meta;
      }
    );

  rename = f: lib.mapAttrs' (name: value: lib.nameValuePair (f name) value);

  # flash-<board>-reader: the generic card-reader flasher, always there.
  readerFlashers = instantiate ./flash.nix flashable;
  # qemu-test-<board>: interactive boot under emulation.
  qemuTests = instantiate ./qemu-test.nix emulatable;

  mergeAll = attr: lib.foldl' (acc: board: acc // (board.${attr} or { })) { } (lib.attrValues boards);

  # flash-<board> is the canonical name: the best path that board has.
  # It defaults to the generic flasher, and a board that can flash
  # itself overrides it from its own `apps` (the `//` order is the whole
  # mechanism) — see rasp-pi-zero, which boots the Pi into USB
  # mass-storage mode instead of trusting a typed /dev/sdX.
  apps =
    rename (name: "flash-${name}-reader") readerFlashers
    // rename (name: "flash-${name}") readerFlashers
    // rename (name: "qemu-test-${name}") qemuTests
    // mergeAll "apps"
    // signetRunners
    // {
      bench-node = benchNode;
    };
in
{
  # The board profiles, exposed so `nix eval .#...` (and future tooling)
  # can read what this repo knows about each board without building it.
  inherit boards;

  # Runnable tooling is a package too — one build, two ways to reach it.
  packages = mergeAll "packages" // apps;
  checks = mergeAll "checks";
  devShells = mergeAll "devShells";
  inherit apps;
}
