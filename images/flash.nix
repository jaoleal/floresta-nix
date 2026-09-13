# SPDX-License-Identifier: MIT OR Apache-2.0
#
# flash-<board>: the GENERIC, board-agnostic flasher — card reader plus
# a hand-typed device node.  A Nix translation of the old
# images/flash.nix, parameterized by a board's `meta` (see images/README.md)
# so every board gets the same guarded dd for free.
#
# This is the FALLBACK path on boards that can flash themselves: the
# Pi Zero, for instance, ships its own images/rasp-pi-zero/flash.nix,
# which boots the board into USB mass-storage mode and *detects* the
# target disk instead of trusting a typed /dev/sdX.  Prefer that when it
# exists; use this one when the OTG port or the cable will not
# cooperate, or on boards with no self-flashing path at all.
#
# dd does not care whether the target is your SD card or your root
# disk; this wrapper does.
#
# Usage:
#   nix run .#flash-<board> -- /dev/sdX              (Linux)
#   nix run .#flash-<board> -- /dev/diskN            (macOS)
#   nix run .#flash-<board> -- /dev/sdX path/to/image.img
{ pkgs, device }:

let
  inherit (pkgs) lib;
in
pkgs.writeShellApplication {
  name = "flash-${device.name}-reader";

  runtimeInputs = [
    pkgs.coreutils # GNU dd (status=progress), basename, sync
    pkgs.gnugrep
    pkgs.gnused
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.util-linux ]; # lsblk

  text = ''
    # diskutil/sudo are macOS system tools, deliberately not from Nix;
    # make sure their home is on PATH even in a bare environment.
    export PATH="$PATH:/usr/sbin:/usr/bin:/sbin:/bin"

    IMAGE_NAME=${device.image.file}
    IMAGE_ATTR=${device.image.attr}
    MIN_BYTES=${toString device.flash.minBytes}
    MAX_BYTES=${toString device.flash.maxBytes}
    BS=${device.flash.blockSize}

    die() {
      echo "flash-${device.name}-reader: ERROR: $*" >&2
      exit 1
    }

    # ------------------------------------------------------- arguments
    DEV="''${1:-}"
    IMG="''${2:-}"

    [ -n "$DEV" ] || die "usage: flash-${device.name}-reader <device> [image]"

    # With no image argument, look where `nix build` leaves things.
    if [ -z "$IMG" ]; then
      for candidate in "result/$IMAGE_NAME" "result-${device.name}/$IMAGE_NAME"; do
        if [ -f "$candidate" ]; then
          IMG="$candidate"
          break
        fi
      done
    fi
    [ -n "$IMG" ] || die "no image given and none found in ./result; \
    build it with: nix build .#$IMAGE_ATTR   (or pass the image path as arg 2)"
    [ -f "$IMG" ] || die "image '$IMG' not found"
    [ -e "$DEV" ] || die "device '$DEV' does not exist"

    # ------------------------------------------------------- confirm
    confirm() {
      name="$1"
      desc="$2"
      echo
      echo "  target : $DEV ($desc)"
      echo "  image  : $IMG"
      echo
      echo "ALL DATA ON $DEV WILL BE DESTROYED."
      printf "Type '%s' to continue: " "$name"
      read -r answer
      [ "$answer" = "$name" ] || die "confirmation mismatch, aborting"
    }

    check_size() {
      size_b="$1"
      [ "$size_b" -ge "$MIN_BYTES" ] ||
        die "'$DEV' is smaller than $((MIN_BYTES / 1024 / 1024)) MiB; not a usable card"
      [ "$size_b" -le "$MAX_BYTES" ] ||
        die "'$DEV' is larger than $((MAX_BYTES / 1024 / 1024 / 1024)) GiB; \
    refusing to believe it is an SD card"
    }

    # ------------------------------------------------------- Linux
    flash_linux() {
      [ -b "$DEV" ] || die "'$DEV' is not a block device"
      name="$(basename "$DEV")"

      # Whole disk, not a partition: flashing /dev/sdX1 writes a
      # partitioned image inside a partition and boots nothing.
      [ "$(lsblk -ndo TYPE "$DEV")" = disk ] ||
        die "'$DEV' is not a whole disk (did you pass a partition?)"

      # Refuse anything that is mounted, or has a mounted partition —
      # system disks always are, SD cards are only if auto-mounted (and
      # then the user should unmount deliberately).
      if lsblk -no MOUNTPOINT "$DEV" | grep -q .; then
        lsblk "$DEV" >&2
        die "'$DEV' has mounted filesystems; unmount them first (umount $DEV*)"
      fi

      # An SD card presents as removable (or at least as an mmcblk/usb
      # device).  A non-removable SATA/NVMe disk is almost certainly not
      # where the user wants a few hundred MB of board image.
      rm_flag="$(lsblk -ndo RM "$DEV" | tr -d ' ')"
      tran="$(lsblk -ndo TRAN "$DEV" | tr -d ' ')"
      case "$name" in
      mmcblk*) : ;; # SD slot
      *)
        if [ "$rm_flag" != 1 ] && [ "$tran" != usb ]; then
          die "'$DEV' looks like a fixed system disk (RM=$rm_flag TRAN=''${tran:-?}); refusing"
        fi
        ;;
      esac

      check_size "$(lsblk -bndo SIZE "$DEV")"
      confirm "$name" "$(lsblk -ndo SIZE,MODEL "$DEV" | tr -s ' ')"

      echo "flashing $IMG -> $DEV ..."
      sudo dd if="$IMG" of="$DEV" bs="$BS" conv=fsync oflag=direct status=progress
      sync
      echo "done. You can remove the card."
    }

    # ------------------------------------------------------- macOS
    flash_darwin() {
      disk="$(basename "$DEV")"
      case "$disk" in
      disk[0-9]*) : ;;
      *) die "'$DEV' is not a /dev/diskN device" ;;
      esac
      case "$disk" in
      *s[0-9]*) die "'$DEV' is a partition slice; pass the whole disk (/dev/diskN)" ;;
      esac

      info="$(diskutil info "$disk")"
      # Internal, non-removable media is the system disk or a fixed
      # drive — never a target.
      echo "$info" | grep -qE 'Removable Media: *(Removable|Yes)' ||
        die "'$DEV' is not removable media; refusing"
      echo "$info" | grep -qE 'Internal: *No' ||
        die "'$DEV' reports as internal; refusing"

      size_b="$(echo "$info" | sed -n 's/.*Disk Size:.*(\([0-9]*\) Bytes.*/\1/p')"
      if [ -n "$size_b" ]; then
        check_size "$size_b"
      fi

      confirm "$disk" "$(echo "$info" | grep 'Disk Size' | head -n1 | sed 's/^ *//')"

      diskutil unmountDisk "$disk"
      echo "flashing $IMG -> /dev/r$disk ..."
      # rdisk (raw) is dramatically faster than disk on macOS.
      sudo dd if="$IMG" of="/dev/r$disk" bs="$BS"
      sync
      diskutil eject "$disk"
      echo "done. Card ejected."
    }

    case "$(uname -s)" in
    Linux) flash_linux ;;
    Darwin) flash_darwin ;;
    *) die "unsupported OS: $(uname -s) (flash manually with dd, carefully)" ;;
    esac
  '';

  meta = {
    description = "Flash the Floresta ${device.name} image to a card in a reader (guarded dd)";
  };
}
