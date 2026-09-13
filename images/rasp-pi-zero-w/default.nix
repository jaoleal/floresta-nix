# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Raspberry Pi Zero W — SCAFFOLD.
#
# Same SoC as ../rasp-pi-zero (BCM2835, ARM1176, 512 MB), plus a
# BCM43438 on SDIO for WiFi/Bluetooth.  So this board is *additive*: it
# re-exports ../rasp-pi-zero and patches in the wireless bits, rather
# than carrying a second copy of the Buildroot tree.
#
# What the real implementation has to add on top of the base board:
#
#   * ./patches.nix     — nothing new expected: the ARMv6 musl cross
#                         builds are identical.  Re-export the base.
#   * ./system.nix      — base defconfig + brcmfmac firmware
#                         (linux-firmware: brcm/brcmfmac43430-sdio.*),
#                         SDIO/mmc + cfg80211 in the kernel fragment,
#                         wpa_supplicant in the package set, and a
#                         wlan0 entry in the network overlay.
#   * ./assets/         — only what differs: the wpa_supplicant
#                         template and the WiFi init script.  Everything
#                         else stays in ../rasp-pi-zero/assets.
#   * ./system-test.nix — the base boot test; QEMU cannot model the
#                         SDIO WiFi, so wireless stays hardware-only.
#
# Its `meta` differs from the base in name, image file and the dtb QEMU
# needs (bcm2708-rpi-zero-w.dtb).
_:

{
  meta = {
    name = "rasp-pi-zero-w";
    description = "Raspberry Pi Zero W — Pi Zero v1.3 plus BCM43438 WiFi/BT (SDIO)";
    platforms = [ "x86_64-linux" ];
    # No `image` / `qemu` key yet: images/default.nix skips scaffolded
    # boards instead of exporting a flasher that cannot work.
  };
}
