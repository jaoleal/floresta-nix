# orange-pi-zero-2-W — Orange Pi Zero 2W

> **Status: scaffold.** The directory shape is in place; the content is
> not written yet. Nothing here is exported by the flake — see
> `../README.md` for the board contract this has to fill.

**Allwinner H618** — four Cortex-A53 cores (aarch64, *with* the ARMv8
crypto extensions, so hardware SHA-256), 1–4 GB LPDDR4, onboard
WiFi/BT, USB-C power and data.

In the lab this board is the **counterweight** to the Pi Zeros: same
`florestad`, same harness, hardware roughly an order of magnitude
faster. The numbers worth reading are the *ratios* — how much of
Floresta's IBD cost is SHA-256 that hardware can absorb, and how much is
everything else.

## Design: NixOS, not Buildroot

`aarch64-linux` has a nixpkgs binary cache. That single fact flips the
build strategy: where [`../rasp-pi-zero`](../rasp-pi-zero) must
hand-roll a Buildroot rootfs because `armv6l` would mean *building the
world*, this board can just be NixOS.

So it **re-exports [`../florestaos`](../florestaos)**, the generic
NixOS-based Floresta image, and patches in the board's boot chain:

| file | delta over `../florestaos` |
|---|---|
| `patches.nix` | mainline U-Boot for the H618, board DTB if needed |
| `system.nix` | `sd-image` wiring: U-Boot, DTB, `ttyS0` console, kernel ≥ 6.6 |
| `assets/` | U-Boot environment / `boot.scr`, AW859A firmware if missing upstream |
| `system-test.nix` | a real `nixosTest` — the guest is NixOS, so the standard driver works |

Anything that is not H618-specific belongs in `../florestaos` instead.
