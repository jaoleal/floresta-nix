# SPDX-License-Identifier: MIT OR Apache-2.0
#
# qemu-test-<board>: boot a board's image under QEMU before touching
# real hardware.  A Nix translation of the old images/qemu-test.nix,
# parameterized by a board's `meta.qemu` (see images/README.md).
#
# This is the INTERACTIVE validation tool.  Its automated sibling is
# each board's system-test.nix, wired into `nix flake check` — same two
# boots, same kernel command line, but asserting on the serial log
# instead of handing you a console.
#
# First-boot behaviour is mirrored faithfully on boards that declare
# `qemu.firstBoot`: stage 1 runs headless until the image repartitions
# itself and calls reboot (which halts under QEMU on hardware whose
# reset path QEMU does not model), then stage 2 boots the same,
# now-repartitioned image interactively.
#
# What QEMU cannot prove (hardware-only): the ROM/firmware boot chain,
# USB gadget modes, and any vendor coprocessor QEMU omits — expect
# probe errors for those in the log and ignore them.
#
# Usage: nix run .#qemu-test-<board> [-- image.img]
# Exit QEMU with: Ctrl-A then X.
{ pkgs, device }:

let
  inherit (pkgs) lib;
  q = device.qemu;
in
pkgs.writeShellApplication {
  name = "qemu-test-${device.name}";

  runtimeInputs = [
    pkgs.qemu
    pkgs.mtools # mcopy: pull kernel + dtb out of the FAT partition
    pkgs.util-linux # sfdisk
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
  ];

  text = ''
    die() {
      echo "qemu-test-${device.name}: ERROR: $*" >&2
      exit 1
    }

    IMAGE_NAME=${device.image.file}
    IMAGE_ATTR=${device.image.attr}

    IMG="''${1:-}"
    if [ -z "$IMG" ]; then
      for candidate in "result/$IMAGE_NAME" "result-${device.name}/$IMAGE_NAME"; do
        if [ -f "$candidate" ]; then
          IMG="$candidate"
          break
        fi
      done
    fi
    if [ -z "$IMG" ] && command -v nix >/dev/null && [ -f flake.nix ]; then
      # Ask nix for the store path directly — never trust ./result,
      # which any later `nix build` of something else repoints.
      echo ">>> resolving the image via .#$IMAGE_ATTR ..."
      out="$(nix build ".#$IMAGE_ATTR" --no-link --print-out-paths 2>/dev/null | tail -n 1)" || out=""
      if [ -n "$out" ] && [ -f "$out/$IMAGE_NAME" ]; then
        IMG="$out/$IMAGE_NAME"
      fi
    fi
    [ -n "$IMG" ] || die "no image found; build it with: nix build .#$IMAGE_ATTR"
    [ -f "$IMG" ] || die "image '$IMG' not found"

    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cp "$IMG" "$WORK/sd.img"
    chmod +w "$WORK/sd.img"

    # QEMU wants a power-of-two SD size; the board's profile picks one
    # big enough for the first-boot data partition to be mkfs'able.
    qemu-img resize -q -f raw "$WORK/sd.img" ${q.sdSize}

    # The kernel and DTB live in the image's FAT boot partition; QEMU
    # has no firmware to read them, so hand them over directly.
    start="$(sfdisk -d "$WORK/sd.img" | grep "img1" | sed 's/.*start= *\([0-9]*\).*/\1/')"
    mcopy -o -i "$WORK/sd.img@@$((start * 512))" ::${q.kernel} "$WORK/kernel"
    mcopy -o -i "$WORK/sd.img@@$((start * 512))" ::${q.dtb} "$WORK/dtb"

    APPEND=${lib.escapeShellArg q.append}

    run_qemu() {
      ${q.emulator} -M ${q.machine} \
        -kernel "$WORK/kernel" -dtb "$WORK/dtb" -append "$APPEND" \
        -sd "$WORK/sd.img" "$@"
    }
  ''
  + lib.optionalString (q.firstBoot or false) ''

    echo ">>> stage 1: first boot (repartitions, then halts under QEMU) ..."
    run_qemu -serial "file:$WORK/boot1.log" -monitor none -display none &
    QPID=$!
    for _ in $(seq 300); do
      if grep -qE "System halted|login:" "$WORK/boot1.log" 2>/dev/null; then
        break
      fi
      kill -0 "$QPID" 2>/dev/null || break
      sleep 1
    done
    kill "$QPID" 2>/dev/null || true
    tail -n 5 "$WORK/boot1.log" || true
    echo
  ''
  + ''

    echo ">>> stage ${if (q.firstBoot or false) then "2" else "1"}: interactive boot (exit: Ctrl-A X)"
    run_qemu -serial mon:stdio -display none
  '';

  meta = {
    description = "Boot the Floresta ${device.name} image under QEMU, interactively";
  };
}
