#!/usr/bin/env bash
# qemu-test.sh — boot the pi0 image under QEMU before touching real
# hardware.  This is the lab's INTERACTIVE validation tool: the
# automated equivalent lives in checks.x86_64-linux.pi0-boot-test.
#
# First-boot behaviour is mirrored faithfully: stage 1 runs headless
# until the image repartitions itself and calls reboot (which halts on
# QEMU — the restart path needs the bcm2835 PM watchdog that QEMU does
# not model, hence also the initcall blacklist).  Stage 2 then boots
# the same, now-repartitioned image interactively: watch the full rc
# chain, log in as root / floresta, run pi0-bench.
#
# Not exercised here (hardware-only): the ROM/firmware SD boot chain
# and the dwc2 USB gadget (S30 logs an error and continues); the
# VideoCore is absent too (vchiq probe errors are expected noise).
#
# Usage: ./pi0/qemu-test.sh [image.img]     (x86_64-linux host)
# Exit QEMU with: Ctrl-A then X.
set -euo pipefail

IMG="${1:-}"
if [ -z "$IMG" ]; then
	IMG="$(nix build ".#pi0-sd-image" --no-link --print-out-paths | tail -n 1)/floresta-pi0-sdcard.img"
fi
[ -f "$IMG" ] || {
	echo "image '$IMG' not found" >&2
	exit 1
}

exec nix shell --inputs-from . nixpkgs#qemu nixpkgs#mtools -c bash -c '
set -euo pipefail
IMG="$1"
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT
cp "$IMG" "$WORK/sd.img" && chmod +w "$WORK/sd.img"
# Power-of-two size for QEMU; 512M sparse leaves the first-boot data
# partition big enough for a real mkfs.f2fs.
qemu-img resize -q -f raw "$WORK/sd.img" 512M
START=$(sfdisk -d "$WORK/sd.img" | grep "img1" | sed "s/.*start= *\([0-9]*\).*/\1/")
mcopy -o -i "$WORK/sd.img@@$((START * 512))" ::zImage "$WORK/zImage"
mcopy -o -i "$WORK/sd.img@@$((START * 512))" ::bcm2708-rpi-zero.dtb "$WORK/dtb"

APPEND="root=/dev/mmcblk0p2 rootfstype=squashfs ro rootwait init=/sbin/preinit console=ttyAMA0,115200 initcall_blacklist=bcm2835_pm_driver_init"

echo ">>> estagio 1: primeiro boot (reparticiona e halta no QEMU) ..."
qemu-system-arm -M raspi0 \
  -kernel "$WORK/zImage" -dtb "$WORK/dtb" -append "$APPEND" \
  -sd "$WORK/sd.img" -serial "file:$WORK/boot1.log" -monitor none -display none &
QPID=$!
for _ in $(seq 300); do
  grep -qE "System halted|login:" "$WORK/boot1.log" 2>/dev/null && break
  kill -0 $QPID 2>/dev/null || break
  sleep 1
done
kill $QPID 2>/dev/null || true
tail -n 5 "$WORK/boot1.log" || true

echo ""
echo ">>> estagio 2: segundo boot, interativo (login: root / floresta; sair: Ctrl-A X)"
exec qemu-system-arm -M raspi0 \
  -kernel "$WORK/zImage" -dtb "$WORK/dtb" -append "$APPEND" \
  -sd "$WORK/sd.img" -serial mon:stdio -display none
' -- "$IMG"
