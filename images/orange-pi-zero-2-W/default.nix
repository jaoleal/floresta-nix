# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Orange Pi Zero 2W — Allwinner H618: four Cortex-A53 cores (aarch64,
# WITH the ARMv8 crypto extensions, so hardware SHA-256), 1-4 GB LPDDR4,
# onboard WiFi/BT, USB-C, and no ethernet port.
#
# This board is the counterweight to ../rasp-pi-zero in the lab: the same
# florestad, the same harness, hardware roughly an order of magnitude
# faster.  The numbers worth reading are the ratios — how much of
# Floresta's IBD cost is SHA-256 that silicon can absorb, and how much is
# everything else.  It also runs the configuration upstream actually
# ships, bitcoinkernel included, which the 32-bit Pi Zero cannot.
#
# Same file contract as every board (see images/README.md), minus one:
# there is no patches.nix, because an aarch64 build of Floresta needs no
# source changes at all.  Its absence is the finding.
#
# BUILDS ON aarch64-linux ONLY, and that is a real constraint rather than
# a preference: a NixOS closure for this board is almost entirely
# *substitutable* from cache.nixos.org, so building it natively is nearly
# free — while cross-compiling it from x86_64 would rebuild glibc,
# systemd and the kernel locally for no gain.  From an x86_64 host, build
# it with binfmt emulation registered for aarch64-linux, or on an aarch64
# remote builder.  See ./README.md.
{
  pkgs,
  inputs,
  system,
}:

let
  inherit (pkgs) lib;

  # Update with: nix flake update floresta-master
  florestaSrc = inputs.floresta-master;

  toolchain = import ./toolchain.nix { inherit pkgs; };

  node = import ./node.nix { inherit pkgs toolchain florestaSrc; };

  # Defined once: a `meta` fact the shared tooling reads, and the name
  # system.nix installs the image under.
  imageFile = "floresta-orange-pi-zero-2-W-sdcard.img";

  os = import ./system.nix {
    inherit
      pkgs
      inputs
      node
      imageFile
      ;
  };

  buildable = system == "aarch64-linux";

  meta = {
    name = "orange-pi-zero-2-W";
    description = "Orange Pi Zero 2W — Allwinner H618, 4x Cortex-A53 (aarch64), 1-4 GB";
    # Where the image can be BUILT.  Unlike the Pi Zero this is the
    # board's own architecture, not a cross host.
    platforms = [ "aarch64-linux" ];

    image = {
      file = imageFile;
      attr = "image-orange-pi-zero-2-W";
    };

    flash = {
      # The Zero 2W boots from microSD; 1 GiB-1 TiB is the plausible
      # range, same as every other board in this lab.
      minBytes = 1024 * 1024 * 1024;
      maxBytes = 1024 * 1024 * 1024 * 1024;
      blockSize = "4M";
    };

    # No `qemu` key yet, deliberately: qemu-system-aarch64 has no H618
    # machine model, so booting this image under emulation would prove
    # nothing about the boot chain that matters (BROM -> SPL -> BL31 ->
    # U-Boot -> extlinux).  The lab half is covered by ./system-test.nix
    # on `-M virt` instead, and the boot chain is hardware-only.  Omitting
    # the key is how a board opts out of ../qemu-test.nix.
  };
in
{
  inherit meta;

  packages = lib.optionalAttrs buildable {
    # The node alone: no image, no U-Boot, nothing to wait for.
    florestad-orange-pi-zero-2-W = node;
    # The bench crate with this board's toolchain.
    microbench-orange-pi-zero-2-W = import ../microbench.nix { inherit pkgs toolchain; };
    # The boot chain pieces, buildable and inspectable on their own.
    uboot-orange-pi-zero-2-W = os.uboot;
    # The system closure without the SD image around it — the
    # counterpart of os-rasp-pi-zero: it is what you iterate on when the
    # change is in the NixOS config rather than in the image layout.
    toplevel-orange-pi-zero-2-W = os.toplevel;
    # The real thing.
    image-orange-pi-zero-2-W = os.image;
  };

  checks = lib.optionalAttrs buildable {
    lab-test-orange-pi-zero-2-W = import ./system-test.nix {
      inherit pkgs node;
      labModule = os.modules.lab;
    };
  };
}
