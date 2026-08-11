#!/bin/bash
# Boot entry point for a field node: put the radio(s) into monitor mode, then
# run the whole pipeline -- capture, continuous enrichment, and the live display
# -- each in its own detached screen.
#
# Setting monitor mode is the piece capture.sh deliberately does NOT do.
# capture.sh refuses an interface that is not already in monitor mode --
# reconfiguring an operator's NICs unasked is the wrong default for a tool run
# by hand. But on a headless node powered on by a crontab there is no operator
# to run `airmon-ng` first, which is why capture only ever "worked after
# airodump-ng was run": something had to create the monitor interface. start.sh
# is that something.
#
# Meant for an unattended node:
#
#   sudo crontab -e
#   @reboot /home/pi/probeprint2/start.sh
#
# Run as root -- airmon-ng and monitor mode require it.
#
# Reads from .env:
#   INF          the monitor interface(s) to capture on, iface[:channel] list
#                (see .env.example). "wlan1mon" etc.
#   CAPTURE_PHYS optional: the physical interface(s) to switch into monitor mode
#                first, space separated. Defaults to each INF interface with a
#                trailing "mon" stripped ("wlan1mon" -> "wlan1"), which is the
#                airmon-ng naming convention.

set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1
[ -f .env ] && source .env

PP_LOG_DIR=${PP_LOG_DIR:-logs}
mkdir -p "$PP_LOG_DIR" 2>/dev/null; chmod 700 "$PP_LOG_DIR" 2>/dev/null
log="$PP_LOG_DIR/start.log"

say () { echo "$(date +'%F %T') $*" | tee -a "$log"; }

[ -n "${INF:-}" ] || { say "INF is not set in .env -- nothing to capture on"; exit 1; }

command -v airmon-ng >/dev/null 2>&1 || {
	say "airmon-ng not found (install aircrack-ng) -- cannot set monitor mode"; exit 1; }

# Derive the physical interfaces to enable if not stated. INF tokens are
# monitor-interface names, optionally iface:channel; strip the channel, then a
# trailing "mon".
if [ -z "${CAPTURE_PHYS:-}" ]; then
	CAPTURE_PHYS=""
	for token in $INF; do
		iface=${token%%:*}
		CAPTURE_PHYS="${CAPTURE_PHYS:+$CAPTURE_PHYS }${iface%mon}"
	done
fi

# airmon-ng check kill stops NetworkManager/wpa_supplicant, which otherwise
# yank the card back out of monitor mode moments after it is set. This is
# exactly what makes a hand-run capture flaky until airodump-ng (which does the
# same) has been run.
say "stopping interfering services (airmon-ng check kill)"
airmon-ng check kill >>"$log" 2>&1

for phys in $CAPTURE_PHYS; do
	if [ "$(iw dev "$phys" info 2>/dev/null | awk '/type/{print $2}')" = "monitor" ]; then
		say "$phys already in monitor mode"
		continue
	fi
	say "putting $phys into monitor mode"
	airmon-ng start "$phys" >>"$log" 2>&1
done

# --- launch the three long-running jobs, each in its own detached screen -----
#
# A field node runs the whole pipeline on one board: capture, continuous
# enrichment, and the live display. Each goes in a named detached screen so an
# operator who joins the node's hostapd AP and SSHes in can attach to any of
# them (screen -r display) and detach again without stopping it.
#
# screen, not backgrounded jobs: start.sh is a @reboot crontab entry and exits
# immediately, but the work must outlive it. A detached screen is owned by no
# terminal and survives the parent exiting.
command -v screen >/dev/null 2>&1 || { say "screen not installed -- cannot launch jobs"; exit 1; }

# start_screen <name> <command...> -- start a detached screen unless one of that
# name is already up (so re-running start.sh does not stack duplicates).
start_screen () {
	local name=$1; shift
	if screen -ls 2>/dev/null | grep -q "\.$name[[:space:]]"; then
		say "screen '$name' already running, leaving it"
		return
	fi
	say "starting '$name' in a detached screen"
	screen -dmS "$name" "$@"
}

# timesync: the node has no RTC, so correct the clock whenever it gets a
# network -- before wrong timestamps corrupt the primary key. First in the list
# so it runs the moment connectivity appears. Needs root, which start.sh has.
start_screen timesync ./analysis-scripts/timesync.sh --loop "${TIMESYNC_INTERVAL:-300}"

# capture: monitor mode is set above, so capture.sh's preflight passes.
start_screen capture ./capture.sh

# analysis: analysis.sh runs the passes once and exits, so loop it -- new frames
# keep arriving and want enriching. ANALYSIS_INTERVAL seconds between sweeps
# (default 60). GEO_LOCS_DIR is inherited from .env if set.
start_screen analysis bash -c \
	'while true; do ./analysis.sh; sleep "${ANALYSIS_INTERVAL:-60}"; done'

# display: the live operator view. Attach with `screen -r display`.
start_screen display ./display.sh

say "field node up: timesync + capture + analysis + display in detached screens"
say "attach with: screen -r timesync | capture | analysis | display"
