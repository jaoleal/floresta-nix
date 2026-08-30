# shellcheck shell=sh
# Shared helpers for the florestaos init scripts and tools.
# Sourced, never executed.

RUN_DIR=/run/florestaos
CONF_FILE=/boot/florestaos.conf
EFFECTIVE_CONF="$RUN_DIR/config"
WARNINGS_FILE="$RUN_DIR/config-warnings"
STATE_DIR=/data/florestaos
RESULTS_DIR=/boot/results

# florestad is always told exactly where to listen, so the sampler and
# floresta-cli never have to guess per-network default ports.
RPC_HOST=http://127.0.0.1:8332

log() {
	echo "florestaos: $*"
}

# --- configuration ---------------------------------------------------
#
# The file is `key=value`, parsed with a whitelist: each known key is
# looked up individually and validated; anything malformed falls back
# to its default and leaves a warning.  A config file that is missing
# entirely (or an unreadable FAT) yields a fully-default node — the
# box must never fail to boot because of a typo made on a laptop.

conf_raw() {
	# $1: key.  Last occurrence wins, comments and CR (FAT files get
	# edited on Windows) stripped.
	[ -r "$CONF_FILE" ] || return 1
	sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF_FILE" |
		tr -d '\r' | sed 's/[[:space:]]*#.*//;s/[[:space:]]*$//' |
		tail -n 1 | grep .
}

warn_cfg() {
	echo "$*" >>"$WARNINGS_FILE"
	log "config: $*"
}

# conf_get <key> <default> <validator-regex>
conf_get() {
	_v="$(conf_raw "$1")" || {
		echo "$2"
		return
	}
	if echo "$_v" | grep -qxE "$3"; then
		echo "$_v"
	else
		warn_cfg "$1='$_v' is invalid, using default '$2'"
		echo "$2"
	fi
}

# Parse everything once and persist the result as a sourceable file;
# later scripts (and the sampler) just source it.
parse_config() {
	mkdir -p "$RUN_DIR"
	: >"$WARNINGS_FILE"

	CFG_MODE=$(conf_get mode node 'node|bench-micro|bench-ibd|bench-assume')
	CFG_NETWORK=$(conf_get network signet 'bitcoin|signet|testnet4')
	CFG_ASSUME_UTREEXO=$(conf_get assume_utreexo true 'true|false')
	CFG_ASSUME_VALID=$(conf_get assume_valid hardcoded 'hardcoded|0|[0-9a-fA-F]{64}')
	CFG_IBD_STOP_HEIGHT=$(conf_get ibd_stop_height 0 '[0-9]{1,9}')
	CFG_IBD_TIME_BUDGET_HOURS=$(conf_get ibd_time_budget_hours 48 '[0-9]{1,4}')
	CFG_SAMPLE_INTERVAL_SECS=$(conf_get sample_interval_secs 60 '[1-9][0-9]{0,5}')
	CFG_RESULTS_SYNC_EVERY=$(conf_get results_sync_every 5 '[1-9][0-9]{0,3}')
	CFG_BENCH_END=$(conf_get bench_end poweroff 'poweroff|idle')
	CFG_USB_GADGET=$(conf_get usb_gadget ecm 'ecm|rndis')
	CFG_USB_IP=$(conf_get usb_ip 10.7.0.2/24 '[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}')
	CFG_USB_GATEWAY=$(conf_get usb_gateway 10.7.0.1 '[0-9]{1,3}(\.[0-9]{1,3}){3}')
	CFG_DNS=$(conf_get dns 1.1.1.1 '[0-9]{1,3}(\.[0-9]{1,3}){3}')
	CFG_NTP_SERVER=$(conf_get ntp_server pool.ntp.org '[A-Za-z0-9._-]+')
	CFG_ZRAM_MB=$(conf_get zram_mb 256 '[0-9]{1,4}')
	# Free-form escape hatch, deliberately unvalidated.
	CFG_EXTRA_FLAGS="$(conf_raw extra_flags || true)"

	{
		echo "# effective florestaos config, generated at boot"
		for k in MODE NETWORK ASSUME_UTREEXO ASSUME_VALID IBD_STOP_HEIGHT \
			IBD_TIME_BUDGET_HOURS SAMPLE_INTERVAL_SECS RESULTS_SYNC_EVERY \
			BENCH_END USB_GADGET USB_IP USB_GATEWAY DNS NTP_SERVER ZRAM_MB; do
			eval "echo CFG_$k=\\'\$CFG_$k\\'"
		done
		echo "CFG_EXTRA_FLAGS='$CFG_EXTRA_FLAGS'"
	} >"$EFFECTIVE_CONF"
}

load_config() {
	# shellcheck disable=SC1090
	. "$EFFECTIVE_CONF"
}

# --- time persistence ------------------------------------------------
#
# No RTC on this board.  Until NTP reaches the internet, the best
# approximation of "now" is "slightly after the last time we knew".
# Persisted by the sampler, the clock script and clean shutdowns.

persist_clock() {
	[ -d "$STATE_DIR" ] && date -u +%s >"$STATE_DIR/last-timestamp" 2>/dev/null
}

restore_clock() {
	[ -r "$STATE_DIR/last-timestamp" ] || return 0
	saved=$(cat "$STATE_DIR/last-timestamp")
	now=$(date -u +%s)
	if [ "$saved" -gt "$now" ] 2>/dev/null; then
		date -u -s "@$saved" >/dev/null 2>&1 &&
			log "clock restored from persisted timestamp ($saved)"
	fi
}

# --- results mailbox -------------------------------------------------

# Copy a file into /boot/results and push it to the card.  `sync` on
# the whole FS is fine here: the FAT is tiny and mounted with `flush`.
sync_to_results() {
	[ -d "$RESULTS_DIR" ] || mkdir -p "$RESULTS_DIR" 2>/dev/null || return 1
	cp -f "$1" "$RESULTS_DIR/" 2>/dev/null && sync
}

boot_stamp() {
	# One stable timestamp per boot for naming logs and CSVs.
	if [ ! -f "$RUN_DIR/boot-stamp" ]; then
		mkdir -p "$RUN_DIR"
		date -u +%Y%m%d-%H%M%S >"$RUN_DIR/boot-stamp"
	fi
	cat "$RUN_DIR/boot-stamp"
}
