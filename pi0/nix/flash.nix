# SPDX-License-Identifier: MIT OR Apache-2.0
#
# flash-pi0: flash the SD card *through the Pi itself* — no card
# reader, no typing /dev/sdX by hand (the most dangerous step of the
# manual flow).
#
# How: the BCM2835 boot ROM falls back to USB device mode when it
# finds nothing bootable on the SD card.  rpiboot (raspberrypi/usbboot)
# feeds it a tiny firmware that exposes the Pi's SD slot as USB mass
# storage on this machine; from there it is an ordinary disk — which
# this script identifies by *diffing* the disk list from before the Pi
# enumerated, never by guessing, and refuses to proceed on any
# ambiguity.
#
# Works on Linux and macOS (the darwin path shells out to the system's
# diskutil).  Exposed as `nix run .#flash-pi0`.
{ pkgs }:

pkgs.writeShellApplication {
  name = "flash-pi0";

  runtimeInputs = [
    pkgs.rpiboot
    pkgs.coreutils # GNU dd (status=progress), sha256sum, stat, head, truncate
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gawk
  ]
  ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.util-linux ];

  text = ''
    # diskutil/plutil/sudo are macOS system tools, deliberately not from
    # Nix; make sure their home is on PATH even in a bare environment.
    export PATH="$PATH:/usr/sbin:/usr/bin:/sbin:/bin"

    MSD_DIR=${pkgs.rpiboot}/share/rpiboot/msd
    OS="$(uname -s)"

    say() { echo ">>> $*"; }
    die() {
      echo "flash-pi0: ERROR: $*" >&2
      exit 1
    }

    # ------------------------------------------------------- image
    IMAGE="''${1:-}"
    if [ -z "$IMAGE" ]; then
      for c in result/floresta-pi0-sdcard.img result-pi0/floresta-pi0-sdcard.img; do
        if [ -f "$c" ]; then
          IMAGE="$c"
          break
        fi
      done
    fi
    if [ -z "$IMAGE" ]; then
      if [ -f flake.nix ] && grep -q "pi0-sd-image" flake.nix; then
        say "no image found; building .#pi0-sd-image first (hours on a first build)"
        nix build ".#pi0-sd-image" ||
          die "image build failed.  Note: the image itself only builds on \
    x86_64-linux — on macOS configure a Linux remote builder, or build it on a \
    Linux box and pass the path: flash-pi0 /path/to/floresta-pi0-sdcard.img"
        IMAGE=result/floresta-pi0-sdcard.img
      else
        die "no image found.  Run from the floresta-nix repo, or: flash-pi0 <image.img>"
      fi
    fi
    [ -f "$IMAGE" ] || die "image '$IMAGE' does not exist"
    IMG_BYTES="$(stat -c %s "$IMAGE")"
    say "image: $IMAGE ($((IMG_BYTES / 1024 / 1024)) MiB)"

    # dd and the device nodes need root; authenticate once, up front,
    # so the backgrounded rpiboot never stalls on a password prompt.
    say "sudo is needed for rpiboot (USB access on Linux) and dd"
    sudo -v

    # ------------------------------------------------------- disk listing
    list_disks() {
      if [ "$OS" = Linux ]; then
        lsblk -dno NAME,TYPE | awk '$2 == "disk" { print $1 }' | sort
      else
        diskutil list external physical |
          awk '/^\/dev\/disk/ { sub("/dev/", "", $1); print $1 }' | sort
      fi
    }

    baseline="$(list_disks)"

    # ------------------------------------------------------- rpiboot
    RPIBOOT_LOG="$(mktemp -t flash-pi0-rpiboot.XXXXXX)"
    cleanup() {
      if [ -n "''${RPIBOOT_PID:-}" ]; then
        kill "$RPIBOOT_PID" 2>/dev/null || true
      fi
      if [ -n "''${READBACK:-}" ]; then
        rm -f "$READBACK"
      fi
    }
    trap cleanup EXIT

    say "starting rpiboot (mass-storage firmware)..."
    if [ "$OS" = Linux ]; then
      # Raw USB access needs root on stock Linux (no udev rule assumed).
      # The log redirect intentionally runs as the invoking user, so
      # the user can read it afterwards.
      # shellcheck disable=SC2024
      sudo rpiboot -d "$MSD_DIR" >"$RPIBOOT_LOG" 2>&1 &
    else
      rpiboot -d "$MSD_DIR" >"$RPIBOOT_LOG" 2>&1 &
    fi
    RPIBOOT_PID=$!

    echo
    echo "  Connect the Pi Zero to this machine NOW:"
    echo "    * use the MIDDLE micro-USB port (labelled USB — the edge one is power-only)"
    echo "    * use a DATA cable (many micro-USB cables are charge-only)"
    echo "    * the SD card must be inserted, and must not be bootable"
    echo "      (already-flashed card?  run 'florestaos reflash' on the Pi first)"
    echo

    # ------------------------------------------------------- wait for the disk
    say "waiting for the Pi to enumerate as a disk (timeout 90s)..."
    disk=""
    for ((try = 0; try < 45; try++)); do
      sleep 2
      current="$(list_disks)"
      # New disks = in current, not in baseline.
      mapfile -t fresh < <(comm -13 <(echo "$baseline") <(echo "$current") | grep . || true)
      if [ "''${#fresh[@]}" -gt 1 ]; then
        die "more than one new disk appeared (''${fresh[*]}); refusing to guess. \
    Unplug other devices and retry."
      fi
      if [ "''${#fresh[@]}" -eq 1 ]; then
        disk="''${fresh[0]}"
        break
      fi
    done
    [ -n "$disk" ] || die "no new disk appeared.  Checklist: middle port? data \
    cable? card present and non-bootable?  rpiboot log: $RPIBOOT_LOG"

    # ------------------------------------------------------- validate
    if [ "$OS" = Linux ]; then
      vendor="$(cat "/sys/block/$disk/device/vendor" 2>/dev/null || true)"
      model="$(cat "/sys/block/$disk/device/model" 2>/dev/null || true)"
      case "$vendor $model" in
      *RPi* | *rpi* | *MSD*) : ;;
      *) die "new disk /dev/$disk does not identify as a Pi in USB boot mode \
    (vendor='$vendor' model='$model'); refusing" ;;
      esac
      size_b="$(lsblk -bndo SIZE "/dev/$disk")"
      desc="$(lsblk -ndo SIZE,MODEL "/dev/$disk" | tr -s ' ')"
      dev="/dev/$disk"
      rawdev="/dev/$disk"
    else
      info="$(diskutil info "$disk")"
      media="$(sed -n 's/.*Device \/ Media Name: *//p' <<<"$info")"
      case "$media" in
      *RPi* | *rpi* | *MSD* | *msd*) : ;;
      *) die "new disk $disk is '$media', not a Pi in USB boot mode; refusing" ;;
      esac
      if grep -q 'Internal: *Yes' <<<"$info"; then
        die "$disk reports as internal; refusing"
      fi
      size_b="$(sed -n 's/.*Disk Size:.*(\([0-9]*\) Bytes.*/\1/p' <<<"$info")"
      desc="$media, $((size_b / 1000 / 1000 / 1000)) GB"
      dev="/dev/$disk"
      rawdev="/dev/r$disk" # raw device: orders of magnitude faster on macOS
    fi

    [ -n "$size_b" ] || die "could not determine the size of $dev"
    [ "$size_b" -ge $((1024 * 1024 * 1024)) ] ||
      die "$dev is smaller than 1 GB — not a usable SD card"
    [ "$size_b" -le $((2 * 1024 * 1024 * 1024 * 1024)) ] ||
      die "$dev is larger than 2 TB — implausible for an SD card; refusing"

    # ------------------------------------------------------- confirm
    echo
    echo "  detected : $dev ($desc)"
    echo "  image    : $IMAGE"
    echo
    echo "ALL DATA ON $dev WILL BE DESTROYED."
    printf "Type '%s' to continue: " "$disk"
    read -r answer
    [ "$answer" = "$disk" ] || die "confirmation mismatch, aborting"

    # ------------------------------------------------------- unmount + flash
    DD="$(command -v dd)" # GNU dd, also for the sudo invocations below
    if [ "$OS" = Linux ]; then
      for part in "$dev"?*; do
        if [ -e "$part" ]; then
          sudo umount "$part" 2>/dev/null || true
        fi
      done
      say "flashing..."
      sudo "$DD" if="$IMAGE" of="$rawdev" bs=4M conv=fsync oflag=direct status=progress
    else
      diskutil unmountDisk "$disk" >/dev/null
      say "flashing..."
      sudo "$DD" if="$IMAGE" of="$rawdev" bs=4M conv=fsync status=progress
    fi
    sync

    # ------------------------------------------------------- verify
    # Read back exactly the image-sized prefix and compare hashes.
    # Catches the two classic failures: wrong disk and truncated write.
    say "verifying (reading back $((IMG_BYTES / 1024 / 1024)) MiB)..."
    expected="$(sha256sum "$IMAGE" | awk '{ print $1 }')"
    READBACK="$(mktemp -t flash-pi0-verify.XXXXXX)"
    mib_ceil=$(((IMG_BYTES + 1048575) / 1048576))
    if [ "$OS" = Linux ]; then
      # iflag=direct: bypass the page cache, or we might "verify" our
      # own dirty pages instead of what the card actually stored.
      sudo "$DD" if="$rawdev" of="$READBACK" bs=1M count="$mib_ceil" iflag=direct status=none
    else
      sudo "$DD" if="$rawdev" of="$READBACK" bs=1M count="$mib_ceil" status=none
    fi
    truncate -s "$IMG_BYTES" "$READBACK"
    actual="$(sha256sum "$READBACK" | awk '{ print $1 }')"
    [ "$actual" = "$expected" ] ||
      die "VERIFICATION FAILED: the card does not contain the image \
    (expected $expected, got $actual).  Do not boot from this card; re-run flash-pi0."
    say "verification OK"

    # ------------------------------------------------------- eject
    if [ "$OS" = Linux ]; then
      sync
    else
      diskutil eject "$disk" >/dev/null
    fi

    echo
    say "done!  Next steps:"
    echo "    1. (optional) re-plug the card/Pi and edit florestaos.conf on the FAT partition"
    echo "    2. disconnect the Pi and reconnect its power — it will boot the lab"
    echo "    3. reach it at ssh root@10.7.0.2 (password: floresta) over the USB cable"
  '';

  meta = {
    description = "Flash the Floresta pi0 image through the Pi's USB boot mode (rpiboot)";
  };
}
