#!/bin/bash
# Correct the clock whenever the node has a network.
#
# A capture node (Raspberry Pi) has no battery-backed real-time clock: powered
# on with no network it resumes from a stale date, and every frame captured
# before the clock is right is stamped with the wrong epoch. Since ssid.time is
# the primary key and every time-based pass (seqgraph, fidelity, "seen before")
# reads it, a wrong clock silently corrupts the collection -- see
# ../platforms/pi/README.md.
#
# So: whenever the node can reach the internet, pull the real time from NTP. Run
# it periodically -- from cron, or with --loop -- so a node that comes online
# hours into a capture gets corrected as soon as it does.
#
# Needs root to set the clock. Read-only against the database (it only reads the
# newest ssid timestamp, to report how far off the clock had drifted).
#
# Usage:
#   ./analysis-scripts/timesync.sh              check once; sync if online
#   ./analysis-scripts/timesync.sh --loop [sec] check every sec (default 300)
#   ./analysis-scripts/timesync.sh --check      report online/clock state only
[ -f .env ] && source .env
source ./analysis-scripts/location_functions.sh    # test_online

PP_LOG_DIR=${PP_LOG_DIR:-logs}
mkdir -p "$PP_LOG_DIR" 2>/dev/null
log="$PP_LOG_DIR/timesync.log"
# NTP servers to try, override in .env.
NTP_SERVERS=${NTP_SERVERS:-"pool.ntp.org time.cloudflare.com time.google.com"}

say () { echo "$(date +'%F %T') $*" | tee -a "$log"; }

# Set the clock from NTP, by whatever tool the node has. Returns 0 on success.
sync_clock () {
	local before after server
	before=$(date +%s)

	if command -v ntpdate >/dev/null 2>&1; then
		for server in $NTP_SERVERS; do
			ntpdate -u "$server" >>"$log" 2>&1 && break
		done
	elif command -v sntp >/dev/null 2>&1; then
		for server in $NTP_SERVERS; do
			sntp -sS "$server" >>"$log" 2>&1 && break
		done
	elif command -v chronyc >/dev/null 2>&1; then
		chronyc -a makestep >>"$log" 2>&1
	elif command -v timedatectl >/dev/null 2>&1; then
		# systemd-timesyncd: nudge it and wait for it to land.
		timedatectl set-ntp true >>"$log" 2>&1
		local i
		for i in $(seq 1 12); do
			[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] && break
			sleep 1
		done
	else
		say "no NTP client found (ntpdate/sntp/chronyc/timedatectl) -- cannot set clock"
		return 1
	fi

	after=$(date +%s)
	# How far the clock jumped is how wrong it was -- worth logging, because a
	# large jump means frames were captured under a bad clock and need scrutiny.
	local jump=$(( after - before ))
	[ "$jump" -lt 0 ] && jump=$(( -jump ))
	if [ "$jump" -gt 5 ]; then
		say "clock corrected by ${jump}s -- frames captured before now may carry a wrong timestamp"
	else
		say "clock already accurate (moved ${jump}s)"
	fi
	return 0
}

report_state () {
	local newest
	newest=$(mysql -N probeprint -e \
		"select ifnull(from_unixtime(max(cast(time as decimal(20,7)))),'none') from ssid;" 2>/dev/null)
	say "now=$(date '+%F %T')  online=$(test_online && echo yes || echo no)  newest capture=$newest"
}

run_once () {
	if test_online; then
		say "online -- syncing clock"
		sync_clock
	else
		say "offline -- clock left as is (no reference available)"
	fi
}

case "${1:-}" in
	--check) report_state ;;
	--loop)
		interval=${2:-300}
		say "timesync loop started, every ${interval}s"
		while true; do run_once; sleep "$interval"; done ;;
	"")      run_once ;;
	*)       echo "usage: $0 [--loop [seconds]|--check]" >&2; exit 1 ;;
esac
