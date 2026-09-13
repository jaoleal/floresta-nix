# rasp-pi-zero-w — Raspberry Pi Zero W

> **Status: scaffold.** The directory shape is in place; the content is
> not written yet. Nothing here is exported by the flake — see
> `../README.md` for the board contract this has to fill.

Identical silicon to [`../rasp-pi-zero`](../rasp-pi-zero) (BCM2835,
ARM1176 at 1 GHz, 512 MB) with one addition that changes the workflow
completely: a **BCM43438 on SDIO** — WiFi and Bluetooth.

For the bench lab that addition cuts both ways:

* **Good** — the board can reach the network without the USB gadget, so
  the OTG port stays free and the harness can talk to it over WiFi
  instead of `10.7.0.2`.
* **Bad** — WiFi costs RAM, CPU and *power*, on a board that has very
  little of the first two and whose energy numbers are the point of the
  lab. Any measurement taken with `wlan0` up is not comparable to a
  Pi Zero v1.3 run. Expect the profile to keep the radio off by default.

## Design: additive, not a fork

This board **re-exports `../rasp-pi-zero`** and patches it. There is no
second Buildroot tree, no second defconfig, no second rootfs overlay —
only the delta lives here:

| file | delta over the base board |
|---|---|
| `patches.nix` | none expected — same ARMv6 musl cross builds |
| `system.nix` | brcmfmac firmware, SDIO + cfg80211 kernel options, `wpa_supplicant` |
| `assets/` | `wpa_supplicant.conf` template, WiFi init script |
| `system-test.nix` | base boot test; the radio is hardware-only under QEMU |

If a change here needs to touch anything that is *not* WiFi, it belongs
in the base board instead.
