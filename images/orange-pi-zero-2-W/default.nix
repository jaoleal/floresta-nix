# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Orange Pi Zero 2W — SCAFFOLD.
#
# Allwinner H618: quad-core Cortex-A53 (aarch64, with the ARMv8 crypto
# extensions), 1–4 GB LPDDR4, WiFi/BT, USB-C.  Being aarch64 is the
# whole reason this board is built differently from the Pi Zeros:
# nixpkgs has a binary cache for aarch64-linux, so there is no reason
# to hand-roll a Buildroot rootfs.  This board re-exports
# ../florestaos — the generic NixOS-based Floresta image — and patches
# in the board's boot chain.
#
# What the real implementation has to add on top of ../florestaos:
#
#   * ./patches.nix     — u-boot-orangepi-zero2w (mainline U-Boot has
#                         the H618 defconfig) and, if the mainline DTBs
#                         are not enough, the sun50i-h618-orangepi-zero2w
#                         device tree.  No Rust cross work: aarch64
#                         florestad already comes from the flake.
#   * ./system.nix      — ../florestaos + the sd-image module wiring:
#                         U-Boot on the boot partition, the H618 DTB,
#                         serial console on ttyS0, and the kernel the
#                         board actually needs (mainline >= 6.6).
#   * ./assets/         — only board-local files: U-Boot environment,
#                         extlinux/boot.scr, WiFi firmware if the
#                         linux-firmware package does not cover AW859A.
#   * ./system-test.nix — a nixosTest is possible here (NixOS guest, so
#                         the standard driver works), unlike on the
#                         Buildroot boards.
#
# Being SHA-accelerated aarch64, this board is the *counterweight* in
# the lab: the same florestad, the same harness, hardware that is
# roughly an order of magnitude faster than a Pi Zero.  The interesting
# numbers are the ratios between the two.
_:

{
  meta = {
    name = "orange-pi-zero-2-W";
    description = "Orange Pi Zero 2W — Allwinner H618, 4x Cortex-A53 (aarch64), 1-4 GB";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    # No `image` / `qemu` key yet: images/default.nix skips scaffolded
    # boards instead of exporting a flasher that cannot work.
  };
}
