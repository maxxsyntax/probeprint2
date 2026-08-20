#!/bin/bash
# Raspberry Pi field-node boot entry point.
#
# Same job as the repo-root ../../start.sh (put the radio into monitor mode, then
# run the pipeline in detached screens) BUT tailored for the Pi: it starts only
# **timesync + capture**, and deliberately does NOT start the **analysis** or
# **display** screens.
#
# Why: the continuous analysis.sh loop (and, to a lesser extent, the display
# loop) drives a Pi to its ~85C thermal limit, so the board throttles and drops
# off the network. On a Pi, enrich and view OFF-NODE: pull the captures to a
# workstation and run ./analysis.sh and ./display.sh there. Non-Pi nodes keep
# using the repo-root start.sh, which starts the FULL pipeline (that file is
# intentionally left unchanged; the Pi exception lives only here in platforms/pi).
#
# Install as the Pi's root @reboot entry INSTEAD of the repo-root start.sh:
#   sudo crontab -e
#   @reboot /home/pi/probeprint2/platforms/pi/start.sh >> /home/pi/probeprint2/logs/start.log 2>&1
#
# Reads INF / CAPTURE_PHYS / TIMESYNC_INTERVAL from ../../.env, exactly as start.sh.

set -u
# @reboot cron runs with a minimal PATH; /usr/sbin (airmon-ng, iw) must be on it.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Run from the repo root so capture.sh, analysis-scripts/, .env and logs/ resolve
# relatively, identically to the repo-root start.sh.
cd "$(dirname "$(readlink -f "$0")")/../.." || exit 1
[ -f .env ] && source .env

PP_LOG_DIR=${PP_LOG_DIR:-logs}
mkdir -p "$PP_LOG_DIR" 2>/dev/null; chmod 700 "$PP_LOG_DIR" 2>/dev/null
log="$PP_LOG_DIR/start.log"
say () { echo "$(date +'%F %T') [pi] $*" | tee -a "$log"; }

[ -n "${INF:-}" ] || { say "INF is not set in .env -- nothing to capture on"; exit 1; }
command -v airmon-ng >/dev/null 2>&1 || { say "airmon-ng not found (install aircrack-ng) -- cannot set monitor mode"; exit 1; }
command -v screen    >/dev/null 2>&1 || { say "screen not installed -- cannot launch jobs"; exit 1; }

# Derive the physical interfaces to enable if not stated (mirror start.sh): INF
# tokens are monitor-interface names, optionally iface:channel; strip the channel,
# then a trailing "mon".
if [ -z "${CAPTURE_PHYS:-}" ]; then
	CAPTURE_PHYS=""
	for token in $INF; do
		iface=${token%%:*}
		CAPTURE_PHYS="${CAPTURE_PHYS:+$CAPTURE_PHYS }${iface%mon}"
	done
fi

# airmon-ng check kill stops NetworkManager/wpa_supplicant so they do not yank the
# card back out of monitor mode.
say "stopping interfering services (airmon-ng check kill)"
airmon-ng check kill >>"$log" 2>&1
for phys in $CAPTURE_PHYS; do
	if [ "$(iw dev "$phys" info 2>/dev/null | awk '/type/{print $2}')" = "monitor" ]; then
		say "$phys already in monitor mode"; continue
	fi
	say "putting $phys into monitor mode"
	airmon-ng start "$phys" >>"$log" 2>&1
done

# start_screen <name> <command...> -- start a detached screen unless one of that
# name is already up (so re-running does not stack duplicates). Same as start.sh.
start_screen () {
	local name=$1; shift
	if screen -ls 2>/dev/null | grep -q "\.$name[[:space:]]"; then
		say "screen '$name' already running, leaving it"; return
	fi
	say "starting '$name' in a detached screen"
	screen -dmS "$name" "$@"
}

# timesync: load-bearing on a Pi (no RTC) -- correct the clock before wrong
# timestamps corrupt the primary key. First, so it runs the moment a network appears.
start_screen timesync ./analysis-scripts/timesync.sh --loop "${TIMESYNC_INTERVAL:-300}"

# capture: monitor mode is set above, so capture.sh's preflight passes.
start_screen capture ./capture.sh

# analysis + display: intentionally NOT started on the Pi (thermal, see header).
# Run ./analysis.sh and ./display.sh off-node against the pulled captures.

say "pi field node up: timesync + capture in detached screens (analysis + display run OFF-NODE to avoid overheating)"
say "attach with: screen -r timesync | capture   (enrich/view off-node: ./analysis.sh, ./display.sh)"
