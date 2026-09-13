# florestaos — a generic NixOS that only runs Floresta

> **Status: scaffold.** The directory shape is in place; the content is
> not written yet. Nothing here is exported by the flake — see
> `../README.md` for the contract this has to fill.

Not a board. This is the **base image** for every board in this
directory that can afford NixOS — currently
[`../orange-pi-zero-2-W`](../orange-pi-zero-2-W) — exactly as
[`../rasp-pi-zero`](../rasp-pi-zero) is the base for the
Buildroot/ARMv6 lineage.

Two lineages, one reason: `armv6l` has no nixpkgs binary cache, so a
NixOS for the Pi Zero means building the world. `aarch64-linux` does, so
there is no excuse for a hand-rolled rootfs there.

## Why it keeps the Buildroot image's name

The Pi Zero's Buildroot userspace already calls itself `florestaos` — it
ships a `florestaos` command, a `florestaos.conf` on the FAT partition
and `florestaos:`-prefixed init logs. This directory is the *same
product* where NixOS is affordable, and it keeps that surface
deliberately: same config file, same paths, same command names. The
[`../harness`](../harness) must not be able to tell the two apart; a
board profile in `harness/targets/` is then only a statement about
hardware, not about which OS happens to be underneath.

## What goes where

| file | content |
|---|---|
| `system.nix` | NixOS modules: [`../../lib/floresta-service.nix`](../../lib/floresta-service.nix) plus lab defaults — read-only root, zram, f2fs data partition, minimal closure, serial console, SSH |
| `system-test.nix` | a `nixosTest`: boot it, assert `florestad` answers RPC |

Deliberately absent:

* **no `assets/`** — NixOS generates its own `/etc`; there is nothing to
  overlay.
* **no `patches.nix`** — `florestad` for aarch64 comes from this flake's
  ordinary builds. The cross-compilation hacks in
  `../rasp-pi-zero/patches.nix` exist only because ARMv6 musl has none
  of that luxury.
* **no bootloader, DTB or `sdImage`** — those are board facts. A board
  re-exporting this adds them in its own `system.nix`.
