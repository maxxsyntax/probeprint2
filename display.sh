#!/usr/bin/bash
# Operator display: who is in range, and what their device says about them.
#
# Device-centric rather than SSID-centric. The old view listed network names as
# they arrived, which meant one person carrying eight preferred networks
# appeared as eight unrelated lines, and a phone that rotated its MAC mid-window
# appeared twice. Now there is one block per device, nearest first, with
# everything the pipeline knows about that fingerprint assembled from its
# preferred network list.
#
# What is shown, and where it comes from:
#   Name        ssid_intel.is_name        (check_name)
#   Household   OTHER_HOUSEHOLD           (recategorize_functions.sh)
#   Employer    BIZ_STAFF / INDUSTRY_ORG / BIZ_COWORK / BIZ_INSTITUTION
#   Language    ssid_intel.lang           (language_functions.sh)
#   Home ISP    cpe_isp + cpe_country     (lists/cpe_isp.txt, country scope only)
#   Places      ssid_intel.location       (WiGLE)
#   Airports    ssid_intel.is_airport     (check_airport)
#   Hotels      BIZ_HOTEL / TRAVEL
#   Eateries    BIZ_EATERY
#   Rare nets   rarity > 15               (rarity_functions.sh)
#
# Usage:
#   ./display.sh                 live in-range view, refreshing every few seconds
#                                (the default; ^C to quit)
#   ./display.sh recent [secs]   one-shot: everything seen in the last N seconds,
#                                grouped by the device behind it
#   ./display.sh devices         one-shot: roster of every device, worst-
#                                corroborated first so a bad merge is visible
#   ./display.sh device <id|alias>   one-shot: one device's full profile and its
#                                preferred network list, rarest entry first
#
# The three one-shot views print once and exit, so they are safe to pipe or
# redirect; only the default live view loops.
#
# Enrichment is not run from here. Populate it first with the standalone passes
# -- categorize, name, airport, rarity, recategorize, language, seqgraph -- or
# the profile will be mostly empty.
#set -x
source ./display-scripts/display_functions.sh

[ -f .env ] && source .env
DISPLAY_DB_ARGS=${DISPLAY_DB_ARGS:--u pi -h 127.0.0.1}

WINDOW=${DISPLAY_WINDOW:-30}
REFRESH=${DISPLAY_REFRESH:-5}

usage () {
	cat >&2 <<EOF
usage: $0 [command]
  (no command)        live in-range view, refreshing every ${REFRESH}s (^C to quit)
  recent [seconds]    everything seen in the last N seconds, grouped by device
  devices             roster of every device, worst-corroborated first
  device <id|alias>   one device's full profile and preferred network list
EOF
}

live_view () {
	clear
	local start_date
	start_date=$(date +%s)
	while true; do
		clear
		# Every counter is scoped to the same window the body reports on.
		# 'frames' used to count from the moment display started, so it read 0
		# on a busy channel for the first refresh and never agreed with what was
		# on screen underneath it.
		local wcut
		wcut=$(date +%s --date="$WINDOW sec ago")
		printf 'probeprint2   in range (last %ss)   devices: %s   suspect merges: %s   frames: %s   ungrouped: %s\n' \
			"$WINDOW" \
			"$(dq <<< "select count(*) from devices;")" \
			"$(dq <<< "select count(*) from devices where confidence='low';")" \
			"$(dq <<< "select count(*) from ssid where cast(time as decimal(20,7)) > $wcut;")" \
			"$(dq <<< "select count(*) from ssid where cast(time as decimal(20,7)) > $wcut and device_id is null;")"
		printf '%s\n\n' "--------------------------------------------------------------------------"

		display_inrange "$WINDOW"

		sleep "$REFRESH"
	done
}

case "${1:-live}" in
	live)
		live_view
		;;
	recent)
		display_recent "${2:-$WINDOW}"
		;;
	devices)
		display_devices
		;;
	device)
		if [ -z "${2:-}" ]; then
			echo "device: needs an id or alias" >&2
			usage
			exit 1
		fi
		display_device "$2"
		;;
	-h|--help|help)
		usage
		;;
	*)
		echo "unknown command: $1" >&2
		usage
		exit 1
		;;
esac
