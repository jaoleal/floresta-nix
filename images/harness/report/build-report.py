#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Turn a run's CSVs into a report that answers questions.

Not a dump of numbers.  Each section below exists to answer one of the
questions the harness was built for, and where the data cannot answer
one, the section says so and says what would be needed -- an admitted
gap is a result; a plausible-looking estimate over missing
instrumentation is a lie with a decimal point.

Standard library only, deliberately: the analysis is a linear
regression and some averages, and a report that needs a scientific
Python stack to render is a report nobody regenerates.
"""

import csv
import json
import math
import statistics
import sys
from pathlib import Path

TIP_BUDGET_S = 600
MAINNET_FULL_BLOCK_TX = 3000

# Release-time assume-valid checkpoints, read from
# crates/floresta-chain/src/pruned_utreexo/chainparams.rs
# (get_assume_valid, floresta v0.9.x).  Blocks at or below these heights
# skip script execution during IBD; blocks above them verify every
# signature.  On the boards this harness targets those two regimes
# differ by an order of magnitude, so a ms/tx figure that does not say
# which side of the line it came from is not comparable to anything.
#
# These are constants of a Floresta release, not of the network: bump
# them when the pinned Floresta moves, or the report will mislabel runs.
ASSUME_VALID_HEIGHTS = {
    "bitcoin": 939969,
    "signet": 296870,
    "testnet": 4887983,
    "testnet4": 126514,
    "regtest": 0,
}

UNDERVOLTAGE_THRESHOLD_V = 4.75


# --- small statistics ------------------------------------------------


def _betacf(a, b, x):
    """Continued fraction for the incomplete beta function (Lentz)."""
    tiny = 1e-30
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c = 1.0
    d = 1.0 - qab * x / qap
    if abs(d) < tiny:
        d = tiny
    d = 1.0 / d
    h = d
    for m in range(1, 200):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        c = 1.0 + aa / c
        if abs(d) < tiny:
            d = tiny
        if abs(c) < tiny:
            c = tiny
        d = 1.0 / d
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        c = 1.0 + aa / c
        if abs(d) < tiny:
            d = tiny
        if abs(c) < tiny:
            c = tiny
        d = 1.0 / d
        delta = d * c
        h *= delta
        if abs(delta - 1.0) < 3e-16:
            break
    return h


def _betai(a, b, x):
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    lbeta = math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
    front = math.exp(lbeta + a * math.log(x) + b * math.log(1.0 - x))
    if x < (a + 1.0) / (a + b + 2.0):
        return front * _betacf(a, b, x) / a
    return 1.0 - front * _betacf(b, a, 1.0 - x) / b


def student_t_cdf(t, df):
    x = df / (df + t * t)
    p = 0.5 * _betai(df / 2.0, 0.5, x)
    return 1.0 - p if t > 0 else p


def student_t_critical(df, confidence=0.95):
    """Two-sided critical value, by bisection on the CDF.

    Bisection because the alternative is shipping a t-table or a
    dependency, and this is twenty lines that are correct for any df.
    """
    target = 1.0 - (1.0 - confidence) / 2.0
    lo, hi = 0.0, 1000.0
    for _ in range(200):
        mid = (lo + hi) / 2.0
        if student_t_cdf(mid, df) < target:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2.0


class Regression:
    """Ordinary least squares of y on x, with the honesty attached.

    The interesting numbers are the intercept (what a block costs before
    it contains anything) and the slope (what one more transaction
    costs).  The rest -- n, the range of x, R², the confidence interval
    -- exists so that nobody quotes the slope outside the range that
    produced it.
    """

    def __init__(self, xs, ys):
        self.n = len(xs)
        self.ok = self.n >= 3 and len(set(xs)) >= 2
        if not self.ok:
            return
        mx, my = statistics.fmean(xs), statistics.fmean(ys)
        sxx = sum((x - mx) ** 2 for x in xs)
        sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
        self.slope = sxy / sxx
        self.intercept = my - self.slope * mx
        residuals = [y - (self.intercept + self.slope * x) for x, y in zip(xs, ys)]
        ss_res = sum(r * r for r in residuals)
        ss_tot = sum((y - my) ** 2 for y in ys)
        self.r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan")
        self.x_min, self.x_max = min(xs), max(xs)
        self.y_median = statistics.median(ys)
        if self.n > 2:
            se = math.sqrt(ss_res / (self.n - 2) / sxx) if sxx > 0 else float("nan")
            self.slope_se = se
            crit = student_t_critical(self.n - 2)
            self.slope_lo = self.slope - crit * se
            self.slope_hi = self.slope + crit * se
            # The intercept's own interval, which matters as much: it is
            # the fixed per-block cost.
            se_i = se * math.sqrt(sum(x * x for x in xs) / self.n)
            self.intercept_lo = self.intercept - crit * se_i
            self.intercept_hi = self.intercept + crit * se_i
        else:
            self.slope_se = float("nan")
            self.slope_lo = self.slope_hi = float("nan")
            self.intercept_lo = self.intercept_hi = float("nan")

    def predict(self, x):
        return self.intercept + self.slope * x


# --- loading ---------------------------------------------------------


def read_csv(path):
    if not path.exists():
        return []
    with path.open(newline="") as fh:
        return list(csv.DictReader(fh))


def num(row, key, default=None):
    value = row.get(key, "")
    if value is None or value == "":
        return default
    try:
        return float(value)
    except ValueError:
        return default


class Run:
    def __init__(self, run_dir):
        self.dir = Path(run_dir)
        self.meta = json.loads((self.dir / "meta.json").read_text())
        self.blocks = read_csv(self.dir / "blocks.csv")
        self.proc = read_csv(self.dir / "proc.csv")
        self.power = read_csv(self.dir / "power.csv")
        self.windows = read_csv(self.dir / "windows.csv")

    def window(self, label):
        for row in self.windows:
            if row["label"] == label and row.get("end_ms"):
                return int(row["start_ms"]), int(row["end_ms"])
        return None

    def window_labels(self):
        return [w["label"] for w in self.windows]

    def rows_in(self, rows, span):
        if span is None:
            return rows
        lo, hi = span
        out = []
        for row in rows:
            t = num(row, "t_ms")
            if t is not None and lo <= t <= hi:
                out.append(row)
        return out


# --- sections --------------------------------------------------------


def fmt_ms(value):
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return "n/a"
    if abs(value) >= 1000:
        return f"{value / 1000:.2f} s"
    return f"{value:.0f} ms"


def section_header(run, out):
    meta = run.meta
    target = meta["target"]
    fd = meta["florestad"]
    out.append(f"# bench-node report — {meta['run_id']}\n")
    out.append(f"*Run kind:* **{meta.get('run_kind', 'bench')}**\n")

    out.append("| | |")
    out.append("|---|---|")
    out.append(f"| Target | {meta['target']['name']} — {target['uname']} |")
    out.append(f"| Host | `{target['host']}` |")
    out.append(f"| Network | {fd['network']} |")
    out.append(f"| florestad | {fd['version']} |")
    out.append(f"| Binary sha256 | `{fd['sha256'][:16]}…` |")
    out.append(f"| Command | `{fd['cmdline'].strip()}` |")
    out.append(f"| Datadir | `{fd['datadir']}` ({meta['run']['state_mode']}) |")
    out.append(
        f"| Harness | {meta['harness']['version']} @ {meta['harness']['commit']} "
        f"({meta['harness']['dirty']}) |"
    )
    out.append("")

    warnings = []

    if not meta["persistence"]["clean_shutdown"]:
        warnings.append(
            "**Shutdown was not clean.** Every conclusion about persistence in "
            "this run is invalid: the datadir's state cannot be distinguished "
            "from a database that was never flushed. Do not use this run to "
            "argue about flush behaviour."
        )
    restart = meta["persistence"].get("restart_check", "skipped")
    if restart == "regressed":
        warnings.append(
            f"**The restart check regressed**: after shutdown the node reloaded "
            f"at height {meta['persistence'].get('restart_height')}, below the "
            f"height reached during the run. Data that was reported as accepted "
            f"did not survive."
        )
    elif restart == "ok":
        warnings.append(
            f"Restart check passed: state reloaded at height "
            f"{meta['persistence'].get('restart_height')}."
        )

    if not meta["florestad"].get("metrics_feature", False):
        warnings.append(
            "**florestad was built without the `metrics` feature.** No "
            "Prometheus exporter existed during this run, so `metrics.jsonl` "
            "is empty: no peer-latency histogram, no block-height gauge, no "
            "`avg_block_processing_time`. Block events below come from the log."
        )

    # Millisecond timestamps are not the default; they come from -d,
    # which the harness always passes.  A run that lost them carries a
    # 1-second error into every derived per-block number.
    if " -d" not in meta["florestad"]["cmdline"]:
        warnings.append(
            "**Log timestamps have 1-second resolution** (florestad was not run "
            "with `-d`). Every `ms_total` below carries up to ±1000 ms of "
            "quantisation error, which dominates any block faster than a few "
            "seconds."
        )

    av = assume_valid_state(run)
    warnings.append(av["summary"])

    if meta.get("assembled", {}).get("drift_correction_applied"):
        warnings.append(
            f"The target clock drifted {meta['clock']['drift_ms']} ms against "
            "the host during the run; a linear correction was applied to all "
            "log-derived timestamps."
        )

    undervolt = undervoltage_state(run)
    if undervolt:
        warnings.append(undervolt)

    throttle = throttle_state(run)
    if throttle:
        warnings.append(throttle)

    collector = collector_cost(run)
    if collector is not None:
        note = (
            f"The target-side collector used **{collector:.2f}%** of one core "
            f"(sampling every {meta['run']['proc_interval_s']}s)."
        )
        if collector > 3.0:
            note += (
                " That is above the 3% budget: lower the sampling rate before "
                "treating fine-grained CPU numbers as undisturbed."
            )
        warnings.append(note)

    for w in meta.get("warnings", []):
        warnings.append(w)

    out.append("## Read this first\n")
    for w in warnings:
        out.append(f"- {w}")
    out.append("")


def assume_valid_state(run):
    """Which validation regime the measured blocks were actually in.

    Without this, ms/tx is not a number anyone can compare: below the
    checkpoint the node skips script execution entirely, above it every
    signature is verified, and on this class of CPU that is an order of
    magnitude.
    """
    meta = run.meta
    network = meta["florestad"]["network"]
    cmdline = meta["florestad"]["cmdline"]
    heights = [int(b["height"]) for b in run.blocks if b.get("height")]

    if "--assume-valid 0" in cmdline:
        return {
            "mode": "disabled",
            "summary": "`assume_valid` was **disabled** (`--assume-valid 0`): "
            "every script from genesis was verified. ms/tx here is "
            "full-verification cost.",
            "checkpoint": None,
            "fraction_above": 1.0,
        }

    checkpoint = ASSUME_VALID_HEIGHTS.get(network)
    if checkpoint is None or not heights:
        return {
            "mode": "unknown",
            "summary": f"`assume_valid` state for network {network} could not be "
            "determined; ms/tx below is not comparable across runs until it is.",
            "checkpoint": checkpoint,
            "fraction_above": None,
        }

    above = [h for h in heights if h > checkpoint]
    fraction = len(above) / len(heights)
    if fraction == 0:
        summary = (
            f"`assume_valid` was **active** for every measured block: all "
            f"{len(heights)} were at or below the {network} checkpoint "
            f"{checkpoint:,}, so **script verification was skipped**. The ms/tx "
            f"figure below is the cost of everything *except* signature "
            f"checking, and must not be compared with a run above the "
            f"checkpoint."
        )
    elif fraction == 1.0:
        summary = (
            f"`assume_valid` was **not in effect** for any measured block: all "
            f"{len(heights)} were above the {network} checkpoint {checkpoint:,}, "
            f"so **every signature was verified**. This is full-validation cost."
        )
    else:
        summary = (
            f"**Mixed validation regimes**: {fraction * 100:.0f}% of the "
            f"{len(heights)} measured blocks were above the {network} "
            f"checkpoint {checkpoint:,} (signatures verified) and the rest below "
            f"it (script verification skipped). The regression below mixes two "
            f"populations and its slope is not a single physical quantity — "
            f"re-run with a height range on one side of {checkpoint:,}."
        )
    return {
        "mode": "hardcoded",
        "summary": summary,
        "checkpoint": checkpoint,
        "fraction_above": fraction,
    }


def undervoltage_state(run):
    if not run.power:
        return None
    volts = [num(r, "volts") for r in run.power]
    volts = [v for v in volts if v is not None]
    if not volts:
        return None
    lowest = min(volts)
    if lowest < UNDERVOLTAGE_THRESHOLD_V:
        return (
            f"**Undervoltage suspected**: the supply dipped to {lowest:.2f} V, "
            f"below the {UNDERVOLTAGE_THRESHOLD_V} V threshold. Treat this run "
            f"as suspect — a board that browns out throttles, and every timing "
            f"here inherits that."
        )
    return f"Supply minimum {lowest:.2f} V (above the {UNDERVOLTAGE_THRESHOLD_V} V threshold)."


def throttle_state(run):
    """The firmware's own account of whether the board was held back."""
    flags = set()
    for row in run.proc:
        raw = row.get("throttled", "")
        if not raw:
            continue
        try:
            value = int(raw, 0)
        except ValueError:
            continue
        if value:
            flags.add(value)
    if not flags:
        return None
    worst = max(flags)
    bits = {
        0: "under-voltage now",
        1: "ARM frequency capped now",
        2: "currently throttled",
        3: "soft temperature limit now",
        16: "under-voltage has occurred",
        17: "ARM frequency capping has occurred",
        18: "throttling has occurred",
        19: "soft temperature limit has occurred",
    }
    active = [name for bit, name in bits.items() if worst & (1 << bit)]
    return (
        f"**The board reported throttling** (`get_throttled=0x{worst:x}`: "
        f"{', '.join(active)}). Timings from this run are of a throttled board, "
        f"not of the hardware at its rated speed."
    )


def collector_cost(run):
    """What the observer cost, as a percentage of one core."""
    rows = [r for r in run.proc if num(r, "collector_cpu_ms") is not None]
    if len(rows) < 2:
        return None
    first, last = rows[0], rows[-1]
    cpu_ms = num(last, "collector_cpu_ms", 0) - num(first, "collector_cpu_ms", 0)
    span_ms = num(last, "t_ms", 0) - num(first, "t_ms", 0)
    if span_ms <= 0:
        return None
    return 100.0 * cpu_ms / span_ms


def pick_analysis_window(run):
    """Where the per-block numbers come from.

    Prefer tip_sync: header sync downloads no blocks, and backfill
    validates historical blocks under different rules.  Mixing them
    produces a regression through two different processes.
    """
    for label in ("tip_sync", "run"):
        span = run.window(label)
        if span:
            return label, span
    return "whole run", None


def section_block_cost(run, out):
    out.append("## 1. What a block costs\n")
    label, span = pick_analysis_window(run)
    blocks = [b for b in run.rows_in(run.blocks, span) if b.get("ms_total")]

    if len(blocks) < 3:
        out.append(
            f"Only {len(blocks)} block events with a measurable interval were "
            f"recorded in the `{label}` window — too few to fit anything. A "
            f"longer run, or one that actually syncs blocks, is needed.\n"
        )
        return None

    xs = [float(b["tx_count"]) for b in blocks]
    ys = [float(b["ms_total"]) for b in blocks]
    fit = Regression(xs, ys)
    if not fit.ok:
        out.append("The block events carry no variation in `tx_count`; no fit.\n")
        return None

    out.append(
        f"Fitted over **{fit.n} blocks** in the `{label}` window, with "
        f"transaction counts from **{fit.x_min:.0f} to {fit.x_max:.0f}**.\n"
    )
    out.append("| | value | 95% CI |")
    out.append("|---|---|---|")
    out.append(
        f"| Fixed cost per block | **{fmt_ms(fit.intercept)}** | "
        f"{fmt_ms(fit.intercept_lo)} … {fmt_ms(fit.intercept_hi)} |"
    )
    out.append(
        f"| Marginal cost per transaction | **{fit.slope:.2f} ms/tx** | "
        f"{fit.slope_lo:.2f} … {fit.slope_hi:.2f} ms/tx |"
    )
    out.append(f"| R² | {fit.r2:.3f} | |")
    out.append(f"| Median block interval | {fmt_ms(fit.y_median)} | |")
    out.append("")

    if fit.r2 < 0.3:
        out.append(
            f"**R² is {fit.r2:.2f}**: transaction count explains very little of "
            f"the variation in block-to-block time here. The dominant term is "
            f"something else — network arrival, batching, or IO — and the slope "
            f"above should not be read as 'the cost of a transaction' until "
            f"§2's decomposition exists.\n"
        )

    out.append(
        f"`ms_total` is the interval between consecutive accepted tips, so it "
        f"contains download, queueing and validation together. During a batched "
        f"sync several blocks can be validated back to back from a full queue, "
        f"which compresses intervals; the intercept above is therefore a "
        f"*lower* bound on the true fixed cost per block.\n"
    )
    out.append(
        f"Extrapolation warning: this fit saw blocks of {fit.x_min:.0f}–"
        f"{fit.x_max:.0f} transactions. Nothing here justifies a claim about a "
        f"block of {MAINNET_FULL_BLOCK_TX} transactions beyond the projection "
        f"in §5, which is labelled as an extrapolation for that reason.\n"
    )
    return fit


def section_decomposition(run, out):
    """The download/validate split -- and why it is not here.

    This is the section the brief cares most about and the one the data
    cannot fill.  Saying so precisely, with the specific instrumentation
    that would fix it, is worth more than a plausible split invented
    from arrival times.
    """
    out.append("## 2. Download versus validation\n")
    out.append(
        "**Not instrumented. This report cannot answer the question, and does "
        "not estimate it.**\n"
    )
    out.append(
        "florestad emits one event per accepted block (`New tip! hash= height= "
        "tx_count=`) and nothing about how that block's time was spent. The "
        "harness therefore records `ms_total` — tip to tip — and leaves "
        "`ms_download` and `ms_validate` empty in `blocks.csv` rather than "
        "splitting a number it did not measure.\n"
    )
    if run.meta["florestad"].get("metrics_feature"):
        out.append(
            "The `metrics` exporter's `avg_block_processing_time` is *close* to "
            "the validation half, but it is an exponential moving average with a "
            "1000-sample half-life (`Ema::with_half_life_1000`), not a per-block "
            "figure: it cannot be regressed against transaction count, and it "
            "lags a change in block size by hundreds of blocks.\n"
        )
    out.append(
        "**The minimal fix upstream**, in decreasing order of value:\n\n"
        "1. `floresta-wire`'s `process_pending_blocks` already measures exactly "
        "the right quantity — `let start = Instant::now(); self.process_block(…); "
        "let elapsed = start.elapsed()` — and then throws it into an EMA. "
        "Emitting `elapsed` per block (a log field on the tip line, or a "
        "histogram keyed by block) would give `ms_validate` at zero measurement "
        "cost.\n"
        "2. The same module already stamps every block request into `inflight` "
        "with an `Instant`. The difference between that stamp and the block's "
        "arrival is `ms_download`; it is already in memory and merely discarded.\n"
        "3. Adding `block_bytes`, `block_weight` and the utreexo proof size to "
        "the tip line would let the regression separate bytes from transactions, "
        "which is what distinguishes an IO-bound board from a CPU-bound one.\n"
    )


def section_energy(run, out):
    out.append("## 3. Energy\n")
    if not run.power:
        out.append(
            "No power meter was attached (`--power-meter none`), so this run has "
            "no energy data. Nothing here is estimated from CPU time: without an "
            "inline measurement, joules are a guess.\n"
        )
        return
    section_energy_body(run, out)


def mean_watts(rows):
    values = [num(r, "watts") for r in rows]
    values = [v for v in values if v is not None]
    return statistics.fmean(values) if values else None


def section_energy_body(run, out):
    pre = run.window("baseline_pre")
    post = run.window("baseline_post")
    run_span = run.window("run")

    idle_rows = run.rows_in(run.power, pre) + run.rows_in(run.power, post)
    load_rows = run.rows_in(run.power, run_span)

    idle_w = mean_watts(idle_rows)
    load_w = mean_watts(load_rows)
    peak_w = max((num(r, "watts", 0) for r in load_rows), default=None)

    if idle_w is None or load_w is None:
        out.append("The power series does not overlap the run windows; no energy figures.\n")
        return

    delta_w = load_w - idle_w
    if load_rows:
        span_s = (num(load_rows[-1], "t_ms", 0) - num(load_rows[0], "t_ms", 0)) / 1000.0
    else:
        span_s = 0.0
    total_j = load_w * span_s
    delta_j = delta_w * span_s

    blocks = run.rows_in(run.blocks, run_span)
    txs = sum(int(b["tx_count"]) for b in blocks if b.get("tx_count"))

    out.append("| | |")
    out.append("|---|---|")
    out.append(f"| Idle (florestad stopped, {len(idle_rows)} samples) | **{idle_w:.3f} W** |")
    out.append(f"| Under load ({len(load_rows)} samples) | **{load_w:.3f} W** |")
    out.append(f"| Attributable to florestad | **{delta_w:.3f} W** |")
    out.append(f"| Peak | {peak_w:.3f} W |" if peak_w else "| Peak | n/a |")
    out.append(f"| Total energy over the run | {total_j / 1000:.1f} kJ ({total_j / 3600:.2f} Wh) |")
    if blocks:
        out.append(f"| Energy per block (over idle) | **{delta_j / len(blocks):.2f} J** |")
    if txs:
        out.append(f"| Energy per transaction (over idle) | **{delta_j / txs * 1000:.2f} mJ** |")
    out.append("")
    out.append(
        f"Per-block and per-transaction energy are deltas over the idle "
        f"baseline: the board burns {idle_w:.3f} W doing nothing at all, and "
        f"charging that to Bitcoin validation would make a slower board look "
        f"more efficient the longer it took.\n"
    )


def section_bottleneck(run, out):
    out.append("## 4. Where the time goes\n")
    span = run.window("run")
    rows = run.rows_in(run.proc, span)
    if len(rows) < 5:
        out.append("Too few resource samples to attribute anything.\n")
        return

    totals = {
        key: sum(num(r, key, 0) for r in rows)
        for key in (
            "cpu_user_ms",
            "cpu_nice_ms",
            "cpu_sys_ms",
            "cpu_idle_ms",
            "cpu_iowait_ms",
            "cpu_irq_ms",
            "cpu_softirq_ms",
        )
    }
    total = sum(totals.values())
    if total <= 0:
        out.append("The CPU counters did not advance; nothing to attribute.\n")
        return

    out.append("Share of wall-clock CPU time on the target during the run:\n")
    out.append("| state | share | reading |")
    out.append("|---|---|---|")
    readings = {
        "cpu_user_ms": "userspace — validation, hashing, signature checks",
        "cpu_sys_ms": "kernel — syscalls, filesystem, network stack",
        "cpu_iowait_ms": "blocked on storage — the SD card is the limit",
        "cpu_softirq_ms": "soft interrupts — mostly network packet handling",
        "cpu_irq_ms": "hard interrupts",
        "cpu_nice_ms": "niced userspace",
        "cpu_idle_ms": "idle — waiting for peers, not for itself",
    }
    for key, share in sorted(totals.items(), key=lambda kv: -kv[1]):
        out.append(f"| {key[4:-3]} | {100.0 * share / total:.1f}% | {readings[key]} |")
    out.append("")

    busy = {k: v for k, v in totals.items() if k != "cpu_idle_ms"}
    dominant = max(busy.items(), key=lambda kv: kv[1])
    idle_share = 100.0 * totals["cpu_idle_ms"] / total
    busy_share = 100.0 - idle_share

    verdict = {
        "cpu_user_ms": "**CPU-bound in userspace**: the board spends its time "
        "computing, which is where a faster core or cheaper validation would pay.",
        "cpu_sys_ms": "**Kernel-bound**: syscall and filesystem overhead dominate "
        "userspace work — look at IO patterns and buffer sizes before optimising "
        "validation.",
        "cpu_iowait_ms": "**IO-bound on the SD card**: the CPU is waiting for "
        "storage. A faster card, or fewer/larger writes, buys more than a faster core.",
        "cpu_softirq_ms": "**Network-bound in softirq**: packet handling dominates; "
        "this is the shape of a link that is delivering faster than the node can "
        "consume, or a chatty peer set.",
        "cpu_irq_ms": "**Interrupt-bound**, which is unusual and worth investigating "
        "directly.",
        "cpu_nice_ms": "**Dominated by niced work** — something other than florestad "
        "is using this board.",
    }[dominant[0]]

    # An idle board has no bottleneck worth naming.  Saying "CPU-bound"
    # about 3% of one core would be true of the busy fraction and
    # completely misleading about the run.
    if idle_share > 50:
        out.append(
            f"The board was **idle {idle_share:.1f}%** of the run, so it was not "
            f"the limiting factor here: it spent the run waiting for something "
            f"else — peers, most likely — rather than running out of any "
            f"resource of its own. Per-block timings from a run like this "
            f"measure arrival, not capability.\n"
        )
        out.append(
            f"Within the {busy_share:.1f}% it was busy, the largest share is "
            f"`{dominant[0][4:-3]}`, but that is a statement about a small "
            f"amount of work and should not be quoted as this board's "
            f"bottleneck.\n"
        )
    else:
        out.append(
            f"The board was busy {busy_share:.1f}% of the run and idle "
            f"{idle_share:.1f}%. Of the busy time, the largest share is "
            f"`{dominant[0][4:-3]}`.\n\n{verdict}\n"
        )

    faults = sum(num(r, "proc_majflt", 0) for r in rows)
    swap = [num(r, "swap_free_kb") for r in rows if num(r, "swap_free_kb") is not None]
    rss = [num(r, "proc_rss_kb") for r in rows if num(r, "proc_rss_kb")]
    avail = [num(r, "mem_available_kb") for r in rows if num(r, "mem_available_kb")]
    if rss and avail:
        out.append(
            f"Memory: florestad's RSS peaked at **{max(rss) / 1024:.0f} MiB**, "
            f"with MemAvailable bottoming out at {min(avail) / 1024:.0f} MiB. "
            f"Major faults during the run: {faults:.0f}"
            + (
                f"; swap free fell by {(swap[0] - min(swap)) / 1024:.0f} MiB.\n"
                if len(swap) > 1 and swap[0] > min(swap)
                else ".\n"
            )
        )
    if faults > len(rows):
        out.append(
            "Major fault rate is high enough to mean real memory pressure: the "
            "board is paging, and that cost is showing up as iowait above.\n"
        )

    temps = [num(r, "temp_millicelsius") for r in rows if num(r, "temp_millicelsius")]
    if temps:
        out.append(
            f"SoC temperature ranged {min(temps) / 1000:.1f}–{max(temps) / 1000:.1f} °C.\n"
        )

    net_rx = sum(num(r, "net_rx_bytes", 0) for r in rows)
    disk_w = sum(num(r, "disk_write_bytes", 0) for r in rows)
    if span:
        span_s = (span[1] - span[0]) / 1000.0
        if span_s > 0:
            out.append(
                f"Throughput: {net_rx / 1e6:.1f} MB received "
                f"({net_rx / span_s / 1024:.0f} KiB/s average) and "
                f"{disk_w / 1e6:.1f} MB written to the datadir device.\n"
            )


def section_tip_margin(run, fit, out):
    out.append("## 5. Can this board keep up with the tip?\n")
    if fit is None:
        out.append("No usable per-block fit, so no margin can be stated.\n")
        return

    blocks = [b for b in run.blocks if b.get("ms_total")]
    median_tx = statistics.median([float(b["tx_count"]) for b in blocks])
    typical_s = fit.predict(median_tx) / 1000.0
    full_s = fit.predict(MAINNET_FULL_BLOCK_TX) / 1000.0

    out.append("| block | predicted time | share of the 10-minute budget |")
    out.append("|---|---|---|")
    out.append(
        f"| typical for this run ({median_tx:.0f} tx) | {typical_s:.1f} s | "
        f"{100 * typical_s / TIP_BUDGET_S:.1f}% |"
    )
    out.append(
        f"| full mainnet block ({MAINNET_FULL_BLOCK_TX} tx) | {full_s:.0f} s | "
        f"{100 * full_s / TIP_BUDGET_S:.1f}% |"
    )
    out.append("")

    if full_s < TIP_BUDGET_S:
        margin = TIP_BUDGET_S / full_s if full_s > 0 else float("inf")
        out.append(
            f"At this rate the board would process a full mainnet block with "
            f"**{margin:.1f}× headroom** against the 10-minute inter-block "
            f"budget.\n"
        )
    else:
        out.append(
            f"A full mainnet block would take **{full_s / TIP_BUDGET_S:.1f}× "
            f"the inter-block budget**: this board could not hold the tip on "
            f"mainnet at that block size.\n"
        )

    av = assume_valid_state(run)
    out.append(
        f"Both rows extrapolate a line fitted to blocks of {fit.x_min:.0f}–"
        f"{fit.x_max:.0f} transactions out to {MAINNET_FULL_BLOCK_TX}. That is a "
        f"{MAINNET_FULL_BLOCK_TX / max(fit.x_max, 1):.0f}× extrapolation and it "
        f"assumes cost stays linear in transaction count, which memory pressure "
        f"and accumulator growth can break. Treat it as an order of magnitude, "
        f"not a measurement."
    )
    if av["fraction_above"] is not None and av["fraction_above"] < 1.0:
        out.append(
            f" It also inherits the validation regime of the measured blocks — "
            f"see the assume_valid note above — while a mainnet tip is always "
            f"fully verified."
        )
    out.append("")


def section_metrics(run, out):
    path = run.dir / "metrics.jsonl"
    if not path.exists() or path.stat().st_size == 0:
        return
    total = ok = 0
    latencies = []
    for line in path.read_text().splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        total += 1
        if row.get("ok"):
            ok += 1
            latencies.append(row.get("latency_ms", 0))
    if not total:
        return
    out.append("## 6. Exporter health\n")
    text = f"{ok} of {total} scrapes succeeded."
    if latencies:
        latencies.sort()
        p50 = latencies[len(latencies) // 2]
        p95 = latencies[min(len(latencies) - 1, int(len(latencies) * 0.95))]
        text += (
            f" Scrape latency: median {p50} ms, p95 {p95} ms, max "
            f"{max(latencies)} ms."
        )
        if max(latencies) > 5 * max(p50, 1):
            text += (
                " The tail is far above the median, which means the exporter was "
                "competing with validation for the CPU — the same contention the "
                "block timings are measuring."
            )
    out.append(text)
    out.append(
        "\nRaw exposition is stored verbatim in `metrics.jsonl`, one JSON object "
        "per scrape, histogram buckets intact.\n"
    )


def section_appendix(run, out):
    meta = run.meta
    out.append("## Appendix: reproducing this run\n")
    out.append("```sh")
    args = [
        "nix run .#bench-node --",
        f"  --target {meta['target']['name']}",
        f"  --host {meta['target']['host']}",
        f"  --datadir {meta['florestad']['datadir']}",
        f"  --network {meta['florestad']['network']}",
        f"  --power-meter {meta['run']['power_meter']}",
        f"  --scrape-interval {meta['run']['scrape_interval_s']}s",
        f"  --baseline {meta['run']['baseline_secs']}",
        f"  --{meta['run']['state_mode']}",
    ]
    if meta["run"]["profile_mode"] != "off":
        args.append(f"  --profile {meta['run']['profile_mode']}")
    if meta["florestad"]["backfill"] != "default":
        args.append(f"  --backfill {meta['florestad']['backfill']}")
    for peer in meta["run"].get("peers", []):
        args.append(f"  --connect {peer}")
    out.append(" \\\n".join(args))
    out.append("```\n")
    out.append("On the target this ran:\n")
    out.append("```sh")
    out.append(meta["florestad"]["cmdline"].strip())
    out.append("```\n")
    out.append(
        f"The binary under test was `{meta['florestad']['path']}`, sha256 "
        f"`{meta['florestad']['sha256']}`"
        + (
            f", build-id `{meta['florestad']['build_id']}`.\n"
            if meta["florestad"].get("build_id")
            else " (no build-id: the binary is stripped).\n"
        )
    )
    counts = meta.get("assembled", {}).get("counts", {})
    out.append(
        f"Artifacts: {counts.get('proc_rows', 0)} resource samples, "
        f"{counts.get('block_events', 0)} block events, "
        f"{counts.get('power_samples', 0)} power samples, "
        f"{counts.get('metric_scrapes', 0)} metric scrapes, "
        f"{counts.get('windows', 0)} labelled windows. Checksums are in "
        f"`manifest.json`; `bench-node export` converts the CSVs to sqlite or "
        f"parquet, and `bench-node serve-prom` replays `metrics.jsonl` into a "
        f"local Prometheus.\n"
    )
    rig = meta.get("bench_rig", {})
    if any(rig.values()):
        out.append("Bench rig: " + ", ".join(f"{k}={v}" for k, v in rig.items() if v) + ".\n")
    else:
        out.append(
            "Bench rig not recorded. Set `BENCH_SD_CARD`, `BENCH_PSU`, "
            "`BENCH_CABLE` and `BENCH_AMBIENT_C` before the run: an SD card "
            "model explains more variance between two otherwise identical runs "
            "than most code changes do.\n"
        )


def section_windows(run, out):
    if not run.windows:
        return
    out.append("## Windows\n")
    out.append("| label | start (ms) | duration | source |")
    out.append("|---|---|---|---|")
    for w in run.windows:
        if w.get("end_ms"):
            duration = f"{(int(w['end_ms']) - int(w['start_ms'])) / 1000:.1f} s"
        else:
            duration = "(never closed)"
        out.append(f"| {w['label']} | {w['start_ms']} | {duration} | {w['source']} |")
    out.append("")
    out.append(
        "Every series in this run shares these timestamps, so any of them can "
        "be sliced by window — which is the only way a flamegraph of "
        "`backfill` says anything different from a flamegraph of `tip_sync`.\n"
    )


def main():
    if len(sys.argv) != 2:
        print("usage: build-report.py <run-dir>", file=sys.stderr)
        raise SystemExit(1)
    run = Run(sys.argv[1])
    out = []

    section_header(run, out)
    fit = section_block_cost(run, out)
    section_decomposition(run, out)
    section_energy(run, out)
    section_bottleneck(run, out)
    section_tip_margin(run, fit, out)
    section_metrics(run, out)
    section_windows(run, out)
    section_appendix(run, out)

    (run.dir / "report.md").write_text("\n".join(out) + "\n")
    print(f"report: {run.dir / 'report.md'}", file=sys.stderr)


if __name__ == "__main__":
    main()
