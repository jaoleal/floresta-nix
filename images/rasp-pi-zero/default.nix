# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Raspberry Pi Zero v1.3 — the reference board of this directory, and
# the only one whose content is finished.
#
# This file is the board's own gate: `meta` plus wiring, no build logic.
# Every step is its own file so that each can be built, iterated on and
# invalidated independently:
#
#   toolchain.nix   how to cross-compile for this board
#   patches.nix     what to change in Floresta's source for it
#   node.nix        THE NODE: florestad + floresta-cli  (toolchain + patches)
#   ../microbench.nix  the shared bench crate           (toolchain only)
#   payload.nix     the seam: node + microbench as a rootfs overlay
#   system.nix      THE OS: Buildroot.  Takes the payload, or none
#   system-test.nix acceptance test for the assembled image
#   flash.nix       the board-specific flasher
#
# The split is what makes `os-rasp-pi-zero` possible: the same OS with
# no payload, so iterating on init scripts or kernel config costs no
# ARMv6 cross build.  It also means a change to patches.nix rebuilds the
# node but not the microbenchmark, which used to share a file with it.
#
# Image builds are x86_64-linux only: Buildroot requires a Linux build
# host, and the download derivation's hash is pinned for one platform's
# closure.  The host-side flasher is exported everywhere — the lab host
# may well be a Mac even though the image was built on Linux.
{
  pkgs,
  inputs,
  system,
}:

let
  inherit (pkgs) lib;

  # The Floresta tree the lab runs: the flake's `floresta-master`
  # input — currently the bump/kernel0-3 branch proposed upstream,
  # which moves to crates.io bitcoinkernel 0.3.0 (libbitcoinkernel-sys
  # 0.4.0: bindgen-free, Android-aware build.rs).  Generic non-Android
  # cross is still not handled by that build.rs, so toolchain.nix keeps
  # compensating with a CMAKE_TOOLCHAIN_FILE.
  # Update with: nix flake update floresta-master
  florestaSrc = inputs.floresta-master;

  toolchain = import ./toolchain.nix { inherit pkgs inputs system; };
  patches = import ./patches.nix;

  node = import ./node.nix {
    inherit
      pkgs
      toolchain
      patches
      florestaSrc
      ;
  };
  microbench = import ../microbench.nix { inherit pkgs toolchain; };

  payload = import ./payload.nix { inherit pkgs node microbench; };

  # The image filename, defined once: it is both a `meta` fact the
  # shared tooling reads and a literal system.nix has to install under.
  imageFile = "floresta-rasp-pi-zero-sdcard.img";

  # Two calls, one file: the OS alone and the OS plus the node.  They
  # share every other derivation (Buildroot tarball, the downloads FOD,
  # the host tools), so having both costs nothing but the final `make`.
  os = import ./system.nix { inherit pkgs imageFile; };
  sdImage = import ./system.nix { inherit pkgs imageFile payload; };

  # The board profile.  Everything the shared tooling in ../flash.nix
  # and ../qemu-test.nix needs to know about this hardware, and nothing
  # about how the image is built.
  meta = {
    name = "rasp-pi-zero";
    description = "Raspberry Pi Zero v1.3 — ARM1176 (ARMv6 + VFPv2), 512 MB, no WiFi";
    # Where the image can be BUILT, not where the flasher runs.
    platforms = [ "x86_64-linux" ];
    inherit (toolchain) rustTarget;

    image = {
      file = imageFile;
      attr = "image-rasp-pi-zero";
    };

    flash = {
      # SD cards for this lab are 1 GiB–1 TiB.  Anything outside that is
      # suspicious enough to refuse.
      minBytes = 1024 * 1024 * 1024;
      maxBytes = 1024 * 1024 * 1024 * 1024;
      blockSize = "4M";
    };

    qemu = {
      emulator = "qemu-system-arm";
      machine = "raspi0";
      # Names as they appear in the image's FAT boot partition.
      kernel = "zImage";
      dtb = "bcm2708-rpi-zero.dtb";
      # Power-of-two size for QEMU; 512M sparse leaves the first-boot
      # data partition big enough for a real mkfs.f2fs.
      sdSize = "512M";
      # bcm2835_pm is blacklisted because QEMU does not model the PM
      # block; its probe faults and takes the deferred-probe worker
      # (and with it the SD host) down.  Harmless on real hardware.
      append = "root=/dev/mmcblk0p2 rootfstype=squashfs ro rootwait init=/sbin/preinit console=ttyAMA0,115200 initcall_blacklist=bcm2835_pm_driver_init";
      # This image repartitions itself on first boot and reboots; under
      # QEMU that halts, so a second boot is needed to reach userspace.
      firstBoot = true;
    };
  };

  buildable = system == "x86_64-linux";
in
{
  inherit meta;

  # flash-rasp-pi-zero: the board-specific flasher, and the one the
  # aggregator exports under the canonical `flash-<board>` name —
  # it flashes through the Pi's own USB boot mode and *detects* the
  # target disk instead of trusting a typed /dev/sdX.  The generic
  # card-reader fallback is still there as `flash-rasp-pi-zero-reader`.
  apps.flash-rasp-pi-zero = import ./flash.nix {
    inherit pkgs;
    device = meta;
  };

  # Each compartment is its own output, so you can build exactly the
  # piece you are working on.  Ordered cheapest-to-most-expensive.
  packages = lib.optionalAttrs buildable {
    # The node, on its own: no Buildroot anywhere in its closure.
    florestad-rasp-pi-zero = node;
    microbench-rasp-pi-zero = microbench;
    # The seam, inspectable on its own (`ls result/usr/bin`).
    payload-rasp-pi-zero = payload;
    # The pinned Buildroot download closure.
    buildroot-downloads-rasp-pi-zero = sdImage.downloads;
    # The OS with no Floresta in it: for iterating on init scripts and
    # kernel config without paying for the ARMv6 cross build.
    os-rasp-pi-zero = os.image;
    # The real thing.
    image-rasp-pi-zero = sdImage.image;
  };

  checks = lib.optionalAttrs buildable {
    # `nix build .#checks.x86_64-linux.boot-test-rasp-pi-zero` = build the
    # image AND boot-validate it under QEMU in one command.  Runs
    # before any hardware flashing — see ./README.md.
    boot-test-rasp-pi-zero = import ./system-test.nix {
      inherit pkgs imageFile;
      inherit (sdImage) image;
    };

    # Seconds-cheap florestad smoke test under qemu-user: user-mode
    # emulation enforces a 32-bit address space, so this catches the
    # whole class of "works on x86_64, dead on ARMv6" bugs (the flat
    # chainstore's 2^31-byte mmap default, dynamic-linking regressions,
    # instant startup crashes) without an image build or hardware.
    # Depends on ./node.nix only — no Buildroot, so it runs in seconds
    # on a cold store.
    florestad-smoke-rasp-pi-zero =
      pkgs.runCommand "florestad-smoke-rasp-pi-zero"
        {
          nativeBuildInputs = [ pkgs.qemu ];
        }
        ''
          qemu-arm ${node}/bin/florestad --version | tee version.txt
          grep -q "florestad" version.txt

          # Start against a fresh datadir: it must get past chainstore
          # creation and stay alive.  timeout's exit 124 (we killed a
          # living process) is the success signal; any earlier exit is
          # a startup crash.
          rc=0
          timeout 45 qemu-arm ${node}/bin/florestad \
            --network signet --data-dir ./datadir \
            --rpc-address 127.0.0.1:18332 >florestad.log 2>&1 || rc=$?
          echo "=== florestad.log ==="
          cat florestad.log
          if grep -q "overflows isize" florestad.log; then
            echo "FAIL: 32-bit mmap overflow is back"
            exit 1
          fi
          if [ "$rc" != 124 ]; then
            echo "FAIL: florestad exited early (rc=$rc) instead of running"
            exit 1
          fi

          mkdir -p $out
          cp florestad.log version.txt $out/
          echo PASS >$out/result
        '';
  };

  devShells = lib.optionalAttrs buildable { rasp-pi-zero = sdImage.devShell; };
}
