# SPDX-License-Identifier: MIT OR Apache-2.0
#
# florestaos — SCAFFOLD.
#
# A generic NixOS whose only job is to run Floresta.  Not a board: the
# *base* every aarch64-and-up board in this directory re-exports and
# patches (starting with ../orange-pi-zero-2-W), the way
# ../rasp-pi-zero is the base for the Buildroot/ARMv6 lineage.
#
# The name is deliberate: the Buildroot image in ../rasp-pi-zero
# already calls its userspace "florestaos" (see its init scripts and
# florestaos.conf).  This is the same product on a board where NixOS is
# affordable — same config file name, same paths, same `florestaos`
# command surface, so the harness cannot tell the two apart.
#
# What the real implementation has to provide:
#
#   * ./system.nix      — the NixOS module set: ../../lib/floresta-service.nix
#                         with lab defaults on top (read-only root,
#                         zram, f2fs data partition, no X, minimal
#                         closure, serial console, SSH with the lab
#                         key).  Board-agnostic: no bootloader, no DTB,
#                         no `sdImage` here — a board adds those.
#   * ./system-test.nix — a nixosTest booting that config and asserting
#                         florestad comes up and answers RPC.  Unlike
#                         the Buildroot boards this can use the real
#                         NixOS test driver.
#
# Explicitly NOT here: `assets/` (nothing to overlay — NixOS generates
# its own etc) and `patches.nix` (florestad for aarch64 comes from the
# flake's own builds, no cross hacks needed).
_:

{
  meta = {
    name = "florestaos";
    description = "Generic NixOS image whose only job is to run Floresta (base for aarch64 boards)";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    # No `image` / `qemu` key: this is a base, not a flashable board.
    # Boards that re-export it declare their own.
  };
}
