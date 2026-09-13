# SPDX-License-Identifier: MIT OR Apache-2.0
#
# How you compile Rust for this board — which, for an aarch64 board, is
# almost nothing.
#
# This file is the whole contrast with ../rasp-pi-zero/toolchain.nix and
# the reason the two boards are different lineages.  There, `armv6l` has
# no nixpkgs binary cache, so the toolchain has to be hand-assembled: a
# fenix rust-std for a tier-2 target, pkgsCross.muslpi for the C parts, a
# linker wrapper that forces -static past ld's positional -Bdynamic, and
# a CMAKE_TOOLCHAIN_FILE to stop libbitcoinkernel-sys from compiling
# Bitcoin Core with the host compiler.  Roughly 120 lines of hard-won
# workarounds.
#
# Here, `aarch64-linux` is a first-class nixpkgs platform with a full
# binary cache.  The toolchain is just `pkgs` — the ordinary stdenv and
# rustPlatform of an aarch64 nixpkgs.  Nothing to work around, nothing
# to pin, nothing to static-link: the binary runs on a glibc NixOS that
# this same flake builds, so there is no libc contract to escape.
#
# It still exists as a file, for two reasons: the board contract in
# images/README.md promises it, and it is where a cross strategy would
# go if we ever want to build this image from an x86_64 host without
# binfmt (see ./README.md on that trade-off).
{ pkgs, ... }:

{
  # Labels derivations, the way "-armv6-musl" does on the Pi Zero.
  shortName = "aarch64";

  # Native: `pkgs` is already an aarch64 nixpkgs when this board is
  # evaluated for aarch64-linux, which is the only system it builds on.
  inherit (pkgs) rustPlatform;

  # No cross environment, no cc override, no linker wrapper.
  env = { };
}
