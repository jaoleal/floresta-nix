# rasp-pi-zero — Floresta bench lab for the Raspberry Pi Zero v1.3

A flashable SD card image that turns the original Raspberry Pi Zero
(ARMv6 ARM1176 @ 1 GHz, 512 MB RAM, no WiFi/Bluetooth, one micro-USB
OTG port) into a **benchmark laboratory** for `florestad`: the most
hostile environment we can cheaply put it in — no SHA hardware
acceleration, almost no RAM, storage that lies about latency.

This is *not* a production node appliance. It is an instrument.

The whole workflow needs one USB data cable and zero peripherals —
the SD card never has to leave the Pi:

```
nix run .#flash-rasp-pi-zero               # builds if needed, then flashes
                                  # THROUGH the Pi via USB boot mode
# edit florestaos.conf on the FAT partition (any OS)
# reconnect the Pi's power
# ...wait (hours or days, that is the point)...
# copy results/ off — over SSH, or by reading the FAT partition
```

---

## How it is built (and why this way)

**Buildroot builds the OS image; Nix orchestrates.** `armv6l` has no
binary cache in nixpkgs, so a pure cross-compiled NixOS for this board
means building the world. Instead, `nix build .#image-rasp-pi-zero`:

1. Cross-compiles `florestad`, `floresta-cli` and `floresta-microbench` as
   **static musl** binaries for `arm-unknown-linux-musleabihf`, using
   the exact same fenix + `--target` machinery the Android outputs of
   this flake use (`images/rasp-pi-zero/patches.nix`). Static linking means the
   binaries owe nothing to the image's libc.
2. Runs Buildroot **non-interactively** from a committed defconfig +
   committed `BR2_EXTERNAL` tree (`images/rasp-pi-zero/assets/buildroot/`), injecting the
   Rust binaries as a rootfs overlay. Buildroot never needs a Rust
   toolchain (its prebuilt one would not even run inside the Nix
   sandbox).
3. Buildroot downloads are captured in a **fixed-output derivation**
   pinned by `dlHash`, so the image build itself runs fully sandboxed
   and offline. The artifact is not Nix-native, but the build is
   declarative and pinned — same philosophy as the rest of
   floresta-nix.

No `nixos-generators`, no external image tooling: Buildroot's genimage
produces the `.img`.

### The `dlHash` TOFU step (maintainers)

`images/rasp-pi-zero/system.nix` pins the Buildroot download closure by content
hash. After **any** change that alters what Buildroot downloads
(defconfig package changes, Buildroot version bump):

1. set the `dlHash` default in `images/rasp-pi-zero/system.nix` to
   `pkgs.lib.fakeHash`,
2. `nix build .#buildroot-downloads-rasp-pi-zero` — it fails printing the real
   hash,
3. commit the real hash back as the `dlHash` default.

(The tree as first committed ships with `fakeHash` — the first build
on x86_64-linux performs this step once.)

**Nix caches fixed-output derivations by hash**: a stale `dlHash`
would silently reuse the *old* downloads. The derivation name embeds a
fingerprint of the defconfig so this mistake surfaces as a loud
hash-mismatch error instead of a wrong image.

### Reproducibility

`BR2_REPRODUCIBLE=y` plus fully pinned inputs (Buildroot tarball hash,
`BR2_DOWNLOAD_FORCE_CHECK_HASHES`, the flake's `floresta-master` pin,
the fixed-output download dir). Two builds of the same revision are
*intended* to produce bit-identical images; the known residual risks
are FAT filesystem construction (mtools timestamps — normalized by
`BR2_REPRODUCIBLE`'s `SOURCE_DATE_EPOCH`, but mtools has had
regressions) and squashfs orderings. If you catch a divergence, diff
`output/images/` between builds and open an issue with the offender —
that is acceptance criterion #2 of this subproject being watched.

---

## SD card layout

| # | FS       | Size    | Mount        | Contents |
|---|----------|---------|--------------|----------|
| 1 | FAT32    | 128 MB  | `/boot` (rw) | RPi firmware, kernel, `config.txt`, `cmdline.txt`, **`florestaos.conf`**, **`results/`** |
| 2 | squashfs | 64 MB   | `/` (ro)     | BusyBox, `florestad`, `floresta-microbench`, init scripts |
| 3 | f2fs     | rest    | `/data` (rw) | florestad datadir, bench CSVs, scratch |

The FAT partition is deliberate: **edit the config and collect results
from any OS** by just plugging the card into a computer. No SSH
required, ever.

The rootfs is immutable squashfs; `/etc` and `/var` are tmpfs-backed
overlayfs (writes evaporate at reboot). Pulling the power can never
corrupt the OS — at worst you lose the last few sampler rows.

**First boot behavior:** the flashed image contains only partitions 1
and 2. On first boot the system creates partition 3 spanning the rest
of the card, **reboots once** (the kernel cannot re-read the partition
table under a mounted root), then formats it as f2fs. Total overhead:
~30 seconds, once.

---

## Configuration: `florestaos.conf`

Lives at the FAT root. `key=value`, `#` comments, CRLF tolerated.
Malformed values fall back to safe defaults **and are reported** in
`results/boot-<timestamp>.log`, which always echoes the effective
configuration a boot actually used.

| key | default | values / meaning |
|-----|---------|------------------|
| `mode` | `node` | `node`, `bench-micro`, `bench-ibd`, `bench-assume` |
| `network` | `signet` | `bitcoin`, `signet`, `testnet4` |
| `assume_utreexo` | `true` | node mode only; bench modes decide themselves |
| `assume_valid` | `hardcoded` | `hardcoded`, `0` (verify **all** scripts), or a block hash |
| `ibd_stop_height` | `0` | stop bench at height (0 = no limit) |
| `ibd_time_budget_hours` | `48` | stop bench after N hours, whichever first |
| `sample_interval_secs` | `60` | sampler period |
| `results_sync_every` | `5` | rows between CSV syncs to the FAT |
| `bench_end` | `poweroff` | `poweroff` or `idle` after a bench finishes |
| `usb_gadget` | `ecm` | `ecm` (Linux/macOS hosts) or `rndis` (Windows) |
| `usb_ip` | `10.7.0.2/24` | Pi side of the USB link |
| `usb_gateway` | `10.7.0.1` | host side / default route |
| `dns` | `1.1.1.1` | resolver once NAT is up |
| `ntp_server` | `pool.ntp.org` | first thing contacted after link-up |
| `zram_mb` | `256` | compressed swap in RAM; 0 disables |
| `extra_flags` | *(empty)* | appended verbatim to `florestad` |

### Boot modes

* **`node`** — run `florestad` as a normal service on the configured
  network. Data persists across boots.
* **`bench-micro`** — no network needed: CPU microbenchmarks with the
  same crates florestad uses (bulk SHA256, double-SHA256 of headers,
  secp256k1 ECDSA verify, utreexo proof verify) plus SD sequential/4k
  throughput via dd. Writes one CSV, then `bench_end`.
* **`bench-ibd`** — real IBD **from a wiped datadir** with
  `--no-assume-utreexo`, sampler running, until `ibd_stop_height` /
  `ibd_time_budget_hours`. Set `assume_valid=0` for the full-script
  torture test.
* **`bench-assume`** — same, but measuring the assume-utreexo fast
  path (florestad's default behavior).

⚠️ both IBD bench modes **wipe `/data/floresta` on every boot** — a
cold start is the thing being measured.

---

## Results

Everything lands in `results/` on the FAT partition:

* `boot-<ts>.log` — effective config + system info of each boot.
* `<mode>-<network>-<ts>.csv` — sampler output (bench modes).
* `bench-micro-<network>-<ts>.csv` — microbenchmark output.
* `<mode>-<network>-<ts>-debug.log` — florestad's own log, copied at
  bench end.
* `<mode>-<network>-<ts>-finished.txt` — why the bench stopped.

CSVs are written to `/data` and synced to the FAT every
`results_sync_every` samples and at every clean shutdown, so a yanked
cable costs at most a few rows.

### Sampler CSV schema (stable — plot with confidence)

One row per `sample_interval_secs`:

| column | meaning |
|--------|---------|
| `ts_utc` | ISO8601 UTC timestamp |
| `uptime_s` | seconds since boot |
| `height` | chain height via floresta-cli (`-1` = RPC unavailable) |
| `rss_kb` | florestad resident memory, kB (`-1` = not running) |
| `cpu_pct` | florestad CPU% over the last interval (100 = the whole core) |
| `temp_mc` | SoC temperature, millidegrees C (throttling shows here) |
| `load1` `load5` `load15` | load averages |
| `mem_avail_kb` | `MemAvailable` |
| `swap_total_kb` `swap_free_kb` | swap (zram) usage |
| `zram_orig_b` `zram_compr_b` | bytes in zram before/after compression |
| `sd_reads` `sd_read_sectors` `sd_writes` `sd_write_sectors` `sd_io_ms` | **cumulative** mmcblk0 counters (sectors = 512 B); post-process into deltas |

### bench-micro CSV schema

`name,iters,total_ns,ns_per_op,ops_per_sec,extra` — rows
`sha256_bulk_8k`, `sha256d_header`, `secp256k1_verify`,
`utreexo_verify_64of4096` (from `floresta-microbench`, fixed iteration counts so
runs are directly comparable), then `sd_write_1m_64m`,
`sd_read_1m_64m`, `sd_read_4k_16m` (from dd; `extra` carries MB/s).

---

## USB networking (the only cable)

The Pi's OTG port is a composite USB gadget: **ECM ethernet + ACM
serial**. The cable that powers the board is the network.

On the host, the Pi appears as a network interface (Linux: usually
`usb0` or `enx027069300001`; macOS: a new Ethernet device). Give the
host side the gateway address:

```bash
# Linux
sudo ip addr add 10.7.0.1/24 dev usb0
sudo ip link set usb0 up
```

* Serial console: `screen /dev/ttyACM0 115200` (login: root/floresta)
* SSH: `ssh root@10.7.0.2` (password `floresta` — this image is a lab
  instrument on a point-to-point cable, not an internet-facing box)

### Giving the Pi internet (required for IBD benches)

Two commands on a Linux host (`usb0` = the Pi link, `eth0` = your
uplink):

```bash
sudo sysctl -w net.ipv4.ip_forward=1
sudo nft add table nat \; \
    add chain nat postrouting '{ type nat hook postrouting priority srcnat; }' \; \
    add rule nat postrouting ip saddr 10.7.0.0/24 oifname "eth0" masquerade
```

macOS equivalent: enable Internet Sharing for the RNDIS/ECM interface
in System Settings, or `pfctl` NAT — and note macOS Internet Sharing
imposes its own subnet; easier to just set `usb_ip` accordingly.

The first thing the Pi does when the link comes up is **NTP** — the
board has no RTC, and block timestamp checks go insane at 1970. Until
NTP succeeds, the clock is restored from the last persisted timestamp
on `/data` (good enough to keep logs monotonic; not good enough to
validate a chain tip, which is why NTP precedes florestad in the boot
order).

Windows hosts: set `usb_gadget=rndis` in the config.

---

## Flashing

### Primary: through the Pi itself (`nix run .#flash-rasp-pi-zero`)

The BCM2835's boot ROM falls back to **USB device mode** when the SD
card holds nothing bootable. `flash-rasp-pi-zero` uses that: it runs
[`rpiboot`](https://github.com/raspberrypi/usbboot) to push a tiny
firmware that exposes the Pi's SD slot as USB mass storage, then
flashes it like a disk — except the disk is *detected*, not typed:

```bash
nix run .#flash-rasp-pi-zero        # Linux or macOS host, only Nix required
```

The script: ensures the image exists (building it if you are in the
repo on a Linux box), snapshots the disk list, starts rpiboot, waits
for exactly **one** new disk to appear (two new disks = abort, it
never guesses), checks the disk identifies as a Pi in USB boot mode
and has an SD-plausible size, makes you type the device name back,
unmounts, flashes with progress, **reads the image back and compares
hashes** (catches wrong-disk and truncated writes — including a cable
yanked mid-dd), and ejects.

Two hardware gotchas cause 90% of failures, both printed by the
script and worth repeating:

* **Use the middle micro-USB port** (labelled *USB*). The port at the
  board's edge (*PWR IN*) is power-only.
* **Use a data cable.** A large fraction of micro-USB cables are
  charge-only and electrically incapable of this. If nothing ever
  enumerates, suspect the cable first.

On macOS the *image build* still needs an x86_64-linux machine (or a
configured remote builder) — build there, then
`nix run .#flash-rasp-pi-zero -- path/to/floresta-rasp-pi-zero-sdcard.img` on the Mac.

### Updating florestad WITHOUT rebuilding the image

The image is the lab equipment; florestad is the specimen.  `/data/bin`
outranks the baked-in `/usr/bin` on the PATH of every init script and
login shell, so a new florestad build reaches the running Pi in
seconds:

```bash
nix build .#florestad-rasp-pi-zero -o result-florestad
cat result-florestad/bin/florestad | ssh root@10.7.0.2 'florestaos update-florestad'
# the Pi RUNS the incoming binary (--version) before installing it —
# truncated transfers and wrong-arch builds are rejected, with the md5
# printed for cross-checking.  Reboot (or restart services) to use it.
```

`florestaos use-baked` reverts to the image's own binary; a wiped
`/data` reverts automatically.  The boot log in `results/` always
records which version a run actually used.

### Re-flashing a working card (`florestaos reflash`)

USB boot mode only triggers when the ROM finds nothing bootable — a
successfully flashed card boots the lab instead. The image therefore
ships its own recovery button:

```bash
ssh root@10.7.0.2 florestaos reflash
```

It stops florestad, flushes pending results to the FAT, **erases the
first MiB of the card** (partition table + boot), and reboots. The
ROM then finds nothing and drops into USB boot mode; run
`nix run .#flash-rasp-pi-zero` on the host and it takes over from there.
Destructive **by design** — copy `results/` first
(`scp -r root@10.7.0.2:/boot/results .`).

### Fallback: card reader + generic flasher

If the OTG port or cable will not cooperate, the classic way still
works:

```bash
nix build .#image-rasp-pi-zero
nix run .#flash-rasp-pi-zero-reader -- /dev/sdX     # Linux
nix run .#flash-rasp-pi-zero-reader -- /dev/diskN   # macOS
```

The generic flasher ([`../flash.nix`](../flash.nix)) refuses whole classes
of foot-gun: partitions instead of whole disks, anything mounted,
non-removable or internal disks, absurd sizes — and still demands you
type the device name back. dd remains dd; read the prompt.

---

## An honest warning about SD cards

An IBD bench writes tens of gigabytes. **Consumer SD cards are
consumables and this lab consumes them**: expect cards to die, expect
performance to degrade as the card's controller juggles worn blocks
(you will *see* this in `sd_io_ms`). Use cards you can afford to lose,
buy A1/A2-class if you want comparable numbers, and never store the
only copy of results on the card that is being benchmarked — the FAT
mailbox is a transfer mechanism, not an archive.

Chain state on `/data` is treated as disposable by design: if the
f2fs partition fails to mount it is fsck'd, and if that fails it is
**reformatted** without asking.

---

## Development

```bash
nix develop .#rasp-pi-zero
```

drops you into a shell with the exact toolset the image build uses,
plus instructions to unpack the pinned Buildroot and drive it manually
(`make menuconfig`, incremental package rebuilds, `make source`).
The committed defconfig is `images/rasp-pi-zero/assets/buildroot/configs/floresta_rasp_pi_zero_defconfig`;
regenerate it from a modified `.config` with `make savedefconfig`.

Component outputs, buildable independently:

* `.#florestad-rasp-pi-zero` — static ARMv6 florestad + floresta-cli
* `.#microbench-rasp-pi-zero` — static ARMv6 microbenchmark binary (`floresta-microbench`)
* `.#buildroot-downloads-rasp-pi-zero` — the pinned download closure
* `.#payload-rasp-pi-zero` — the rootfs overlay both binaries land in
* `.#os-rasp-pi-zero` — the **image without Floresta**: 1502 derivations
  instead of 2554, and no ARMv6 cross-gcc at all.  Use it when the change
  you are testing is in `assets/buildroot/` (init scripts, kernel config,
  package set) rather than in the node.

Build order note: the first build compiles an armv6 musl cross-gcc
(nixpkgs `pkgsCross.muslpi`, ~40 min), the Buildroot internal
toolchain, and the kernel. Hours on a laptop. This subproject
optimizes for correctness and reproducibility, not build speed.

### Layout

```
images/rasp-pi-zero/
├── README.md            this file
├── default.nix          the board's gate: meta + wiring, no build logic
├── toolchain.nix        how to cross-compile for ARMv6 musl (target, cc, linker)
├── patches.nix          what to change in Floresta's source for it (pure data)
├── node.nix             THE NODE: static florestad + floresta-cli
├── payload.nix          the seam: node + microbench as a rootfs overlay
├── system.nix           THE OS: Buildroot downloads FOD + offline image build.
│                        Takes the payload — or none, for `.#os-rasp-pi-zero`
├── system-test.nix      `nix flake check` boot validation under QEMU
├── flash.nix            `nix run .#flash-rasp-pi-zero` (rpiboot auto-flasher)
└── assets/
    └── buildroot/       BR2_EXTERNAL tree (committed, versioned)
        ├── configs/floresta_rasp_pi_zero_defconfig
        └── board/
            ├── config.txt cmdline.txt        firmware config
            ├── linux.fragment                kernel: no modules, gadget/f2fs/zram/squashfs built in
            ├── busybox.fragment              + ntpd, timeout
            ├── genimage.cfg.in post-*.sh     image assembly
            ├── florestaos.conf               config template shipped on the FAT
            └── rootfs-overlay/               preinit, init scripts, sampler, bench-micro
```

One file per rebuild boundary: editing `patches.nix` rebuilds the node
and the image but not the microbenchmark or `.#os-rasp-pi-zero`. See
[`../README.md`](../README.md#the-node-is-not-the-image).

Shared with every other board, one level up: the generic flasher
(`../flash.nix`), the interactive QEMU runner (`../qemu-test.nix`), the
microbenchmark crate (`../bench/`) and the measurement harness
(`../harness/`).  See [`../README.md`](../README.md).

### Troubleshooting

* **Host sees no network interface** — check `dmesg` for a `cdc_ether`
  device; if nothing, the cable is power-only (very common!) or
  plugged into the Pi's `PWR` port instead of `USB`.
* **No results after a bench-micro boot** — read `boot-<ts>.log` on
  the FAT; a config typo falls back to `mode=node`, which writes no
  CSV.
* **Serial over USB dead but network up** — `ssh root@10.7.0.2`; the
  ACM console and getty logs are in `/var/log/messages` (tmpfs, lost
  at poweroff).
* **First boot seems to hang then reboots** — that is the documented
  partition-table reboot, not a crash.
