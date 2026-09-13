# orange-pi-zero-2-W — Orange Pi Zero 2W

**Allwinner H618** — four Cortex-A53 cores (aarch64, *with* the ARMv8
crypto extensions, so hardware SHA-256), 1–4 GB LPDDR4, onboard
WiFi/BT, USB-C, and **no ethernet port**.

In the lab this board is the **counterweight** to
[`../rasp-pi-zero`](../rasp-pi-zero): same `florestad`, same harness,
hardware roughly an order of magnitude faster. The numbers worth reading
are the *ratios* — how much of Floresta's IBD cost is SHA-256 that
silicon can absorb, and how much is everything else.

It also runs **the configuration upstream actually ships**,
`bitcoinkernel` included, which the 32-bit Pi Zero cannot. That alone
makes it the more representative of the two.

> **Status: builds, not yet booted.** Everything here evaluates and
> instantiates; nothing has run on the hardware, because the board's card
> is still empty. Treat the boot chain below as carefully-sourced but
> unverified until the first successful boot.

## NixOS, not Buildroot

`aarch64-linux` has a nixpkgs binary cache. That single fact flips the
build strategy: where the Pi Zero must hand-roll a Buildroot rootfs
because `armv6l` would mean *building the world*, almost this entire
closure is **downloaded**.

The consequences run all the way down, and the two boards' files read as
a before/after of that one difference:

| | rasp-pi-zero | this board |
|---|---|---|
| `toolchain.nix` | ~120 lines: fenix rust-std, `pkgsCross.muslpi`, a `-static` linker wrapper, a `CMAKE_TOOLCHAIN_FILE` | `pkgs.rustPlatform`, and nothing else |
| `patches.nix` | bitcoinkernel ripped out, 32-bit mmap clamp | **does not exist** — no source changes needed |
| `node.nix` | ~90 lines of `CARGO_ENCODED_RUSTFLAGS` and a `readelf` guard | three lines of wiring |
| `system.nix` | Buildroot, driven offline from a pinned download FOD | `nixosSystem` + the `sd-image` module |
| `system-test.nix` | greps a serial log (busybox cannot host the test driver) | a real `nixosTest` |

The absence of `patches.nix` is the finding, not an omission.

## The boot chain

No UEFI, no vendor firmware blob, no FAT boot partition:

```
BROM  reads an eGON header 8 KiB into the card
  └─ SPL      (u-boot-sunxi-with-spl.bin, dd'd there by sdImage.postBuildCommands)
      └─ BL31 (armTrustedFirmwareAllwinnerH616 — the H618 is a minor H616 revision)
          └─ U-Boot proper
              └─ /boot/extlinux/extlinux.conf   on the ext4 root
                  └─ kernel + sun50i-h618-orangepi-zero2w.dtb
```

Pieces, and where they come from in the pin:

* **U-Boot** — nixpkgs has `ubootOrangePiZero2` (H616) and
  `ubootOrangePiZero3` (H618) but *not* the Zero 2W, so `system.nix`
  builds the same recipe against `orangepi_zero2w_defconfig`, which
  mainline U-Boot does carry (verified present in 2025.10).
* **Device tree** — `allwinner/sun50i-h618-orangepi-zero2w.dtb`, verified
  present in the pin's kernel (6.12.93). `hardware.deviceTree.name` is
  what makes the extlinux builder emit the `FDT` line; without it U-Boot
  falls back to `FDTDIR` and can pick the wrong one.
* **FIRMWARE partition** — created by the `sd-image` module and left
  **empty**. It exists only for the Raspberry Pi family.

## Instrument, not appliance

`florestad` is installed, configured and **stopped**. It does not start
at boot.

That is deliberate: [`../harness`](../harness) launches `florestad`
itself, with its own datadir and log. A node already running from boot
would fight it for the datadir and for the metrics port, which floresta
hardcodes to `3333` — two florestads means measurements that mean
nothing.

```bash
systemctl start floresta      # when you want a node
nix run .#run-orange-pi-zero-2-W-signet -- --host <ip>   # when you want numbers
```

Pass `autostart = true` to `system.nix` to turn this into an appliance
instead.

## Getting in, on a board with no ethernet

WiFi is the only network interface. `system.nix` takes an optional
`wifi = { ssid, psk }`; **the psk lands in the world-readable Nix
store**, which is acceptable for a bench instrument on a lab network and
for nothing else. Without it the board comes up reachable only over the
serial console (`ttyS0`, 115200, on the 13-pin header).

`root` has the password `floresta` — the same deliberate concession the
Pi Zero image makes, so a freshly flashed card is usable when you have
no serial cable. Pass `authorizedKeys` to use keys instead. Note the
password lives in the **board** module, not the lab module, precisely so
that [`../florestaos`](../florestaos) can adopt the lab half without
inheriting it.

## Building it

Outputs live under `aarch64-linux`, not under your host's system:

```bash
nix build .#packages.aarch64-linux.image-orange-pi-zero-2-W
```

That is a real constraint, not a preference. The closure is almost
entirely substitutable from `cache.nixos.org`, so building it *natively*
is nearly free — while cross-compiling it from x86_64 would rebuild
glibc, systemd and the kernel locally for no gain. From an x86_64 host
you therefore need one of:

* **binfmt emulation** — on NixOS,
  `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];` on the build host.
  Cached paths are still downloaded; only the handful of derivations that
  must actually run get emulated.
* an **aarch64 remote builder**.

Without either, `nix build` fails with *"a 'aarch64-linux' with features
{} is required to build … but I am a 'x86_64-linux'"*. If you would
rather cross-compile anyway, `toolchain.nix` is where that strategy
belongs.

Component outputs, buildable independently:

* `.#packages.aarch64-linux.florestad-orange-pi-zero-2-W` — the node alone
* `.#packages.aarch64-linux.microbench-orange-pi-zero-2-W` — the shared bench crate
* `.#packages.aarch64-linux.uboot-orange-pi-zero-2-W` — the boot chain piece
* `.#packages.aarch64-linux.toplevel-orange-pi-zero-2-W` — the system closure
  without the image around it; the counterpart of `os-rasp-pi-zero` for
  iterating on the NixOS config

## Layout

```
images/orange-pi-zero-2-W/
├── README.md            this file
├── default.nix          the board's gate: meta + wiring, no build logic
├── toolchain.nix        how to compile for aarch64 (almost nothing)
├── node.nix             THE NODE: florestad + floresta-cli
├── system.nix           THE OS: two modules — `lab` and `board`
├── system-test.nix      a real nixosTest, on the lab module alone
└── assets/              nothing yet — NixOS generates its own /etc
```

There is no `patches.nix` (see above) and no `payload.nix`: NixOS
installs the node through the service unit, so there is no rootfs
overlay to splice in — the Pi Zero's `payload.nix` seam exists only
because Buildroot needs one.

## What is not verified yet

Honest list, to be closed against hardware:

* **Nothing has booted.** The boot chain is assembled from the pin's own
  sources and from how nixpkgs treats the sibling H616/H618 boards, but
  no card has been written.
* **`lab-test-orange-pi-zero-2-W` has not been run** — it needs an
  aarch64 builder, same constraint as the image.
* The harness profile
  [`../harness/targets/orange-pi-zero-2-W.nix`](../harness/targets/orange-pi-zero-2-W.nix)
  carries values marked `NOT MEASURED` — the thermal zone index and the
  power meter. The `rasp-pi-zero` profile was written the other way round,
  measured first, and that is the standard to hold this one to.
