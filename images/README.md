# images — operating-system images for small boards

Everything this repo knows about putting Floresta on an SBC lives here:
one directory per board, plus the shared machinery they all reuse.

```
images/
├── README.md              this file
├── default.nix            THE GATE — the only thing flake.nix imports
├── flash.nix              generic flasher: card reader + guarded dd
├── qemu-test.nix          generic interactive boot under emulation
├── microbench.nix         the bench/ crate, cross-built with a board's toolchain
├── bench/                 CPU microbenchmark crate, cross-built per board
├── harness/               bench-node: the host-side measurement harness
│
├── rasp-pi-zero/          ← complete.  Buildroot/ARMv6, the reference board
├── rasp-pi-zero-w/        ← scaffold.  re-exports rasp-pi-zero + WiFi
├── orange-pi-zero-2-W/    ← scaffold.  re-exports florestaos + H618 boot
└── florestaos/            ← scaffold.  generic NixOS base for aarch64+
```

> **Status:** only `rasp-pi-zero` is implemented. The other three
> directories are scaffolds: the shape is committed, the content is not
> written. Their `.nix` files `throw` if imported, and
> `images/default.nix` deliberately exports nothing for them.

---

## The board contract

A board directory is a Nix function `{ pkgs, inputs, system }` returning:

```nix
{
  meta,                # the board profile — see below.  REQUIRED.
  packages ? { },      # derivations (images, component builds)
  checks ? { },        # acceptance tests, wired into `nix flake check`
  apps ? { },          # runnable programs; also merged into packages
  devShells ? { },     # optional
}
```

`images/default.nix` merges those into the flake's outputs. Attribute
names must already be globally unique — there is no automatic prefixing,
because output names are a user-facing promise.

The convention is **`<thing>-<board>`**, board name last, so everything
about one board sorts together in `nix flake show`:

| output | what it is |
|---|---|
| `image-<board>` | the flashable image |
| `os-<board>` | the same image with NO Floresta in it |
| `payload-<board>` | the rootfs overlay that joins the two |
| `florestad-<board>` | `florestad` + `floresta-cli`, cross-built for it |
| `microbench-<board>` | the `bench/` crate, cross-built for it |
| `flash-<board>` | the best flasher that board has |
| `flash-<board>-reader` | the generic card-reader flasher |
| `qemu-test-<board>` | interactive boot under emulation |
| `boot-test-<board>` | the same boot, asserted, in `nix flake check` |
| `devShells.<board>` | the board's build environment |
| `bench-node` | the measurement harness (board-agnostic) |
| `run-<board>-signet` | `bench-node --target <board> --network signet` |

**Platform gating lives in the board, not in the aggregator.** A board
whose image can only be *built* on `x86_64-linux` returns empty
`packages`/`checks` elsewhere, while still exporting its host-side
tooling everywhere — the lab host may well be a Mac.

### The files inside a board directory

One responsibility per file, because the file boundary *is* the rebuild
boundary. Splitting them is not tidiness — it is what decides how much
you pay for a one-line change.

| file | role |
|---|---|
| `README.md` | top-level documentation of that board: what it is, why it is built the way it is |
| `default.nix` | the board's own gate: `meta` plus wiring. No build logic |
| `toolchain.nix` | *how* to cross-compile for this board: target triple, cc, linker, cargo env |
| `patches.nix` | *what* to change in Floresta's source for this board. Pure data |
| `node.nix` | **the node**: `florestad` + `floresta-cli`. Consumes toolchain + patches |
| `payload.nix` | the **seam**: node and microbenchmark as one rootfs overlay |
| `system.nix` | **the OS**: how the image is assembled. Takes the payload, or none |
| `system-test.nix` | acceptance test for the assembled image, before any hardware |
| `flash.nix` | the board's own flasher, if it has a better one than the generic |
| `assets/` | everything that is not Nix: rootfs overlays, defconfigs, firmware config, init scripts |

### The node is not the image

`system.nix` takes a **single** `payload` input — the overlay from
`payload.nix` — instead of one argument per binary. That one indirection
buys two things:

* `payload = null` builds the **OS alone**: same kernel, same rootfs, no
  Floresta. On `rasp-pi-zero` that is 1502 derivations instead of 2554,
  and it drops the ARMv6 cross-gcc (≈40 min on a cold store) entirely.
  It is how you iterate on init scripts and kernel config.
* The node builds, tests and versions on its own. The
  `florestad-smoke-<board>` check depends on `node.nix` only, so it runs
  in seconds without Buildroot anywhere in its closure.

Measured on `rasp-pi-zero` — editing `patches.nix` (the node's source
patches) rebuilds:

| output | rebuilds? | |
|---|---|---|
| `florestad-<board>` | yes | it is the thing being patched |
| `image-<board>` | yes | the payload changed |
| `microbench-<board>` | **no** | it only needs `toolchain.nix` |
| `os-<board>` | **no** | the OS does not know the node exists |

> **Byte-sensitive strings.** `buildPhase`/`installPhase`/`postPatch`
> bodies are part of the derivation hash. Re-wrapping a *comment* inside
> one of them costs a full ARMv6 rebuild — those blocks carry a `do not
> rewrap` note for that reason.

### `meta`: the board profile

`meta` is the board reduced to facts about the *hardware*, with nothing
about how its image is built. The shared tooling is instantiated from
it, so no board reimplements `dd` or a QEMU command line:

```nix
meta = {
  name = "rasp-pi-zero";             # directory name; suffixes output names
  description = "...";
  platforms = [ "x86_64-linux" ];    # where the image can be BUILT

  image = {
    file = "floresta-rasp-pi-zero-sdcard.img";  # filename inside the derivation
    attr = "image-rasp-pi-zero";             # flake attr that produces it
  };

  flash = {
    minBytes = 1024 * 1024 * 1024;     # refuse implausible targets
    maxBytes = 1024 * 1024 * 1024 * 1024;
    blockSize = "4M";
  };

  qemu = {
    emulator = "qemu-system-arm";
    machine = "raspi0";
    kernel = "zImage";                 # names in the FAT boot partition
    dtb = "bcm2708-rpi-zero.dtb";
    sdSize = "512M";                   # power of two: QEMU insists
    append = "root=/dev/mmcblk0p2 ...";
    firstBoot = true;                  # image repartitions itself, then reboots
  };
};
```

`image` and `qemu` are what make a board *flashable* and *emulatable*.
Omitting them is how a scaffolded board (or a non-board base like
`florestaos`) opts out: the aggregator skips it instead of exporting a
`flash-…` that could not possibly work.

---

## Shared machinery

### `flash.nix` — the generic flasher

`nix run .#flash-<board>-reader -- /dev/sdX` — card reader plus a
hand-typed device node, translated from the old `pi0/flash.sh`. It
refuses whole classes of foot-gun: partitions instead of whole disks,
anything mounted, non-removable or internal disks, implausible sizes —
and still makes you type the device name back. `dd` does not care
whether the target is your SD card or your root disk; this wrapper does.

**Output naming.** `flash-<board>` is the canonical name: *the best path
that board has*. It defaults to this generic flasher, and a board that
can flash itself overrides it from its own `apps` — see
`rasp-pi-zero/flash.nix`, which boots the Pi into USB mass-storage mode
and **detects** the target disk rather than trusting what you typed. The
card-reader fallback always stays reachable as `flash-<board>-reader`:

| output | rasp-pi-zero | a board with no self-flashing path |
|---|---|---|
| `flash-<board>` | rpiboot, detects the disk | the generic flasher |
| `flash-<board>-reader` | the generic flasher | the generic flasher |

### `qemu-test.nix` — the generic emulator run

`nix run .#qemu-test-<board>` boots the image under QEMU, interactively,
before any hardware is involved. Its automated sibling is each board's
`system-test.nix` (in `nix flake check`): same two boots, same kernel
command line, asserting on the serial log instead of handing you a
console.

Emulation cannot prove the ROM/firmware boot chain, USB gadget modes, or
any vendor coprocessor QEMU omits. Expect probe errors for those and
read past them.

### `bench/` and `harness/`

* [`bench/`](bench) — a small Rust crate of CPU microbenchmarks built
  from the same crates Floresta uses on its hot path (`bitcoin_hashes`,
  `secp256k1`, `rustreexo`), cross-compiled for each board by its
  toolchain via `microbench.nix`. Board-agnostic by design: the numbers are only
  comparable because the code is identical.
* [`harness/`](harness) — `bench-node`, the measurement harness. Runs
  entirely on the **lab host**; the only thing that reaches the board is
  POSIX `sh` over SSH. Its `targets/*.nix` profiles describe boards from
  the harness' point of view, which is a different (and deliberately
  smaller) thing than a `meta` here.

  It is exported through the gate, not around it: `bench-node` and
  `run-<board>-signet` come out of `images/default.nix`, and the runner
  aliases are derived from which `targets/<board>.nix` files exist — add
  the profile and the runner appears.

---

## Two lineages, and why

| | ARMv6 / Buildroot | aarch64 / NixOS |
|---|---|---|
| base | `rasp-pi-zero` | `florestaos` |
| boards | `rasp-pi-zero-w` | `orange-pi-zero-2-W` |
| why | `armv6l` has no nixpkgs binary cache — NixOS would mean building the world | `aarch64-linux` is cached, so there is no excuse for a hand-rolled rootfs |

Boards are **additive**. A derived board re-exports its base and
overrides only its delta — no second Buildroot tree, no second
defconfig, no copied overlay. If a change is not specific to the derived
board, it belongs in the base.

## Adding a board

1. `mkdir images/<board>` and copy the file set above.
2. Write `meta` first — the flasher and the QEMU runner fall out of it.
3. Re-export the closest base (`rasp-pi-zero` or `florestaos`) and keep
   only the delta.
4. Register it in the `boards` attrset in `images/default.nix`.
5. Nothing to register with the linters: `flake.nix` picks up every
   `.nix` file under `images/` by extension.
6. If the board is to be benchmarked, add a profile in
   `harness/targets/`.
