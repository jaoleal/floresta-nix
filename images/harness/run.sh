#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# bench-node -- measure what a Bitcoin node costs on a small board.
#
# Everything here runs on the lab host.  The target contributes exactly
# two long-lived processes: florestad itself, and one POSIX sh loop
# reading /proc.  That asymmetry is deliberate -- on a single-core board
# the measurement apparatus is a competitor for the resource being
# measured, so it is kept as close to nothing as it can be and its cost
# is reported alongside the results.
#
# The target is described entirely by a profile in targets/.  If you
# find yourself adding a board-specific branch to this file, the profile
# schema is missing a field; add the field instead.

set -euo pipefail

readonly EX_OK=0
readonly EX_USAGE=1
readonly EX_PREFLIGHT=2
readonly EX_UNREACHABLE=3
readonly EX_RUNFAIL=4
readonly EX_TEARDOWN=5

readonly SCHEMA_VERSION=1
readonly HARNESS_VERSION="0.1.0"

HARNESS_DIR="${BENCH_HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
readonly HARNESS_DIR
TARGETS_DIR="${BENCH_TARGETS_DIR:-$HARNESS_DIR/targets}"
readonly TARGETS_DIR

# --- defaults --------------------------------------------------------

TARGET=""
HOST=""
DATADIR=""
NETWORK=""
UNTIL_HEIGHT=""
DURATION=""
POWER_METER=""
SCRAPE_INTERVAL="5s"
BACKFILL=""
PROFILE_MODE="off"
STATE_MODE="resume"
OUT_DIR="./runs"
DRY_RUN=0
BASELINE_SECS="${BENCH_BASELINE_SECS:-180}"
ALLOW_NO_METRICS=0
ARCHIVE_BINARY=0
CONNECT_PEERS=()
EXTRA_FLAGS=()
NOTE_SD_CARD="${BENCH_SD_CARD:-}"
NOTE_PSU="${BENCH_PSU:-}"
NOTE_CABLE="${BENCH_CABLE:-}"
NOTE_AMBIENT="${BENCH_AMBIENT_C:-}"

# --- state -----------------------------------------------------------

RUN_DIR=""
RUN_ID=""
LOG_FILE=""
CTL_PATH=""
TMP_DIR=""
TARGET_WORKDIR=""
FLORESTAD_PID=""
COLLECTOR_PID=""
SCRAPER_PID=""
POWER_PID=""
TAIL_PID=""
TUNNEL_PID=""
LOCAL_METRICS_PORT=""
BOOT_EPOCH_MS=""
CLOCK_OFFSET_MS=""
CLOCK_RTT_MS=""
CLOCK_OFFSET_START_MS=""
CLOCK_OFFSET_END_MS=""
CLEAN_SHUTDOWN="false"
FLORESTAD_EXIT=""
RUN_ABORTED=0
TEARDOWN_DONE=0
PHASE="startup"

# --- output ----------------------------------------------------------

log() {
	local line
	line="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) [$PHASE] $*"
	echo "$line" >&2
	[ -n "$LOG_FILE" ] && echo "$line" >>"$LOG_FILE"
	return 0
}

phase() {
	PHASE="$1"
	log "=== phase: $1 ==="
}

die() {
	local code="$1"
	shift
	log "FATAL: $*"
	exit "$code"
}

now_ms() { date -u +%s%3N; }

# --- ssh -------------------------------------------------------------
#
# One multiplexed connection carries every channel: the control commands,
# the collector stream, the log tail and the metrics tunnel.  Opening a
# fresh TCP connection per command would add its own latency to the
# measurements and, on a USB gadget link, its own failure mode.

# Extra ssh arguments -- identity file, port, jump host -- come from the
# environment rather than the flake, so a lab's addressing and keys never
# end up committed:
#
#   BENCH_SSH_OPTS="-i ~/.ssh/lab_key -J bastion" bench-node --target rasp-pi-zero ...
#
# Built once, into a global, because tsh is called often enough that
# rebuilding the list per call would put a subshell between the harness
# and every measurement.
SSH_OPTS=()

init_ssh_opts() {
	SSH_OPTS=()
	# Intentional word splitting: the variable holds an argument list.
	# shellcheck disable=SC2206
	[ -n "${BENCH_SSH_OPTS:-}" ] && SSH_OPTS=(${BENCH_SSH_OPTS})
	SSH_OPTS+=(
		-o BatchMode=yes
		-o StrictHostKeyChecking=accept-new
		-o ControlMaster=auto
		-o ControlPath="$CTL_PATH"
		-o ControlPersist=60
		-o ServerAliveInterval=15
		-o ServerAliveCountMax=4
		-o ConnectTimeout=10
	)
}

tsh() {
	ssh "${SSH_OPTS[@]}" "$HOST" "$@"
}

# Stages the remote/ scripts in a per-run directory under /tmp on the
# target.  Piping them on stdin would be tidier, but a script that
# detaches a background process races the SSH channel closing under it,
# and this harness exists partly to stop processes being orphaned.
# Nothing is installed: the directory is removed at teardown, and on
# these boards /tmp is a tmpfs that a reboot clears anyway.
upload_remote_scripts() {
	local script
	tsh "mkdir -p '$TARGET_WORKDIR'" ||
		die "$EX_PREFLIGHT" "cannot create $TARGET_WORKDIR on the target"
	for script in collect-proc.sh run-florestad.sh watchdog.sh; do
		tsh "cat > '$TARGET_WORKDIR/$script'" <"$HARNESS_DIR/remote/$script" ||
			die "$EX_PREFLIGHT" "cannot stage $script on the target"
	done
	log "staged the collector, launcher and watchdog in $TARGET_WORKDIR"
}

# --- profile ---------------------------------------------------------

# A profile value by dotted path, or the given default when the profile
# leaves it null.  `false` is a value, not an absence -- hence the
# explicit null test rather than jq's `//`.
pget() {
	local path="$1" def="${2-}" val
	val="$(jq -r --arg p "$path" \
		'getpath($p | split(".")) | if . == null then "" else . end' \
		<<<"$PROFILE_JSON")"
	if [ -z "$val" ]; then echo "$def"; else echo "$val"; fi
}

load_profile() {
	local file="$TARGETS_DIR/$TARGET.json"
	if [ ! -r "$file" ]; then
		local available
		available="$(cd "$TARGETS_DIR" 2>/dev/null && ls ./*.json 2>/dev/null |
			sed 's|^\./||; s|\.json$||' | tr '\n' ' ' || true)"
		die "$EX_USAGE" "unknown target '$TARGET'; available: ${available:-none}"
	fi
	PROFILE_JSON="$(cat "$file")"
	jq -e . >/dev/null <<<"$PROFILE_JSON" ||
		die "$EX_USAGE" "profile $file is not valid JSON"

	# CLI overrides the profile; the profile overrides nothing else.
	[ -z "$HOST" ] && HOST="$(pget host)"
	[ -z "$DATADIR" ] && DATADIR="$(pget datadir)"
	[ -z "$NETWORK" ] && NETWORK="$(pget network)"
	[ -z "$POWER_METER" ] && POWER_METER="$(pget powerMeter none)"

	FLORESTAD_BIN="$(pget florestad florestad)"
	# Preflight replaces this with the resolved absolute path; --dry-run
	# never gets that far and describes the plan with what it has.
	FLORESTAD_PATH="$FLORESTAD_BIN"
	FLORESTA_CLI="$(pget florestaCli floresta-cli)"
	METRICS_PORT="$(pget metricsPort 3333)"
	METRICS_PATH="$(pget metricsPath /)"
	PROC_INTERVAL="$(pget procInterval 1)"
	CLK_TCK="$(pget clkTck 100)"
	TIME_SOURCE="$(pget timeSource uptime)"
	PROFILER="$(pget profiler none)"
	MIN_FREE_BYTES="$(pget minFreeBytes 1073741824)"
	SENSOR_THERMAL="$(pget sensors.thermal)"
	SENSOR_THROTTLED="$(pget sensors.throttled)"
	SENSOR_PRESSURE="$(pget sensors.pressure false)"
	DISK_DEVICE="$(pget sensors.diskDevice)"
	NET_IFACE="$(pget sensors.netInterface)"

	[ -n "$HOST" ] || die "$EX_USAGE" \
		"profile '$TARGET' declares no host and --host was not given"
	[ -n "$DATADIR" ] || die "$EX_USAGE" "no datadir in profile or --datadir"
}

# --- argument parsing ------------------------------------------------

usage() {
	cat <<'EOF'
bench-node -- measure a Bitcoin node's cost on a small board

  bench-node [options]
  bench-node export --format parquet|sqlite <run-dir>
  bench-node serve-prom [--port N] <run-dir>

Options:
  --target NAME            profile from targets/ (required)
  --host USER@HOST         override the profile's host
  --datadir PATH           florestad data directory on the target
  --network NET            bitcoin|signet|testnet4
  --until-height N         stop once the tip reaches height N
  --duration SPEC          stop after this long (45m, 2h, 900s)
  --power-meter NAME       none|um25c|ina226        (default: profile)
  --scrape-interval SPEC   Prometheus scrape period (default: 5s)
  --backfill on|off        pass --no-backfill or not
  --profile off|perf       run kind: bench measurement or CPU profile
  --fresh | --resume       wipe the datadir first, or keep it (default)
  --baseline SECS          idle baseline length      (default: 180)
  --connect ADDR           connect only to this peer (repeatable)
  --florestad-flag FLAG    extra flag for florestad  (repeatable)
  --archive-binary         keep a copy of the target binary with the run
  --allow-no-metrics       downgrade the metrics preflight to a warning
  --out DIR                where runs are written    (default: ./runs)
  --dry-run                print the plan; touch nothing but `ssh true`
  -h, --help               this text

Environment:
  BENCH_SSH_OPTS   extra ssh arguments (identity file, port, jump host)
  BENCH_POWER_DEVICE, BENCH_POWER_RATE, BENCH_POWER_BAUD
                   passed through to the power driver
  BENCH_SD_CARD, BENCH_PSU, BENCH_CABLE, BENCH_AMBIENT_C
                   recorded in meta.json; an SD card model explains more
                   variance between two runs than most code changes do

Exit codes: 0 ok, 1 usage, 2 preflight, 3 target unreachable,
            4 florestad failed, 5 unclean teardown
EOF
}

parse_duration() {
	local spec="$1" n unit
	n="${spec%[smh]}"
	unit="${spec#"$n"}"
	[[ "$n" =~ ^[0-9]+$ ]] || die "$EX_USAGE" "bad duration '$spec'"
	case "$unit" in
	s | "") echo "$n" ;;
	m) echo $((n * 60)) ;;
	h) echo $((n * 3600)) ;;
	*) die "$EX_USAGE" "bad duration unit in '$spec'" ;;
	esac
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--target) TARGET="$2"; shift 2 ;;
		--host) HOST="$2"; shift 2 ;;
		--datadir) DATADIR="$2"; shift 2 ;;
		--network) NETWORK="$2"; shift 2 ;;
		--until-height) UNTIL_HEIGHT="$2"; shift 2 ;;
		--duration) DURATION="$2"; shift 2 ;;
		--power-meter) POWER_METER="$2"; shift 2 ;;
		--scrape-interval) SCRAPE_INTERVAL="$2"; shift 2 ;;
		--backfill) BACKFILL="$2"; shift 2 ;;
		--profile) PROFILE_MODE="$2"; shift 2 ;;
		--baseline) BASELINE_SECS="$2"; shift 2 ;;
		--connect)
			CONNECT_PEERS+=("$2")
			shift 2
			;;
		--florestad-flag)
			EXTRA_FLAGS+=("$2")
			shift 2
			;;
		--out) OUT_DIR="$2"; shift 2 ;;
		--fresh) STATE_MODE="fresh"; shift ;;
		--resume) STATE_MODE="resume"; shift ;;
		--archive-binary) ARCHIVE_BINARY=1; shift ;;
		--allow-no-metrics) ALLOW_NO_METRICS=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h | --help)
			usage
			exit "$EX_OK"
			;;
		*) die "$EX_USAGE" "unknown option '$1' (try --help)" ;;
		esac
	done

	[ -n "$TARGET" ] || die "$EX_USAGE" "--target is required (try --help)"

	if [ -n "$UNTIL_HEIGHT" ] && [ -n "$DURATION" ]; then
		die "$EX_USAGE" "--until-height and --duration are mutually exclusive"
	fi
	if [ -z "$UNTIL_HEIGHT" ] && [ -z "$DURATION" ]; then
		die "$EX_USAGE" "one of --until-height or --duration is required"
	fi
	if [ -n "$UNTIL_HEIGHT" ] && ! [[ "$UNTIL_HEIGHT" =~ ^[0-9]+$ ]]; then
		die "$EX_USAGE" "--until-height must be a number"
	fi
	DURATION_SECS=0
	[ -n "$DURATION" ] && DURATION_SECS="$(parse_duration "$DURATION")"
	SCRAPE_SECS="$(parse_duration "$SCRAPE_INTERVAL")"
	[ "$SCRAPE_SECS" -ge 1 ] || die "$EX_USAGE" "--scrape-interval must be >= 1s"

	case "$PROFILE_MODE" in off | perf) ;; *) die "$EX_USAGE" "--profile must be off or perf" ;; esac
	case "$BACKFILL" in "" | on | off) ;; *) die "$EX_USAGE" "--backfill must be on or off" ;; esac
	case "$POWER_METER" in "" | none | um25c | ina226) ;; *)
		die "$EX_USAGE" "unknown --power-meter '$POWER_METER'"
		;;
	esac
	[[ "$BASELINE_SECS" =~ ^[0-9]+$ ]] || die "$EX_USAGE" "--baseline must be seconds"
}

# --- preflight -------------------------------------------------------
#
# Every check here exists because getting it wrong once produced a run
# whose numbers could not be interpreted afterwards.  Failing loudly at
# the start costs a minute; failing silently costs the whole run.

PREFLIGHT_WARNINGS=()

warn() {
	PREFLIGHT_WARNINGS+=("$*")
	log "WARNING: $*"
}

preflight_reachable() {
	log "checking ssh to $HOST"
	tsh true 2>/dev/null || die "$EX_UNREACHABLE" "cannot ssh to $HOST"
	TARGET_UNAME="$(tsh 'uname -srm')"
	TARGET_KERNEL="$(tsh 'uname -r')"
	TARGET_OS="$(tsh 'cat /etc/os-release 2>/dev/null | sed -n "s/^PRETTY_NAME=//p" | tr -d \"\\\"\" || true')"
	[ -n "$TARGET_OS" ] || TARGET_OS="unknown"
	log "target: $TARGET_UNAME ($TARGET_OS)"
}

# Anchors the target's monotonic clock to the host's wall clock, and
# checks that the two wall clocks agree.
#
# A board without an RTC boots in 1970 and jumps to the real time
# whenever DNS and NTP first succeed -- which, on one earlier run here,
# happened *in the middle of the measurement* and destroyed every
# correlation in the dataset.  So: refuse to start when the clocks
# disagree, and stamp target samples from /proc/uptime, which cannot
# jump, rather than from a wall clock that can.
# Sets BOOT_EPOCH_MS (once per run), CLOCK_RTT_MS and CLOCK_OFFSET_MS.
# It assigns rather than prints because a command substitution would run
# it in a subshell, and the anchor would never reach the caller.
measure_clock() {
	local h0 h1 out uptime_s epoch_s hmid up_ms
	h0="$(now_ms)"
	out="$(tsh 'read -r u _ </proc/uptime; echo "$u $(date -u +%s)"')"
	h1="$(now_ms)"
	uptime_s="${out%% *}"
	epoch_s="${out##* }"

	CLOCK_RTT_MS=$((h1 - h0))
	hmid=$(((h0 + h1) / 2))
	up_ms="$(awk -v u="$uptime_s" 'BEGIN{printf "%d", u*1000}')"

	# The target's uptime, expressed on the host's clock.  Every
	# target-side timestamp in this run is derived from this anchor, so
	# it is fixed at preflight: re-deriving it at teardown would shift
	# every proc.csv row that had already been written against it.
	[ -z "$BOOT_EPOCH_MS" ] && BOOT_EPOCH_MS=$((hmid - up_ms))

	# busybox `date` truncates to the second, so the true offset lies
	# somewhere in [offset, offset+1000).  Report the optimistic end and
	# say so, rather than inventing precision.
	CLOCK_OFFSET_MS=$((epoch_s * 1000 - hmid))
}

preflight_clock() {
	measure_clock
	CLOCK_OFFSET_START_MS="$CLOCK_OFFSET_MS"
	log "clock offset (target - host): ${CLOCK_OFFSET_START_MS}ms (rtt ${CLOCK_RTT_MS}ms, +/-1000ms from second-resolution date)"

	local abs=${CLOCK_OFFSET_START_MS#-}
	if [ "$abs" -gt 2000 ]; then
		die "$EX_PREFLIGHT" \
			"target clock is ${CLOCK_OFFSET_START_MS}ms from the host's; fix NTP on the target before benchmarking (nothing in the report would be alignable)"
	fi

	TARGET_TZ="$(tsh 'date +%z')"
	log "target timezone offset: $TARGET_TZ (florestad logs in local time)"
}

preflight_tools() {
	local missing=() tool
	local required optional
	required="$(jq -r '.requiredTools[]?' <<<"$PROFILE_JSON")"
	optional="$(jq -r '.optionalTools[]?' <<<"$PROFILE_JSON")"

	MISSING_OPTIONAL=""
	local present
	present="$(tsh 'for t in '"$(echo "$required $optional" | tr "\n" " ")"'; do
		command -v "$t" >/dev/null 2>&1 && echo "$t"
	done')"

	for tool in $required; do
		grep -qx "$tool" <<<"$present" || missing+=("$tool")
	done
	for tool in $optional; do
		grep -qx "$tool" <<<"$present" || MISSING_OPTIONAL="$MISSING_OPTIONAL $tool"
	done

	if [ ${#missing[@]} -gt 0 ]; then
		die "$EX_PREFLIGHT" \
			"target is missing tools the profile requires: ${missing[*]}"
	fi
	[ -n "$MISSING_OPTIONAL" ] && warn "optional tools absent on target:$MISSING_OPTIONAL"
	return 0
}

preflight_disk() {
	local avail
	avail="$(tsh "df -k '$(dirname "$DATADIR")' 2>/dev/null | awk 'NR==2{print \$4*1024}'")"
	[ -n "$avail" ] || die "$EX_PREFLIGHT" "cannot stat the datadir filesystem"
	DATADIR_FS_FREE_BYTES="$avail"
	if [ "$avail" -lt "$MIN_FREE_BYTES" ]; then
		die "$EX_PREFLIGHT" \
			"only $((avail / 1048576)) MiB free where the datadir lives; the profile asks for $((MIN_FREE_BYTES / 1048576)) MiB"
	fi
	log "datadir filesystem free: $((avail / 1048576)) MiB"
}

# Identifies the binary under test and answers the one question that
# decides whether metrics exist at all.
#
# The `metrics` feature is a compile-time cfg with no runtime flag, so
# the only honest check is to look inside the binary for a string that
# exists solely on that code path.  Grepping an 11 MB binary takes 14
# seconds of the target's CPU; pulling it over the wire takes 18 and
# gives the host a copy to hash, to archive for profiling, and to check
# without spending the target's cycles.
preflight_binary() {
	local remote_path
	remote_path="$(tsh "command -v '$FLORESTAD_BIN' || echo ''")"
	[ -n "$remote_path" ] ||
		die "$EX_PREFLIGHT" "florestad not found on the target as '$FLORESTAD_BIN'"
	FLORESTAD_PATH="$remote_path"

	FLORESTAD_VERSION="$(tsh "'$remote_path' --version 2>&1 | head -1" || echo unknown)"
	FLORESTAD_SIZE="$(tsh "ls -l '$remote_path' | awk '{print \$5}'")"

	local copy="$TMP_DIR/florestad.bin"
	log "fetching the binary to identify it ($((FLORESTAD_SIZE / 1048576)) MiB)"
	tsh "cat '$remote_path'" >"$copy" ||
		die "$EX_PREFLIGHT" "could not read the binary from the target"

	FLORESTAD_SHA256="$(sha256sum "$copy" | cut -d' ' -f1)"
	FLORESTAD_MD5="$(md5sum "$copy" | cut -d' ' -f1)"
	log "florestad: $FLORESTAD_VERSION"
	log "sha256: $FLORESTAD_SHA256"

	# Emitted only under #[cfg(feature = "metrics")].
	if grep -qa "Started metrics server on" "$copy"; then
		METRICS_BUILT="true"
		log "metrics feature: present"
	else
		METRICS_BUILT="false"
		if [ "$ALLOW_NO_METRICS" -eq 1 ]; then
			warn "florestad was built WITHOUT the metrics feature: metrics.jsonl will be empty and the report loses peer-latency and block-height series (--allow-no-metrics given, continuing)"
		else
			die "$EX_PREFLIGHT" \
				"florestad on the target was built without the 'metrics' feature, so no exporter will ever answer. Rebuild with --features metrics, or pass --allow-no-metrics to run without that data."
		fi
	fi

	# GNU build-id, for matching profiles to symbols later.
	BUILD_ID="$(readelf -n "$copy" 2>/dev/null |
		sed -n 's/.*Build ID: \([0-9a-f]*\).*/\1/p' | head -1 || true)"
	[ -n "$BUILD_ID" ] || BUILD_ID=""

	if [ "$ARCHIVE_BINARY" -eq 1 ] || [ "$PROFILE_MODE" = "perf" ]; then
		cp "$copy" "$RUN_DIR/florestad.bin"
		log "archived the binary with the run (needed to resolve symbols later)"
	fi
}

preflight_no_stray_node() {
	local running
	running="$(tsh "ps w 2>/dev/null | grep -v grep | grep '$(basename "$FLORESTAD_BIN")' || true")"
	[ -n "$running" ] || return 0

	# A node already on this datadir would fight ours for the chainstate
	# lock and for the only core; one elsewhere just makes the numbers
	# noisy, which the report must say out loud.
	if grep -q -- "$DATADIR" <<<"$running"; then
		die "$EX_PREFLIGHT" \
			"a florestad is already running on $DATADIR; stop it first (this harness will not adopt a process it did not start)"
	fi
	warn "another florestad is running on the target with a different datadir; it will compete for CPU and network for the whole run: $(tr '\n' ';' <<<"$running")"
}

preflight_profiler() {
	[ "$PROFILE_MODE" = "perf" ] || return 0

	if [ "$PROFILER" != "perf" ]; then
		die "$EX_PREFLIGHT" \
			"profile '$TARGET' declares profiler=$PROFILER: this board has no perf, so --profile perf would produce an empty flamegraph. Not generating one."
	fi
	tsh 'command -v perf >/dev/null' ||
		die "$EX_PREFLIGHT" "the profile promises perf but the target has none"

	local paranoid
	paranoid="$(tsh 'cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 99')"
	if [ "$paranoid" -gt 1 ]; then
		warn "perf_event_paranoid=$paranoid may block kernel-symbol sampling; set it to 1 for full stacks"
	fi
	[ -n "$BUILD_ID" ] ||
		warn "the binary carries no build-id and may have been stripped; expect unresolved frames"
}

preflight_power() {
	POWER_DRIVER=""
	[ "$POWER_METER" = "none" ] && {
		log "power meter: none (the report will have no energy section)"
		return 0
	}

	POWER_DRIVER="$HARNESS_DIR/power/$POWER_METER.sh"
	[ -x "$POWER_DRIVER" ] ||
		die "$EX_PREFLIGHT" "no driver for power meter '$POWER_METER'"

	log "probing the power meter with $POWER_DRIVER"
	local probe="$TMP_DIR/power-probe"
	timeout 15 "$POWER_DRIVER" >"$probe" 2>"$TMP_DIR/power-probe.err" || true
	if [ ! -s "$probe" ]; then
		die "$EX_PREFLIGHT" \
			"the $POWER_METER driver produced no samples in 15s: $(tail -3 "$TMP_DIR/power-probe.err" 2>/dev/null || echo 'no diagnostics')"
	fi
	log "power meter responding: $(head -1 "$probe")"
}

preflight_sensors() {
	# Sensors are optional by nature: a board either has a thermal zone
	# or it does not.  Their presence is recorded so the report never
	# claims a column it does not have.
	local s
	for s in thermal throttled; do
		local pathvar="SENSOR_${s^^}"
		local path="${!pathvar}"
		[ -n "$path" ] || continue
		if ! tsh "[ -r '$path' ]"; then
			warn "sensor $s declared at $path but unreadable; that column will be empty"
			eval "$pathvar=''"
		fi
	done

	if [ "$SENSOR_PRESSURE" = "true" ]; then
		if tsh '[ -r /proc/pressure/cpu ]'; then
			PSI_FLAG=1
		else
			warn "profile expects PSI but /proc/pressure is absent (CONFIG_PSI off)"
			PSI_FLAG=0
		fi
	else
		PSI_FLAG=0
	fi

	# Autodetect what the profile left null, so a new board needs a
	# nearly empty profile rather than a lab notebook.
	if [ -z "$DISK_DEVICE" ]; then
		# The datadir may not exist yet (a --fresh run creates it), so
		# ask about the filesystem that will hold it.
		DISK_DEVICE="$(tsh "df '$(dirname "$DATADIR")' 2>/dev/null | awk 'NR==2{print \$1}' | sed 's|.*/||'" || true)"
		# tmpfs, overlay and friends have no block device to sample.
		case "$DISK_DEVICE" in
		tmpfs | overlay | none | devtmpfs | "") DISK_DEVICE="" ;;
		esac
		log "autodetected datadir device: ${DISK_DEVICE:-none}"
	fi
	if [ -z "$NET_IFACE" ]; then
		NET_IFACE="$(tsh "ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p' | head -1" || true)"
		log "autodetected network interface: ${NET_IFACE:-none}"
	fi
	[ -n "$DISK_DEVICE" ] || warn "no datadir block device identified; disk columns will be zero"
	[ -n "$NET_IFACE" ] || warn "no network interface identified; net columns will be zero"
}

preflight_metrics_endpoint() {
	# The exporter only exists while florestad runs, so this is a
	# tunnel-and-port sanity check now and a real fetch once the node is
	# up (see run_phase).
	[ "$METRICS_BUILT" = "true" ] || return 0
	if tsh "wget -q -T 2 -O /dev/null http://127.0.0.1:$METRICS_PORT$METRICS_PATH" 2>/dev/null; then
		warn "something is already answering on the target's metrics port $METRICS_PORT"
	fi
	return 0
}

preflight() {
	phase preflight
	preflight_reachable
	preflight_clock
	preflight_tools
	preflight_disk
	preflight_binary
	preflight_no_stray_node
	preflight_profiler
	preflight_sensors
	preflight_metrics_endpoint
	preflight_power
	log "preflight passed with ${#PREFLIGHT_WARNINGS[@]} warning(s)"
}

# --- collectors ------------------------------------------------------
#
# All three start before the first baseline and stop after the last one,
# so proc.csv and power.csv are one continuous series across the whole
# session.  Which part of that series is baseline, sync or shutdown is
# expressed in windows.csv, not by starting and stopping instruments.

start_proc_collector() {
	log "starting the target-side /proc collector (every ${PROC_INTERVAL}s)"
	ssh "${SSH_OPTS[@]}" "$HOST" \
		"sh '$TARGET_WORKDIR/collect-proc.sh' '$PROC_INTERVAL' \
		 '$TARGET_WORKDIR/florestad.pid' '$DISK_DEVICE' '$NET_IFACE' \
		 '$SENSOR_THERMAL' '$SENSOR_THROTTLED' '$PSI_FLAG' \
		 '$TARGET_WORKDIR/heartbeat'" \
		>"$RUN_DIR/proc.raw" 2>>"$RUN_DIR/collector.err" &
	COLLECTOR_PID=$!
}

start_power_meter() {
	[ "$POWER_METER" = "none" ] && return 0
	log "starting the $POWER_METER power meter"
	"$POWER_DRIVER" >"$RUN_DIR/power.raw" 2>>"$RUN_DIR/power.err" &
	POWER_PID=$!
}

# The exposition is pulled through the SSH connection rather than by
# reaching for the target's port directly: the exporter binds 0.0.0.0,
# but a tunnel keeps the measurement independent of how the lab network
# happens to be routed today.
start_metrics_tunnel() {
	[ "$METRICS_BUILT" = "true" ] || return 0
	LOCAL_METRICS_PORT="$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"
	ssh "${SSH_OPTS[@]}" -N -L "127.0.0.1:$LOCAL_METRICS_PORT:127.0.0.1:$METRICS_PORT" "$HOST" &
	TUNNEL_PID=$!
	sleep 1
	log "metrics tunnel: localhost:$LOCAL_METRICS_PORT -> $HOST:$METRICS_PORT"
}

# Stores the exposition verbatim, one JSON object per scrape.  Parsing
# happens in the report; a stored histogram keeps its buckets, and a
# bucket can still become a heatmap next month, while a quantile
# computed today cannot.
start_metrics_scraper() {
	[ "$METRICS_BUILT" = "true" ] || return 0
	log "scraping metrics every ${SCRAPE_SECS}s"
	(
		while :; do
			local_t0="$(now_ms)"
			body="$(curl -sS --max-time 4 \
				"http://127.0.0.1:$LOCAL_METRICS_PORT$METRICS_PATH" 2>/dev/null || true)"
			local_t1="$(now_ms)"
			if [ -n "$body" ]; then
				jq -cn --argjson t "$local_t0" \
					--argjson lat "$((local_t1 - local_t0))" \
					--arg b "$body" \
					'{t_ms:$t, latency_ms:$lat, ok:true, body:$b}'
			else
				jq -cn --argjson t "$local_t0" \
					--argjson lat "$((local_t1 - local_t0))" \
					'{t_ms:$t, latency_ms:$lat, ok:false, body:""}'
			fi
			sleep "$SCRAPE_SECS"
		done
	) >"$RUN_DIR/metrics.jsonl" 2>/dev/null &
	SCRAPER_PID=$!
}

stop_collectors() {
	local pid
	for pid in "$SCRAPER_PID" "$POWER_PID" "$COLLECTOR_PID" "$TAIL_PID" "$TUNNEL_PID"; do
		[ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
	done
	# The power driver is asked to flush, not shot: SIGTERM is part of
	# the driver contract.
	sleep 1
	for pid in "$SCRAPER_PID" "$POWER_PID" "$COLLECTOR_PID" "$TAIL_PID" "$TUNNEL_PID"; do
		[ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
	done
	SCRAPER_PID="" POWER_PID="" COLLECTOR_PID="" TAIL_PID="" TUNNEL_PID=""
}

# --- windows ---------------------------------------------------------

# windows.raw is a raw stream like proc.raw and power.raw, and is kept
# for the same reason: assemble.py must be re-runnable against a stored
# run after a parser fix, which it would not be if the phase boundaries
# were consumed on first use.
window_open() {
	echo "$1,$(now_ms)," >>"$RUN_DIR/windows.raw"
}

window_close() {
	local label="$1" tmp="$RUN_DIR/windows.raw.tmp"
	awk -v l="$label" -v t="$(now_ms)" -F, '
		$1 == l && $3 == "" { print $1 "," $2 "," t; next } { print }
	' "$RUN_DIR/windows.raw" >"$tmp" && mv "$tmp" "$RUN_DIR/windows.raw"
}

# --- baseline --------------------------------------------------------
#
# Three idle minutes before and after, with florestad stopped.  Every
# energy number in the report is a delta over this, because a board that
# burns 0.7 W doing nothing is most of the reading and none of the
# answer.

baseline() {
	local label="$1"
	phase "baseline"
	log "$label baseline: ${BASELINE_SECS}s idle with florestad stopped"
	window_open "$label"
	local end=$((SECONDS + BASELINE_SECS))
	while [ "$SECONDS" -lt "$end" ]; do
		[ "$INTERRUPTED" -eq 1 ] && break
		printf '\r  baseline: %ds remaining   ' "$((end - SECONDS))" >&2
		sleep 2
	done
	printf '\r%*s\r' 40 '' >&2
	window_close "$label"
}

# --- run -------------------------------------------------------------

florestad_argv() {
	local -a argv=("$FLORESTAD_PATH" --network "$NETWORK" --data-dir "$DATADIR")
	# Deliberately no --log-to-file: the harness already captures the
	# node's stdout, and having florestad write a second copy into the
	# datadir would put the measurement's own logging into the SD-card
	# write counters this run is trying to measure.
	[ "$BACKFILL" = "off" ] && argv+=(--no-backfill)
	local peer
	for peer in "${CONNECT_PEERS[@]+"${CONNECT_PEERS[@]}"}"; do
		argv+=(--connect "$peer")
	done
	argv+=("${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}")

	# -d is what switches the log timestamp to milliseconds; RUST_LOG
	# independently holds the level at info.  Without this pair every
	# block event would land in a one-second bucket, and ms/tx derived
	# from it would carry that error silently.
	printf '%q ' env RUST_LOG=info "${argv[@]}" -d
}

current_height() {
	grep -a "New tip!" "$RUN_DIR/florestad.log" 2>/dev/null |
		tail -1 | sed -n 's/.*height=\([0-9]*\).*/\1/p'
}

run_phase() {
	phase run

	if [ "$STATE_MODE" = "fresh" ]; then
		log "--fresh: removing $DATADIR on the target"
		tsh "rm -rf '$DATADIR'" ||
			die "$EX_PREFLIGHT" "could not clear the datadir"
	fi
	DATADIR_BYTES_BEFORE="$(tsh "du -sk '$DATADIR' 2>/dev/null | awk '{print \$1*1024}'" || echo 0)"

	local cmd
	cmd="$(florestad_argv)"
	log "launching: $cmd"

	FLORESTAD_PID="$(tsh "sh '$TARGET_WORKDIR/run-florestad.sh' \
		'$TARGET_WORKDIR' '$TARGET_WORKDIR/florestad.log' $cmd")" || {
		RUN_ABORTED=1
		die "$EX_RUNFAIL" "florestad did not start"
	}
	log "florestad running as pid $FLORESTAD_PID"

	# Stream the node's log to the host as it is written.  Nothing here
	# depends on the target keeping it: if the SD card fills, the host
	# already has every line up to that point.
	ssh "${SSH_OPTS[@]}" "$HOST" "tail -n +1 -F '$TARGET_WORKDIR/florestad.log' 2>/dev/null" \
		>"$RUN_DIR/florestad.log" 2>/dev/null &
	TAIL_PID=$!

	# The other half of the orphan guard; see remote/watchdog.sh.
	tsh "nohup sh '$TARGET_WORKDIR/watchdog.sh' '$TARGET_WORKDIR/heartbeat' \
		'$TARGET_WORKDIR/florestad.pid' 180 '$TARGET_WORKDIR/watchdog.pid' \
		</dev/null >>'$TARGET_WORKDIR/watchdog.log' 2>&1 &" ||
		warn "could not start the target watchdog"

	start_metrics_tunnel
	start_metrics_scraper
	window_open run

	if [ "$METRICS_BUILT" = "true" ]; then
		local waited=0
		while [ "$waited" -lt 120 ]; do
			curl -sS --max-time 3 \
				"http://127.0.0.1:$LOCAL_METRICS_PORT$METRICS_PATH" >/dev/null 2>&1 && break
			sleep 5
			waited=$((waited + 5))
		done
		if [ "$waited" -ge 120 ]; then
			warn "the metrics endpoint never answered; metrics.jsonl will be mostly failures"
		else
			log "metrics endpoint answering after ${waited}s"
		fi
	fi

	start_profiler
	progress_loop
	window_close run
}

progress_loop() {
	local start_ms height last_height="" last_ms="" blocks_per_s watts
	local tick=0
	start_ms="$(now_ms)"
	local deadline_ms=0
	[ -n "$DURATION" ] && deadline_ms=$((start_ms + DURATION_SECS * 1000))

	while :; do
		if [ "$INTERRUPTED" -eq 1 ]; then
			log "interrupted; moving to teardown"
			return 0
		fi

		# The node dying is a result, not a crash of the harness: record
		# it and let teardown work out whether the state is usable.
		tick=$((tick + 1))
		if [ $((tick % 3)) -eq 0 ] &&
			tsh "[ -s '$TARGET_WORKDIR/florestad.exit' ]" 2>/dev/null; then
			FLORESTAD_EXIT="$(tsh "cat '$TARGET_WORKDIR/florestad.exit'")"
			RUN_ABORTED=1
			log "florestad exited on its own with status $FLORESTAD_EXIT"
			return 0
		fi

		height="$(current_height || true)"
		local now
		now="$(now_ms)"
		if [ -n "$height" ] && [ -n "$last_height" ] && [ "$now" -gt "$last_ms" ]; then
			blocks_per_s="$(awk -v a="$height" -v b="$last_height" \
				-v t="$((now - last_ms))" 'BEGIN{printf "%.2f", (a-b)*1000.0/t}')"
		else
			blocks_per_s="-"
		fi
		last_height="$height" last_ms="$now"

		watts="-"
		if [ "$POWER_METER" != "none" ] && [ -s "$RUN_DIR/power.raw" ]; then
			watts="$(tail -1 "$RUN_DIR/power.raw" | cut -d, -f4)"
		fi

		printf '\r  height %-9s  blocks/s %-6s  %sW  elapsed %ds    ' \
			"${height:-?}" "$blocks_per_s" "$watts" "$(((now - start_ms) / 1000))" >&2

		if [ -n "$UNTIL_HEIGHT" ] && [ -n "$height" ] &&
			[ "$height" -ge "$UNTIL_HEIGHT" ]; then
			printf '\n' >&2
			log "reached height $height (target $UNTIL_HEIGHT)"
			return 0
		fi
		if [ "$deadline_ms" -gt 0 ] && [ "$now" -ge "$deadline_ms" ]; then
			printf '\n' >&2
			log "duration $DURATION elapsed"
			return 0
		fi
		sleep 5
	done
}

# --- teardown --------------------------------------------------------
#
# The whole point of this phase is to be able to say, afterwards, which
# of two very different things happened: the node shut down and flushed
# its database, or the node died and the database is whatever was on
# disk at the time.  A run that cannot tell those apart can say nothing
# about persistence, and the report is required to say so.

teardown() {
	[ "$TEARDOWN_DONE" -eq 1 ] && return 0
	TEARDOWN_DONE=1
	phase teardown
	window_open shutdown

	if [ -z "$FLORESTAD_PID" ]; then
		log "florestad was never started; nothing to stop"
		CLEAN_SHUTDOWN="false"
		window_close shutdown
		return 0
	fi

	if [ -n "$FLORESTAD_EXIT" ]; then
		log "florestad had already exited with status $FLORESTAD_EXIT"
	else
		log "sending SIGINT to florestad (pid $FLORESTAD_PID), waiting up to 120s"
		tsh "kill -INT '$FLORESTAD_PID' 2>/dev/null" || true

		local waited=0
		while [ "$waited" -lt 120 ]; do
			if tsh "[ ! -d /proc/$FLORESTAD_PID ]" 2>/dev/null; then break; fi
			printf '\r  waiting for shutdown: %ds   ' "$waited" >&2
			sleep 3
			waited=$((waited + 3))
		done
		printf '\r%*s\r' 40 '' >&2

		if [ "$waited" -ge 120 ]; then
			warn "florestad did not exit within 120s of SIGINT; sending SIGKILL"
			tsh "kill -KILL '$FLORESTAD_PID' 2>/dev/null" || true
			sleep 2
		else
			log "florestad exited after ${waited}s"
		fi
		FLORESTAD_EXIT="$(tsh "cat '$TARGET_WORKDIR/florestad.exit' 2>/dev/null" || echo "")"
	fi

	# The log tail needs a moment to drain the final lines before the
	# channel is torn down; shutdown messages are exactly the lines a
	# post-mortem wants.
	sleep 3

	local saw_shutdown="no"
	grep -qa "Stopping node\|Shutting down node" "$RUN_DIR/florestad.log" 2>/dev/null &&
		saw_shutdown="yes"

	if [ "$FLORESTAD_EXIT" = "0" ] && [ "$saw_shutdown" = "yes" ]; then
		CLEAN_SHUTDOWN="true"
		log "clean shutdown: exit 0 and the shutdown sequence is in the log"
	else
		CLEAN_SHUTDOWN="false"
		warn "UNCLEAN SHUTDOWN (exit='${FLORESTAD_EXIT:-unknown}', shutdown logged=$saw_shutdown): every conclusion about persistence in this run is invalid"
	fi

	tsh "if [ -s '$TARGET_WORKDIR/watchdog.pid' ]; then
		kill -TERM \"\$(cat '$TARGET_WORKDIR/watchdog.pid')\" 2>/dev/null || true
	fi" || true

	DATADIR_BYTES_AFTER="$(tsh "du -sk '$DATADIR' 2>/dev/null | awk '{print \$1*1024}'" || echo 0)"
	DF_AFTER="$(tsh "df -k '$DATADIR' 2>/dev/null | tail -1" || echo "")"
	log "datadir: $((DATADIR_BYTES_BEFORE / 1048576)) MiB -> $((DATADIR_BYTES_AFTER / 1048576)) MiB"

	window_close shutdown
	restart_check
}

# Reads the state back.  A flush that "completed" but left a chainstate
# that reloads at the wrong height did not complete, and on a 32-bit
# target that is a live suspicion, not a hypothetical.
restart_check() {
	RESTART_HEIGHT=""
	RESTART_OK="skipped"
	local expected
	expected="$(current_height || true)"
	[ -n "$expected" ] || {
		log "no block was accepted this run; skipping the restart check"
		return 0
	}

	log "restarting florestad briefly to confirm the state reloads at height $expected"
	local cmd probe_log="$TARGET_WORKDIR/restart.log"
	cmd="$(florestad_argv)"
	local pid
	pid="$(tsh "sh '$TARGET_WORKDIR/run-florestad.sh' '$TARGET_WORKDIR/restart' \
		'$probe_log' $cmd" 2>/dev/null || echo "")"
	if [ -z "$pid" ]; then
		RESTART_OK="failed-to-start"
		warn "florestad would not restart after the run: the datadir may be damaged"
		return 0
	fi

	# Loading a flat chainstore takes ~20s on the slowest board here;
	# 180s is that with room to spare.
	local waited=0
	while [ "$waited" -lt 180 ]; do
		RESTART_HEIGHT="$(tsh "grep -a 'New tip!\|Loaded' '$probe_log' 2>/dev/null | tail -1 | sed -n 's/.*height=\([0-9]*\).*/\1/p'" || true)"
		[ -n "$RESTART_HEIGHT" ] && break
		if tsh "grep -qa 'Starting IBD\|Starting sync node' '$probe_log' 2>/dev/null"; then
			RESTART_HEIGHT="$(tsh "'$FLORESTA_CLI' -n '$NETWORK' getblockcount 2>/dev/null" || true)"
			[ -n "$RESTART_HEIGHT" ] && break
		fi
		sleep 5
		waited=$((waited + 5))
	done

	tsh "kill -INT '$pid' 2>/dev/null" || true
	sleep 5
	tsh "kill -KILL '$pid' 2>/dev/null" || true

	if [ -z "$RESTART_HEIGHT" ] || ! [[ "$RESTART_HEIGHT" =~ ^[0-9]+$ ]]; then
		RESTART_OK="inconclusive"
		warn "the restart probe never reported a usable height within 180s"
	elif [ "$RESTART_HEIGHT" -ge "$((expected - 10))" ]; then
		RESTART_OK="ok"
		log "state reloaded at height $RESTART_HEIGHT (expected ~$expected)"
	else
		RESTART_OK="regressed"
		warn "after restart the node is at height $RESTART_HEIGHT but reached $expected during the run: the flush did not persist everything"
	fi
}

# --- collect ---------------------------------------------------------

collect() {
	phase collect

	if measure_clock; then
		CLOCK_OFFSET_END_MS="$CLOCK_OFFSET_MS"
	else
		CLOCK_OFFSET_END_MS=""
	fi
	local drift=0
	if [ -n "$CLOCK_OFFSET_END_MS" ] && [ -n "$CLOCK_OFFSET_START_MS" ]; then
		drift=$((CLOCK_OFFSET_END_MS - CLOCK_OFFSET_START_MS))
		log "clock drift over the run: ${drift}ms"
	fi

	tsh "cat '$TARGET_WORKDIR/watchdog.log' 2>/dev/null" >"$RUN_DIR/watchdog.log" 2>/dev/null || true

	write_meta "$drift"

	log "assembling CSVs"
	python3 "$HARNESS_DIR/report/assemble.py" "$RUN_DIR" ||
		die "$EX_RUNFAIL" "could not assemble the run's CSVs"

	# The staging directory goes away, but only after everything in it
	# has been read back.
	tsh "rm -rf '$TARGET_WORKDIR'" || warn "could not clean $TARGET_WORKDIR on the target"

	log "artifacts in $RUN_DIR"
}

write_meta() {
	local drift="$1"
	local warnings_json
	warnings_json="$(printf '%s\n' "${PREFLIGHT_WARNINGS[@]+"${PREFLIGHT_WARNINGS[@]}"}" |
		jq -R . | jq -sc 'map(select(. != ""))')"

	jq -n \
		--arg run_id "$RUN_ID" \
		--argjson schema_version "$SCHEMA_VERSION" \
		--arg harness_version "$HARNESS_VERSION" \
		--arg harness_commit "${HARNESS_COMMIT:-unknown}" \
		--arg harness_dirty "${HARNESS_DIRTY:-unknown}" \
		--arg run_kind "$RUN_KIND" \
		--arg target "$TARGET" \
		--arg host "$HOST" \
		--arg arch "$(pget arch unknown)" \
		--arg uname "$TARGET_UNAME" \
		--arg kernel "$TARGET_KERNEL" \
		--arg os "$TARGET_OS" \
		--arg tz "$TARGET_TZ" \
		--arg network "$NETWORK" \
		--arg datadir "$DATADIR" \
		--arg florestad_path "$FLORESTAD_PATH" \
		--arg florestad_version "$FLORESTAD_VERSION" \
		--arg florestad_sha256 "$FLORESTAD_SHA256" \
		--arg florestad_md5 "$FLORESTAD_MD5" \
		--arg build_id "$BUILD_ID" \
		--argjson metrics_built "$METRICS_BUILT" \
		--arg cmdline "$(florestad_argv)" \
		--arg backfill "${BACKFILL:-default}" \
		--arg state_mode "$STATE_MODE" \
		--arg power_meter "$POWER_METER" \
		--argjson proc_interval_s "$PROC_INTERVAL" \
		--argjson scrape_interval_s "$SCRAPE_SECS" \
		--argjson clk_tck "$CLK_TCK" \
		--arg time_source "$TIME_SOURCE" \
		--argjson boot_epoch_ms "$BOOT_EPOCH_MS" \
		--argjson clock_offset_start_ms "${CLOCK_OFFSET_START_MS:-0}" \
		--argjson clock_offset_end_ms "${CLOCK_OFFSET_END_MS:-0}" \
		--argjson clock_drift_ms "$drift" \
		--argjson clock_rtt_ms "${CLOCK_RTT_MS:-0}" \
		--argjson clean_shutdown "$CLEAN_SHUTDOWN" \
		--arg florestad_exit "${FLORESTAD_EXIT:-}" \
		--arg restart_check "${RESTART_OK:-skipped}" \
		--arg restart_height "${RESTART_HEIGHT:-}" \
		--argjson run_aborted "$([ "$RUN_ABORTED" -eq 1 ] && echo true || echo false)" \
		--argjson interrupted "$([ "$INTERRUPTED" -eq 1 ] && echo true || echo false)" \
		--argjson datadir_before "${DATADIR_BYTES_BEFORE:-0}" \
		--argjson datadir_after "${DATADIR_BYTES_AFTER:-0}" \
		--argjson fs_free_before "${DATADIR_FS_FREE_BYTES:-0}" \
		--arg df_after "${DF_AFTER:-}" \
		--arg disk_device "$DISK_DEVICE" \
		--arg net_iface "$NET_IFACE" \
		--argjson baseline_secs "$BASELINE_SECS" \
		--argjson psi "$([ "${PSI_FLAG:-0}" = "1" ] && echo true || echo false)" \
		--arg profile_mode "$PROFILE_MODE" \
		--arg profile_freq "${PROFILE_FREQ:-}" \
		--arg sd_card "$NOTE_SD_CARD" \
		--arg psu "$NOTE_PSU" \
		--arg cable "$NOTE_CABLE" \
		--arg ambient_c "$NOTE_AMBIENT" \
		--argjson peers "$(printf '%s\n' "${CONNECT_PEERS[@]+"${CONNECT_PEERS[@]}"}" |
			jq -R . | jq -sc 'map(select(. != ""))')" \
		--argjson warnings "$warnings_json" \
		--argjson profile "$PROFILE_JSON" \
		'{
			run_id: $run_id,
			schema_version: $schema_version,
			run_kind: $run_kind,
			harness: {version: $harness_version, commit: $harness_commit, dirty: $harness_dirty},
			target: {
				name: $target, host: $host, arch: $arch, uname: $uname,
				kernel: $kernel, os: $os, tz: $tz,
				disk_device: $disk_device, net_interface: $net_iface,
				psi_available: $psi, clk_tck: $clk_tck, time_source: $time_source
			},
			florestad: {
				path: $florestad_path, version: $florestad_version,
				sha256: $florestad_sha256, md5: $florestad_md5,
				build_id: $build_id, metrics_feature: $metrics_built,
				cmdline: $cmdline, network: $network, datadir: $datadir,
				backfill: $backfill, exit_status: $florestad_exit
			},
			run: {
				state_mode: $state_mode, baseline_secs: $baseline_secs,
				proc_interval_s: $proc_interval_s,
				scrape_interval_s: $scrape_interval_s,
				power_meter: $power_meter, peers: $peers,
				profile_mode: $profile_mode, profile_freq_hz: $profile_freq,
				aborted: $run_aborted, interrupted: $interrupted
			},
			clock: {
				boot_epoch_ms: $boot_epoch_ms,
				offset_start_ms: $clock_offset_start_ms,
				offset_end_ms: $clock_offset_end_ms,
				drift_ms: $clock_drift_ms,
				rtt_ms: $clock_rtt_ms,
				offset_resolution_ms: 1000
			},
			persistence: {
				clean_shutdown: $clean_shutdown,
				restart_check: $restart_check,
				restart_height: $restart_height,
				datadir_bytes_before: $datadir_before,
				datadir_bytes_after: $datadir_after,
				fs_free_bytes_before: $fs_free_before,
				df_after: $df_after
			},
			bench_rig: {sd_card: $sd_card, psu: $psu, cable: $cable, ambient_c: $ambient_c},
			warnings: $warnings,
			target_profile: $profile
		}' >"$RUN_DIR/meta.json"
}

# --- report ----------------------------------------------------------

report() {
	phase report
	python3 "$HARNESS_DIR/report/build-report.py" "$RUN_DIR" ||
		die "$EX_RUNFAIL" "report generation failed"
	log "report written to $RUN_DIR/report.md"
}

# --- profiling -------------------------------------------------------
#
# A profile run answers "where does the time go", which is a different
# question from "how much time is there", and it must not be asked at
# the same time: on a board with one or two cores the sampler perturbs
# exactly the code it is sampling.  Hence run_kind, and hence the
# refusal to combine --profile perf with a power meter.
#
# The stacks are folded on the target.  perf.data is architecture- and
# version-specific; folded text is neither, so the host never has to
# decode another machine's binary format.
#
# NOT YET EXERCISED ON HARDWARE: the only board in this lab has no perf
# (see targets/rasp-pi-zero.nix), so this path is written from the perf
# documentation and has never run end to end.  It fails closed --
# preflight refuses --profile perf on a profiler=none target rather than
# producing an empty flamegraph.

PROFILE_FREQ="${BENCH_PROFILE_FREQ:-97}"

start_profiler() {
	[ "$PROFILE_MODE" = "perf" ] || return 0
	log "sampling at ${PROFILE_FREQ}Hz (prime, to avoid locking step with periodic work)"
	tsh "nohup perf record -F '$PROFILE_FREQ' -g --pid '$FLORESTAD_PID' \
		-o '$TARGET_WORKDIR/perf.data' </dev/null >'$TARGET_WORKDIR/perf.err' 2>&1 &
		echo \$! > '$TARGET_WORKDIR/perf.pid'" ||
		warn "perf record would not start"
}

collect_profile() {
	[ "$PROFILE_MODE" = "perf" ] || return 0
	phase profile
	mkdir -p "$RUN_DIR/profile"

	tsh "if [ -s '$TARGET_WORKDIR/perf.pid' ]; then
		kill -INT \"\$(cat '$TARGET_WORKDIR/perf.pid')\" 2>/dev/null || true
	fi" || true
	sleep 5

	log "folding stacks on the target (perf script + stackcollapse)"
	tsh "cat > '$TARGET_WORKDIR/stackcollapse.awk'" \
		<"$HARNESS_DIR/remote/stackcollapse.awk" || true
	tsh "perf script -i '$TARGET_WORKDIR/perf.data' -F comm,pid,tid,time,ip,sym,dso 2>/dev/null |
		awk -f '$TARGET_WORKDIR/stackcollapse.awk'" \
		>"$RUN_DIR/profile/folded-timed.txt" 2>>"$RUN_DIR/profile/fold.err" ||
		warn "folding stacks failed; see profile/fold.err"

	if [ ! -s "$RUN_DIR/profile/folded-timed.txt" ]; then
		warn "no folded stacks were produced"
		return 0
	fi

	python3 "$HARNESS_DIR/report/slice-profile.py" "$RUN_DIR" ||
		warn "slicing the profile by window failed"

	if command -v inferno-flamegraph >/dev/null 2>&1; then
		local f
		for f in "$RUN_DIR"/profile/folded*.txt; do
			[ -s "$f" ] || continue
			inferno-flamegraph <"$f" >"${f%.txt}.svg" 2>/dev/null ||
				warn "could not render $(basename "$f")"
		done
		log "flamegraphs rendered on the host"
	else
		warn "inferno-flamegraph not on PATH; folded stacks kept, no SVG"
	fi
}

# --- lifecycle -------------------------------------------------------

INTERRUPTED=0

on_interrupt() {
	INTERRUPTED=1
	printf '\n' >&2
	log "interrupt received: stopping the target cleanly before exiting"
}

cleanup() {
	local code=$?
	trap - EXIT INT TERM HUP

	# An interrupt during the run must still leave the board idle; this
	# is the difference between a bad run and a board quietly pegged at
	# 100% until someone notices tomorrow.
	if [ -n "$FLORESTAD_PID" ] && [ "$TEARDOWN_DONE" -eq 0 ]; then
		PHASE="cleanup"
		teardown || true
	fi
	stop_collectors
	[ -n "$CTL_PATH" ] && ssh -o ControlPath="$CTL_PATH" -O exit "$HOST" 2>/dev/null || true
	[ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
	exit "$code"
}

dry_run_plan() {
	cat <<EOF
bench-node --dry-run: this is exactly what a real run would do.

  target profile   $TARGETS_DIR/$TARGET.json
  target host      $HOST
  architecture     $(pget arch unknown)
  datadir          $DATADIR
  network          $NETWORK
  stop condition   $([ -n "$UNTIL_HEIGHT" ] && echo "height >= $UNTIL_HEIGHT" || echo "after $DURATION")
  datadir state    $STATE_MODE
  backfill         ${BACKFILL:-florestad default}
  power meter      $POWER_METER$([ "$POWER_METER" != none ] && echo " (driver: $HARNESS_DIR/power/$POWER_METER.sh)")
  run kind         $RUN_KIND$([ "$PROFILE_MODE" = perf ] && echo " at ${PROFILE_FREQ}Hz")
  proc sampling    every ${PROC_INTERVAL}s
  metrics scrape   every ${SCRAPE_SECS}s from 127.0.0.1:$METRICS_PORT$METRICS_PATH
  baselines        ${BASELINE_SECS}s idle before and after
  artifacts        $OUT_DIR/<timestamp>-<commit>/

  on the target it would:
    - stage collect-proc.sh, run-florestad.sh and watchdog.sh in /tmp/bench-node-<run>
    - read /proc, /sys and $DATADIR
    - run: $(florestad_argv)
    - remove the staging directory afterwards
    - install nothing, and write nothing outside $DATADIR and /tmp

  preflight would refuse the run if:
    - the target clock differs from this host's by more than 2s
    - florestad lacks the metrics feature$([ "$ALLOW_NO_METRICS" -eq 1 ] && echo " (waived by --allow-no-metrics)")
    - a florestad is already running on $DATADIR
    - the profile's required tools are missing
    - less than $((MIN_FREE_BYTES / 1048576)) MiB is free where the datadir lives
$([ "$PROFILE_MODE" = perf ] && echo "    - the target has no perf (this profile declares profiler=$PROFILER)")
EOF
}

main() {
	case "${1:-}" in
	export)
		shift
		exec python3 "$HARNESS_DIR/report/export.py" "$@"
		;;
	serve-prom)
		shift
		exec python3 "$HARNESS_DIR/report/serve-prom.py" "$@"
		;;
	esac

	parse_args "$@"
	load_profile

	RUN_KIND="bench"
	if [ "$PROFILE_MODE" = "perf" ]; then
		RUN_KIND="profile"
		if [ "$POWER_METER" != "none" ]; then
			die "$EX_USAGE" \
				"--profile perf cannot share a run with a power meter: the sampler distorts the very cost it is measuring. Run them separately."
		fi
	fi

	TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bench-node.XXXXXX")"
	CTL_PATH="$TMP_DIR/ssh-ctl"
	init_ssh_opts

	if [ "$DRY_RUN" -eq 1 ]; then
		# The single permitted touch: prove the address resolves and the
		# key works, then describe everything else instead of doing it.
		if tsh true 2>/dev/null; then
			echo "ssh $HOST: ok" >&2
		else
			echo "ssh $HOST: FAILED (a real run would exit $EX_UNREACHABLE)" >&2
		fi
		dry_run_plan
		rm -rf "$TMP_DIR"
		exit "$EX_OK"
	fi

	# The invoking working tree, not $HARNESS_DIR: under `nix run` the
	# latter is an immutable store path with no git history at all.
	HARNESS_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
	if git diff --quiet 2>/dev/null; then
		HARNESS_DIRTY="clean"
	else
		HARNESS_DIRTY="dirty"
	fi

	RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$HARNESS_COMMIT"
	RUN_DIR="$OUT_DIR/$RUN_ID"
	if [ -e "$RUN_DIR" ]; then
		RUN_ID="$RUN_ID-$$"
		RUN_DIR="$OUT_DIR/$RUN_ID"
	fi
	mkdir -p "$RUN_DIR"
	LOG_FILE="$RUN_DIR/harness.log"
	: >"$RUN_DIR/windows.raw"
	TARGET_WORKDIR="/tmp/bench-node-$RUN_ID"

	# HUP matters as much as INT here: when the harness is itself driven
	# over SSH, a dropped connection arrives as SIGHUP, and without this
	# the target would be left with a node running and no teardown.
	trap on_interrupt INT TERM HUP
	trap cleanup EXIT

	log "bench-node $HARNESS_VERSION, run $RUN_ID"
	log "target=$TARGET host=$HOST network=$NETWORK datadir=$DATADIR kind=$RUN_KIND"

	preflight
	upload_remote_scripts

	start_power_meter
	start_proc_collector

	baseline baseline_pre
	if [ "$INTERRUPTED" -eq 0 ]; then
		run_phase
	fi
	teardown
	collect_profile
	baseline baseline_post
	stop_collectors

	collect
	report

	local exit_code="$EX_OK"
	if [ "$RUN_ABORTED" -eq 1 ] && [ "${FLORESTAD_EXIT:-0}" != "0" ]; then
		log "florestad failed during the run (exit ${FLORESTAD_EXIT})"
		exit_code="$EX_RUNFAIL"
	elif [ "$CLEAN_SHUTDOWN" != "true" ]; then
		log "teardown was not clean; persistence conclusions are void for this run"
		exit_code="$EX_TEARDOWN"
	fi

	echo >&2
	echo "run complete: $RUN_DIR" >&2
	echo "report:       $RUN_DIR/report.md" >&2
	TEARDOWN_DONE=1
	exit "$exit_code"
}

main "$@"
