# SPDX-License-Identifier: MIT OR Apache-2.0
#
# THE NODE: florestad + floresta-cli for this board.
#
# Three lines of wiring, against ~90 in ../rasp-pi-zero/node.nix, because
# an aarch64 build needs none of what an ARMv6 musl build needs: no
# explicit --target (so the stock cargo hooks work), no
# CARGO_ENCODED_RUSTFLAGS fight to force a static link, no readelf guard
# against a stray PT_INTERP, no source patches at all — hence no
# ./patches.nix in this directory.
#
# In particular bitcoinkernel stays ENABLED here.  On the Pi Zero it had
# to be ripped out (32-bit, and its build.rs breaks crt-static); on
# aarch64 it builds the way upstream intends, so this board measures the
# configuration upstream actually ships.  That difference is the point
# of having this board in the lab at all.
{
  pkgs,
  toolchain,
  # The Floresta tree to build — the flake's `floresta-master` input.
  florestaSrc,
}:

(import ../../lib/floresta-build.nix {
  inherit pkgs;
  inherit (pkgs) lib;
  defaultSrc = florestaSrc;
  inherit (toolchain) rustPlatform;
  pnameSuffix = "-${toolchain.shortName}";
}).default
