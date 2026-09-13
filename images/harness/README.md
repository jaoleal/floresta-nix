# bench-node

Measures what a Bitcoin node costs on a small board: time per block, time
per transaction, energy per block, and which resource actually runs out
first.

```sh
nix run .#bench-node -- --target rasp-pi-zero --network signet --duration 45m
nix run .#run-rasp-pi-zero-signet -- --duration 45m          # same thing, shorter
```

The harness runs entirely on the lab host. The target contributes two
processes: `florestad`, and one POSIX `sh` loop reading `/proc`. Nothing
is installed on the board, and nothing assumes `bash`, `python`, `jq`,
`curl` or `systemd` are there — the profile in `targets/` declares what
the board has, and preflight verifies it.

---

## Discovery: what is actually on the board

Everything below was measured on the lab's Pi Zero on 2026-09-02, not
assumed. Where it contradicts the design brief, the brief is wrong about
this board and the harness follows the measurement.

### The metrics exporter

`metrics` is a workspace feature (`florestad/metrics` →
`floresta-node/metrics` → `floresta-{chain,wire}/metrics`). There is **no
runtime flag**: with the feature the exporter starts, without it the code
does not exist.

| | |
|---|---|
| Address | `0.0.0.0:3333`, **hardcoded** in `crates/floresta-node/src/florestad.rs` |
| Path | **`/`**, not `/metrics` (`Router::new().route("/", …)`) |
| Configurable | No — neither by flag nor by config file |

The five series it exposes, with their literal names:

| name | type | notes |
|---|---|---|
| `block_height` | gauge | set in `chain_state.rs` next to the "New tip!" log line |
| `peer_count` | gauge | |
| `avg_block_processing_time` | gauge, seconds | **an EMA, `Ema::with_half_life_1000`** — not a per-block figure |
| `memory_usage_gigabytes` | gauge | **system-wide** used memory, not florestad's |
| `message_times` | histogram | peer response latency; buckets 0.1, 0.5, 1, 2, 5, 10, 30 s |

Two consequences worth stating plainly:

* `avg_block_processing_time` cannot be regressed against transaction
  count. It lags a change in block size by hundreds of blocks, and a
  half-life of 1000 samples on a board doing a few blocks per second
  means it describes the last several minutes, not the last block.
* `memory_usage_gigabytes` measures the board, not the node. On a
  456 MB board it also reads in gigabytes, so it is three significant
  figures of nothing. `proc.csv` carries florestad's real RSS.

**The binary on the lab board was built without the feature** (verified:
nothing listens on 3333, and the marker string `Started metrics server
on` is absent from the binary). Preflight refuses to run in that state;
`--allow-no-metrics` downgrades it to a warning that then appears at the
top of the report.

### Log timestamps: milliseconds are available

The brief expected to have to file an upstream issue for this. Not
needed:

* `bin/florestad/src/logger.rs` picks the timestamp format from
  `is_debug = log_level >= Level::DEBUG` — i.e. from `-d`.
* The *filter* is separate: `EnvFilter::try_from_default_env()` prefers
  `RUST_LOG` and only falls back to the level implied by `-d`.

So `RUST_LOG=info florestad -d` gives **INFO-level events with
millisecond timestamps**, which is exactly what is wanted and is what the
harness always runs. Verified on the board:

```
2026-09-02 15:00:53.958  INFO node: RPC server is running at 127.0.0.1:19332
```

Timestamps are formatted with `ChronoLocal` — the target's *local* time.
The harness records the target's UTC offset at preflight and converts.

### What the board has, and does not

| | |
|---|---|
| present | `wget` (busybox), `awk`, `sed`, `grep`, `cut`, `od`, `dd`, `pidof`, `nice`, `md5sum`, `sha256sum`, `timeout`, fractional `sleep`, `floresta-cli` |
| **absent** | `nc`, `curl`, `vcgencmd`, `perf`, `python3`, `bash`, `jq`, `stat`, `getconf` |
| `/proc/pressure` | **absent** — `CONFIG_PSI` is off in this kernel |
| thermal | `/sys/class/thermal/thermal_zone0/temp` works (36.3 °C idle) |
| throttling | **`/sys/devices/platform/soc/soc:firmware/get_throttled`** — the same word `vcgencmd get_throttled` reads, without needing the Pi userland |
| CPU | 1 core, ARMv6, 698 BogoMIPS |
| RAM | 456 MB, plus 256 MB zram |
| datadir device | `mmcblk0p3` (f2fs) |
| interface | `usb0` (the gadget link to the host) |

Three of these shaped the design:

* **No `perf`.** `targets/rasp-pi-zero.nix` declares `profiler = "none"`, and
  `--profile perf` fails preflight with that reason rather than
  producing an empty flamegraph. The perf path is implemented but has
  **never been exercised on hardware** — this lab has no perf-capable
  board yet.
* **No sub-second `date`.** busybox `date +%s%3N` prints whole seconds
  with a literal `3N` stripped. But `/proc/uptime` is centisecond
  resolution, so target samples are stamped from uptime and anchored to
  the host clock once per run. Uptime also cannot jump, which matters on
  a board with no RTC.
* **No `getconf`.** `USER_HZ` is assumed to be 100 and recorded in
  `meta.json` as `target.clk_tck`, so a wrong assumption is auditable
  rather than invisible.

### What `blocks.csv` cannot contain

florestad emits exactly one event per accepted block:

```
2026-09-01 17:21:01  INFO chain: New tip! hash=00000005…62e height=296973 tx_count=67
```

That is the whole per-block dataset. `getblock` over RPC returns
`Block not found` — a pruned utreexo node does not keep blocks — so
there is no second source for size or weight.

Empty in `blocks.csv`, and **not estimated**: `block_bytes`,
`block_weight`, `inputs`, `outputs`, `proof_bytes`, `proof_hashes`,
`utxos_added`, `utxos_removed`, `ms_download`, `ms_validate`.

`ms_total` (tip to tip) is always computed. The report says all of this
in §2 and proposes the minimal upstream instrumentation: the validation
time is *already measured* in `process_pending_blocks` and thrown into
an EMA, and the download start time is *already stored* in the
`inflight` map. Both are two lines from being usable.

### The collector's own cost

An acceptance criterion, so it was measured rather than asserted. First
version scanned `/proc/diskstats` (≈50 lines) and `/proc/net/dev` (≈45
interfaces on this kernel) in shell: **130 ms of CPU per tick, ~10% of
the core.** Switching those two to single-line sysfs files
(`/sys/class/block/<dev>/stat`, `/sys/class/net/<if>/statistics/*`)
brought it to **~30 ms per tick**:

| sampling interval | collector cost |
|---|---|
| 1 s | ~2.9% of one core |
| **2 s (rasp-pi-zero default)** | **~1.5% of one core** |

`targets/rasp-pi-zero.nix` therefore sets `procInterval = 2`. The report states
the measured figure for every run, from the collector's own
`collector_cpu_ms` column, and flags it if it exceeds 3%.

---

## What the harness produces

```
runs/<timestamp>-<commit>/
  meta.json        run identity: everything needed to compare two runs
  manifest.json    schema version, windows, artifact checksums
  blocks.csv       one row per accepted block
  proc.csv         target resources, one row per interval
  power.csv        volts/amps/watts plus integrated mAh/mWh
  metrics.jsonl    one raw Prometheus exposition per scrape
  windows.csv      labelled intervals on the shared clock
  florestad.log    the node's own log, millisecond stamps
  harness.log      what the harness did, phase by phase
  report.md        the answers
  proc.raw         the target's stream before timestamp conversion
  power.raw        the meter's stream before integration
  windows.raw      phase boundaries as the run recorded them
```

Raw streams are kept alongside the assembled CSVs on purpose: a parser
bug found next month can be fixed and the CSVs regenerated
(`assemble.py <run-dir>` is idempotent); a parser bug that ate the data
during collection cannot be undone.

**Column names are a contract.** Breaking one bumps `schema_version` in
both `meta.json` and `manifest.json`.

The four CSVs are always written, header included, even when the run
measured nothing of that kind — a `power.csv` with zero rows says "no
meter was attached" unambiguously, where a missing file could equally
mean the harness died before writing it. Raw captures follow the
opposite rule: they are absent when nothing produced them, so
`metrics.jsonl` simply does not exist for a run against a florestad
built without the exporter.

### Time base

Everything is epoch milliseconds on the *host's* clock, in `t_ms`.

* Target samples: `t_ms = boot_epoch_ms + uptime_cs × 10`, where the
  anchor is measured at preflight against the host clock.
* Log events: parsed in the target's local timezone, then corrected by
  the measured clock offset.
* Preflight **aborts** (exit 2) when the target's wall clock differs
  from the host's by more than 2 s.
* The offset is measured again at the end of the run. If it moved more
  than 1 s the report applies a linear correction and says so.

The offset itself is only accurate to ±1000 ms, because busybox `date`
truncates to the second; `meta.json` records that as
`clock.offset_resolution_ms`.

## Reuse outside the harness

```sh
bench-node export --format sqlite runs/2026…/    # + parsed metrics table
bench-node export --format parquet runs/2026…/   # needs pyarrow (Linux hosts)
bench-node serve-prom runs/2026…/                # replay into Prometheus
```

`serve-prom` maps wall-clock time since it started onto run time, so a
local Prometheus scraping `127.0.0.1:9099/metrics` records the run as if
it were live — visual exploration after the fact, costing the board
nothing while it is busy. Histograms keep their original buckets, so a
latency heatmap is still possible; a quantile computed at collection
time would not have been.

## Adding a board

Add one file to `targets/`. That is the whole procedure, and it is the
test of the design: `generic-aarch64.nix` was written without changing a
line anywhere else. A profile declares the host, the architecture, the
datadir, the tools it expects, which sensors exist, whether the kernel
has PSI, whether `perf` is available, and the sampling interval. Fields
left `null` (block device, network interface) are autodetected at
preflight.

If you find yourself adding a board-specific branch to `run.sh`, the
schema is missing a field — add the field.

## Phases and exit codes

`preflight → baseline → run → teardown → collect → report`, each logged,
each failing explicitly.

| code | meaning |
|---|---|
| 0 | ok |
| 1 | usage error |
| 2 | preflight failed |
| 3 | target unreachable |
| 4 | florestad failed during the run |
| 5 | teardown was not clean |

`Ctrl-C` stops florestad on the target and runs the full teardown; the
board is never left with an orphaned node eating its only core. If the
SSH link itself dies, the target-side watchdog notices the collector's
heartbeat going stale and stops florestad with SIGINT after 180 s.

`--dry-run` prints exactly what would happen and touches the target only
with `ssh true`.

## Known gaps

* **Power drivers are untested on hardware.** The lab has no inline USB
  meter yet. `um25c.sh` implements the published request/response
  protocol and refuses to guess scaling factors for an unrecognised
  model word; `ina226.sh` reads ASCII lines from a support MCU. Both
  follow the same three-line contract, so a third meter is a new file.
* **`--profile perf` is untested on hardware**, for the same reason: no
  board in this lab has `perf`. It fails closed at preflight rather than
  producing an empty profile.
* **No switchable USB hub**, so no cold-boot energy measurement and no
  power-cycling between runs. `targets/*.nix` has a `hub` field waiting
  for one.
* **SSH key auth must already work.** The rasp-pi-zero image authenticates root
  by password and mounts `/root` read-only from squashfs, so there is
  nowhere for `authorized_keys` to live. Until the image provides one,
  install a key by hand before running the harness.
