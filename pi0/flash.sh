#!/usr/bin/env bash
# flash.sh — FALLBACK flasher: card reader + hand-typed device.
#
# The primary flow is `nix run .#flash-pi0`, which flashes through the
# Pi's own USB boot mode and *detects* the target disk instead of
# trusting a typed /dev/sdX.  Use this script only when the rpiboot
# path is not an option (no data cable, broken OTG port).
#
# dd does not care whether the target is your SD card or your root
# disk; this wrapper does.
#
# Usage:
#   ./pi0/flash.sh /dev/sdX            (Linux)
#   ./pi0/flash.sh /dev/diskN          (macOS)
#   ./pi0/flash.sh /dev/sdX path/to/floresta-pi0-sdcard.img
#
# With no image argument, uses ./result/floresta-pi0-sdcard.img (what
# `nix build .#pi0-sd-image` leaves behind).
set -euo pipefail

die() {
	echo "flash.sh: ERROR: $*" >&2
	exit 1
}

DEV="${1:-}"
IMG="${2:-result/floresta-pi0-sdcard.img}"

[ -n "$DEV" ] || die "usage: flash.sh <device> [image]"
[ -f "$IMG" ] || die "image '$IMG' not found — run: nix build .#pi0-sd-image"
[ -e "$DEV" ] || die "device '$DEV' does not exist"

OS="$(uname -s)"

# ---------------------------------------------------------------- Linux
flash_linux() {
	[ -b "$DEV" ] || die "'$DEV' is not a block device"
	local name
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
		die "'$DEV' has mounted filesystems; unmount them first (umount ${DEV}*)"
	fi

	# A SD card presents as removable (or at least as an mmcblk/usb
	# device).  A non-removable SATA/NVMe disk is almost certainly
	# not where the user wants 200MB of Pi image.
	local rm tran
	rm="$(lsblk -ndo RM "$DEV" | tr -d ' ')"
	tran="$(lsblk -ndo TRAN "$DEV" | tr -d ' ')"
	case "$name" in
	mmcblk*) : ;; # SD slot
	*)
		if [ "$rm" != 1 ] && [ "$tran" != usb ]; then
			die "'$DEV' looks like a fixed system disk (RM=$rm TRAN=${tran:-?}); refusing"
		fi
		;;
	esac

	# Size sanity: SD cards for this lab are 4GB–1TB. Anything outside
	# that is suspicious enough to refuse.
	local size_b
	size_b="$(lsblk -bndo SIZE "$DEV")"
	[ "$size_b" -ge $((1024 * 1024 * 1024)) ] ||
		die "'$DEV' is smaller than 1GB; not a usable SD card"
	[ "$size_b" -le $((1024 * 1024 * 1024 * 1024)) ] ||
		die "'$DEV' is larger than 1TB; refusing to believe it is an SD card"

	confirm "$name" "$(lsblk -ndo SIZE,MODEL "$DEV" | tr -s ' ')"

	echo "flashing $IMG -> $DEV ..."
	sudo dd if="$IMG" of="$DEV" bs=4M conv=fsync oflag=direct status=progress
	sync
	echo "done. You can remove the card."
}

# ---------------------------------------------------------------- macOS
flash_darwin() {
	local disk info
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
	local size_b
	size_b="$(echo "$info" | sed -n 's/.*Disk Size:.*(\([0-9]*\) Bytes.*/\1/p')"
	if [ -n "$size_b" ]; then
		[ "$size_b" -ge $((1024 * 1024 * 1024)) ] ||
			die "'$DEV' is smaller than 1GB; not a usable SD card"
		[ "$size_b" -le $((1024 * 1024 * 1024 * 1024)) ] ||
			die "'$DEV' is larger than 1TB; refusing to believe it is an SD card"
	fi

	confirm "$disk" "$(echo "$info" | grep 'Disk Size' | head -n1 | sed 's/^ *//')"

	diskutil unmountDisk "$disk"
	echo "flashing $IMG -> /dev/r$disk ..."
	# rdisk (raw) is dramatically faster than disk on macOS.
	sudo dd if="$IMG" of="/dev/r$disk" bs=4m
	sync
	diskutil eject "$disk"
	echo "done. Card ejected."
}

confirm() {
	local name="$1" desc="$2"
	echo
	echo "  target : $DEV ($desc)"
	echo "  image  : $IMG"
	echo
	echo "ALL DATA ON $DEV WILL BE DESTROYED."
	printf "Type '%s' to continue: " "$name"
	read -r answer
	[ "$answer" = "$name" ] || die "confirmation mismatch, aborting"
}

case "$OS" in
Linux) flash_linux ;;
Darwin) flash_darwin ;;
*) die "unsupported OS: $OS (flash manually with dd, carefully)" ;;
esac
