#!/usr/bin/bash
# Live operator display: who is in range, and what their device says about them.
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
# Enrichment is not run from here. Populate it first with the standalone passes
# -- categorize, name, airport, rarity, recategorize, language, seqgraph -- or
# the profile will be mostly empty.
#set -x
source ./display_functions.sh

[ -f .env ] && source .env
DISPLAY_DB_ARGS=${DISPLAY_DB_ARGS:--u pi -h 127.0.0.1}

WINDOW=${DISPLAY_WINDOW:-30}
REFRESH=${DISPLAY_REFRESH:-5}

clear
start_date=$(date +%s)

while true; do
	clear
	printf 'probeprint2   in range (last %ss)   devices seen: %s   suspect merges: %s   frames: %s\n' \
		"$WINDOW" \
		"$(dq <<< "select count(*) from devices;")" \
		"$(dq <<< "select count(*) from devices where confidence='low';")" \
		"$(dq <<< "select count(*) from ssid where cast(time as decimal(20,7)) > $start_date;")"
	printf '%s\n\n' "--------------------------------------------------------------------------"

	display_inrange "$WINDOW"

	sleep "$REFRESH"
done
