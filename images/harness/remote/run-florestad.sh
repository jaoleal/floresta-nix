#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Starts florestad detached from the SSH session that launched it, and
# records the one fact a post-mortem cannot reconstruct: its exit code.
#
# Why not just `ssh target florestad ...`?  Because a command run that
# way dies with the connection, and this harness must survive a flaky
# USB link long enough to shut the node down cleanly.  Instead the node
# is reparented to init here, and the host watches it through the log.
#
# Usage: run-florestad.sh <workdir> <logfile> <command...>

set -u

WORKDIR="$1"
LOGFILE="$2"
shift 2

mkdir -p "$WORKDIR"
PIDFILE="$WORKDIR/florestad.pid"
EXITFILE="$WORKDIR/florestad.exit"
rm -f "$PIDFILE" "$EXITFILE"

# The supervisor: start the node, publish its pid, wait, publish the
# status.  It runs in a detached subshell so that this script -- and the
# SSH command that invoked it -- returns immediately.
#
# `trap '' HUP` before anything else is what makes the node outlive the
# connection that started it: the disposition is inherited by florestad,
# so a dropped SSH link cannot kill it mid-write. Stopping it stays the
# harness's job (SIGINT from teardown) or the watchdog's.
(
	trap "" HUP
	"$@" >"$LOGFILE" 2>&1 &
	child=$!
	echo "$child" >"$PIDFILE"
	wait "$child"
	status=$?
	echo "$status" >"$EXITFILE"
	# The pidfile outliving the process would make the collector
	# sample a recycled pid.
	rm -f "$PIDFILE"
) </dev/null >/dev/null 2>&1 &

# Wait for the pid to appear, so the caller can rely on it existing.
# Ten seconds is generous: this is a fork, not a chain load.
i=0
while [ $i -lt 100 ]; do
	if [ -s "$PIDFILE" ]; then
		cat "$PIDFILE"
		exit 0
	fi
	if [ -s "$EXITFILE" ]; then
		echo "florestad exited immediately with status $(cat "$EXITFILE")" >&2
		exit 1
	fi
	sleep 0.1
	i=$((i + 1))
done

echo "florestad did not report a pid within 10s" >&2
exit 1
