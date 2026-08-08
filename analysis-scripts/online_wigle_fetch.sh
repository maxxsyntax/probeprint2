#!/bin/bash
# Look up and summarize WiGLE locations for SSIDs.
#
# Usage:
#   ./analysis-scripts/online_wigle_fetch.sh <ssid_hex>   one SSID
#   ./analysis-scripts/online_wigle_fetch.sh --new        every SSID with no location yet; stop
#                                        when the WiGLE quota is exhausted
#   ./analysis-scripts/online_wigle_fetch.sh --new --wait same, but wait out the quota and keep
#                                        going -- the daily-grind mode driven by
#                                        ssid2loc_every24.sh
#
# Called from build_ssid.sh's capture loop when `online=1` in .env.
#
# This file used to define its functions and then never call them -- both the
# bottom-of-file invocations and the database writes inside summarize_location()
# were commented out, so the live enrichment path computed a result and threw it
# away. Its ssid2loc() also curled ?ssid=$ssid_uri without ever assigning
# ssid_uri, so the request went out empty.
source .env
source ./analysis-scripts/location_functions.sh

if [ $# -eq 0 ]; then
	echo "usage: $0 <ssid_hex> | --new [--wait]" >&2
	exit 1
fi

if [ "$1" = "--new" ]; then
	# Default to the stop policy; --wait blocks through quota windows instead.
	on_quota=stop
	[ "$2" = "--wait" ] && on_quota=wait

	# Anything not yet located. Skip the anomalous hex patterns, which are not
	# real SSIDs and would only waste API calls.
	while read -r ssid_hex; do
		[ -z "$ssid_hex" ] && continue
		[ "$ssid_hex" = "<MISSING>" ] && continue

		# Under stop, a failed fetch means the quota is gone -- break rather
		# than hammering. Under wait, wigle_fetch blocks until it succeeds and
		# only returns non-zero on a genuine skip, so break is still correct.
		wigle_fetch "$ssid_hex" "$on_quota" || break
		summarize_one "$ssid_hex" || break
	done <<< "$(mysql -N probeprint <<< "select ssid_hex from ssid_intel where location is null and ssid_hex not like '%00%' and ssid_hex not like '%fff%';")"
	exit 0
fi

ssid_hex=$1
wigle_fetch "$ssid_hex" || exit 1
summarize_one "$ssid_hex"
