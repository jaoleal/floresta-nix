#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# The only thing this harness runs continuously on the target.
#
# It samples /proc and /sys once per interval and writes one CSV row to
# stdout, which the host reads off the SSH channel.  Everything else --
# parsing, correlating, plotting -- happens on the host, because on a
# single-core board the collector competes with the very thing it is
# measuring.
#
# Two rules follow from that, and both shape the code below:
#
#   1. No forks in the sample loop.  Every read is a shell redirection
#      into a builtin `read`; there is no awk, no grep, no cat.  The
#      only process this script creates per tick is `sleep`, because
#      busybox ash has no builtin for it.
#
#   2. The collector measures itself.  The last two columns are its own
#      accumulated CPU time, so the report can state the observer's cost
#      instead of assuming it away.  That is an acceptance criterion,
#      not a nicety.
#
# Counters are emitted as deltas over the interval; gauges are emitted
# raw.  Timestamps are centiseconds of uptime: busybox `date` cannot
# print sub-second time, but /proc/uptime is centisecond-resolution, and
# the host anchors uptime to its own clock once per run.
#
# The heartbeat is the other half of the orphan story: this script
# writes its uptime to that file every tick, and the target-side
# watchdog reads it.  If the SSH channel dies, this script dies with it,
# the heartbeat goes stale, and the watchdog stops florestad -- so a
# dropped connection can never leave a node eating the only core.
#
# Usage: collect-proc.sh <interval_s> <pidfile> <disk> <iface> <thermal> <throttled> <psi:0|1> [heartbeat]

set -u

INTERVAL="${1:-1}"
PIDFILE="${2:-}"
DISK="${3:-}"
IFACE="${4:-}"

# Resolved once, so the sample loop only ever opens a known path.
DISK_STAT=""
[ -n "$DISK" ] && [ -r "/sys/class/block/$DISK/stat" ] && DISK_STAT="/sys/class/block/$DISK/stat"
NET_RX="" NET_TX=""
if [ -n "$IFACE" ] && [ -r "/sys/class/net/$IFACE/statistics/rx_bytes" ]; then
	NET_RX="/sys/class/net/$IFACE/statistics/rx_bytes"
	NET_TX="/sys/class/net/$IFACE/statistics/tx_bytes"
fi
THERMAL="${5:-}"
THROTTLED="${6:-}"
PSI="${7:-0}"
HEARTBEAT="${8:-}"

# Jiffies to milliseconds.  No getconf on busybox; USER_HZ is 100 on
# every kernel this harness targets, and the value is recorded in
# meta.json so a wrong assumption stays auditable.
J2MS=10

pid=0
prev_ok=0

# --- readers ---------------------------------------------------------
#
# Each sets a fixed group of variables.  They are deliberately flat and
# repetitive: a helper that took a field name would cost a fork or a
# case statement per field, which is exactly what we are avoiding.

read_uptime() {
	up_cs=0
	if read -r _u _ </proc/uptime 2>/dev/null; then
		# "79097.35" -> 7909735, by concatenation rather than
		# arithmetic.  $((_i * 100 + _f)) looks equivalent and is not:
		# /proc/uptime writes the centiseconds zero-padded, and the
		# shell reads a leading zero as octal, so ".09" aborts the
		# expression ("value too great for base") and silently costs a
		# sample's timestamp.  String concatenation has no base.
		_i="${_u%.*}"
		_f="${_u#*.}"
		if [ "$_f" = "$_u" ]; then
			_f=00
		fi
		case "$_f" in
		?) _f="${_f}0" ;;
		??) ;;
		*) _f="$(printf %.2s "$_f")" ;;
		esac
		up_cs="${_i}${_f}"
	fi
}

read_cpu() {
	cpu_user=0 cpu_nice=0 cpu_sys=0 cpu_idle=0
	cpu_iowait=0 cpu_irq=0 cpu_softirq=0
	if read -r _tag _a _b _c _d _e _f _g _rest </proc/stat 2>/dev/null; then
		[ "$_tag" = "cpu" ] && {
			cpu_user=$_a cpu_nice=$_b cpu_sys=$_c cpu_idle=$_d
			cpu_iowait=$_e cpu_irq=$_f cpu_softirq=$_g
		}
	fi
}

read_mem() {
	mem_avail=0 mem_cached=0 mem_dirty=0 mem_writeback=0 swap_free=0
	_hits=0
	while read -r _k _v _; do
		case "$_k" in
		MemAvailable:) mem_avail=$_v _hits=$((_hits + 1)) ;;
		Cached:) mem_cached=$_v _hits=$((_hits + 1)) ;;
		SwapFree:) swap_free=$_v _hits=$((_hits + 1)) ;;
		Dirty:) mem_dirty=$_v _hits=$((_hits + 1)) ;;
		Writeback:) mem_writeback=$_v _hits=$((_hits + 1)) ;;
		esac
		# Every key we want lives in the first ~25 lines; stop there
		# rather than reading the remaining ~30.
		[ "$_hits" -ge 5 ] && break
	done </proc/meminfo 2>/dev/null
}

read_disk() {
	d_reads=0 d_rsect=0 d_writes=0 d_wsect=0 d_io_ms=0
	[ -n "$DISK_STAT" ] || return 0
	# /sys/class/block/<dev>/stat is one line; /proc/diskstats is ~50 on
	# this board (ram0-15, loop0-7, ...) and scanning it in shell cost
	# more CPU than everything else in the tick put together.
	if read -r _r _rm _rs _rms _w _wm _ws _wms _cur _ioms _ <"$DISK_STAT" 2>/dev/null; then
		d_reads=$_r d_rsect=$_rs d_writes=$_w d_wsect=$_ws d_io_ms=$_ioms
	fi
}

read_net() {
	n_rx=0 n_tx=0
	[ -n "$NET_RX" ] || return 0
	# Same reasoning as read_disk: two one-line files instead of the
	# ~45 interfaces this kernel enumerates in /proc/net/dev.
	read -r n_rx <"$NET_RX" 2>/dev/null || n_rx=0
	read -r n_tx <"$NET_TX" 2>/dev/null || n_tx=0
}

read_proc_pid() {
	p_utime=0 p_stime=0 p_rss_kb=0 p_minflt=0 p_majflt=0 p_alive=0
	[ "$pid" -gt 0 ] 2>/dev/null && [ -r /proc/"$pid"/stat ] || return 0
	if read -r _line </proc/"$pid"/stat; then
		# Drop "<pid> (<comm>) " so that $1 is the state character and
		# every later field sits at (procfs index - 2).
		_line="${_line#*) }"
		# Intentional word splitting: this is the whole point.
		# shellcheck disable=SC2086
		set -- $_line
		# procfs 10,12,14,15,24 -> local 8,10,12,13,22
		p_minflt=${8:-0}
		p_majflt=${10:-0}
		p_utime=${12:-0}
		p_stime=${13:-0}
		p_rss_kb=$((${22:-0} * 4))
		p_alive=1
	fi
}

read_proc_io() {
	p_read_bytes=0 p_write_bytes=0
	[ "$pid" -gt 0 ] 2>/dev/null && [ -r /proc/"$pid"/io ] || return 0
	while read -r _k _v; do
		case "$_k" in
		read_bytes:) p_read_bytes=$_v ;;
		write_bytes:)
			p_write_bytes=$_v
			break
			;;
		esac
	done </proc/"$pid"/io 2>/dev/null
}

read_sensors() {
	temp_mc=""
	throttled=""
	[ -n "$THERMAL" ] && [ -r "$THERMAL" ] && read -r temp_mc <"$THERMAL"
	[ -n "$THROTTLED" ] && [ -r "$THROTTLED" ] && read -r throttled <"$THROTTLED"
	: "${temp_mc:=}"
	: "${throttled:=}"
}

read_psi() {
	psi_cpu="" psi_io="" psi_mem=""
	[ "$PSI" = "1" ] || return 0
	# "some avg10=0.00 avg60=0.00 avg300=0.00 total=0" -> avg10.
	[ -r /proc/pressure/cpu ] || return 0
	if read -r _t _a10 _ </proc/pressure/cpu; then psi_cpu="${_a10#avg10=}"; fi
	if read -r _t _a10 _ </proc/pressure/io; then psi_io="${_a10#avg10=}"; fi
	if read -r _t _a10 _ </proc/pressure/memory; then psi_mem="${_a10#avg10=}"; fi
}

read_self_cpu() {
	# The observer's own cost, including the per-tick `sleep` it reaps
	# (cutime/cstime), which is the honest number to report.
	self_cpu=0
	if read -r _line </proc/$$/stat; then
		_line="${_line#*) }"
		# shellcheck disable=SC2086
		set -- $_line
		self_cpu=$(((${12:-0} + ${13:-0} + ${14:-0} + ${15:-0}) * J2MS))
	fi
}

resolve_pid() {
	# Re-read every tick: florestad may not have started yet, and a
	# restart inside one run must not silently orphan the columns.
	[ -n "$PIDFILE" ] && [ -r "$PIDFILE" ] || return 0
	_p=0
	# The redirection is what fails when the file is absent, and the
	# shell reports that itself -- `2>/dev/null` on the command would
	# not catch it -- so existence is checked before the read, every
	# tick, for as long as florestad has not started yet.
	read -r _p <"$PIDFILE" || _p=0
	case "$_p" in
	'' | *[!0-9]*) _p=0 ;;
	esac
	if [ "$_p" != "$pid" ]; then
		pid=$_p
		# A new process invalidates the previous cumulative counters.
		prev_p_utime=0 prev_p_stime=0 prev_p_minflt=0 prev_p_majflt=0
		prev_p_read_bytes=0 prev_p_write_bytes=0
	fi
	[ -d /proc/"$pid" ] || pid=0
}

sample() {
	resolve_pid
	read_uptime
	read_cpu
	read_mem
	read_disk
	read_net
	read_proc_pid
	read_proc_io
	read_sensors
	read_psi
	read_self_cpu
}

emit() {
	echo "$up_cs,\
$(((cpu_user - prev_cpu_user) * J2MS)),\
$(((cpu_nice - prev_cpu_nice) * J2MS)),\
$(((cpu_sys - prev_cpu_sys) * J2MS)),\
$(((cpu_idle - prev_cpu_idle) * J2MS)),\
$(((cpu_iowait - prev_cpu_iowait) * J2MS)),\
$(((cpu_irq - prev_cpu_irq) * J2MS)),\
$(((cpu_softirq - prev_cpu_softirq) * J2MS)),\
$mem_avail,$mem_cached,$mem_dirty,$mem_writeback,$swap_free,\
$((d_reads - prev_d_reads)),$(((d_rsect - prev_d_rsect) * 512)),\
$((d_writes - prev_d_writes)),$(((d_wsect - prev_d_wsect) * 512)),\
$((d_io_ms - prev_d_io_ms)),\
$((n_rx - prev_n_rx)),$((n_tx - prev_n_tx)),\
$(((p_utime - prev_p_utime) * J2MS)),$(((p_stime - prev_p_stime) * J2MS)),\
$p_rss_kb,\
$((p_minflt - prev_p_minflt)),$((p_majflt - prev_p_majflt)),\
$((p_read_bytes - prev_p_read_bytes)),$((p_write_bytes - prev_p_write_bytes)),\
$temp_mc,$throttled,$psi_cpu,$psi_io,$psi_mem,$p_alive,$self_cpu"
}

remember() {
	prev_cpu_user=$cpu_user prev_cpu_nice=$cpu_nice prev_cpu_sys=$cpu_sys
	prev_cpu_idle=$cpu_idle prev_cpu_iowait=$cpu_iowait
	prev_cpu_irq=$cpu_irq prev_cpu_softirq=$cpu_softirq
	prev_d_reads=$d_reads prev_d_rsect=$d_rsect
	prev_d_writes=$d_writes prev_d_wsect=$d_wsect prev_d_io_ms=$d_io_ms
	prev_n_rx=$n_rx prev_n_tx=$n_tx
	prev_p_utime=$p_utime prev_p_stime=$p_stime
	prev_p_minflt=$p_minflt prev_p_majflt=$p_majflt
	prev_p_read_bytes=$p_read_bytes prev_p_write_bytes=$p_write_bytes
}

# --- main loop -------------------------------------------------------

# Prime the counters.  The first tick produces no row: a row of zeroed
# deltas would look like an idle second that never happened.
sample
remember
prev_ok=1

trap 'exit 0' TERM INT HUP

while :; do
	sleep "$INTERVAL"
	sample
	[ -n "$HEARTBEAT" ] && echo "$up_cs" >"$HEARTBEAT"
	[ "$prev_ok" = "1" ] && emit
	remember
done
