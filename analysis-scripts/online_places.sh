#!/bin/bash
# Resolve SSIDs that name a business to that business's street address, using
# the Google Places API.
#
# Only SSIDs WiGLE could not place are queried. An SSID already carrying
# observed coordinates keeps them: a measurement outranks an inference, and
# overwriting one with the other would quietly downgrade the evidence.
#
# NETWORK AND BILLING. This sends SSIDs to Google and is charged per request.
# It is not part of process.sh for that reason -- like summarize_location.sh,
# it is run deliberately. Responses cache under $PLACES_CACHE_DIR so no name is
# ever paid for twice, and each run is capped.
#
# Usage:
#   ./analysis-scripts/online_places.sh              query up to 200 candidates
#   ./analysis-scripts/online_places.sh 25           query up to 25 (start here)
#   ./analysis-scripts/online_places.sh --dry-run    show what would be queried, send nothing
#   ./analysis-scripts/online_places.sh --report     coverage summary, no network
#
# Requires GOOGLE_PLACES_KEY in .env, with the Places API (New) enabled.
[ -f .env ] && source .env
source ./analysis-scripts/places_functions.sh

case "${1:-}" in
	--report)
		places_report
		;;
	--dry-run)
		# Exactly the candidate query and exactly the rejection rules the pass
		# uses -- no second copy of the selection logic to drift out of step.
		echo "Candidates with no WiGLE fix${PLACES_CATEGORY:+, category=$PLACES_CATEGORY}:"
		echo
		queried=0
		: > /tmp/pp_places_reasons.$$
		while IFS='|' read -r hex ssid; do
			[ -z "$hex" ] && continue
			if why=$(places_reject "$ssid"); then
				echo "$why" >> /tmp/pp_places_reasons.$$
			else
				queried=$((queried+1))
				[ "$queried" -le 25 ] && \
					printf '  QUERY  %-38s -> %s\n' "$ssid" "$(places_normalize "$ssid")"
			fi
		done < <(places_candidate_sql "${2:-200}" | mysql -N probeprint)

		[ "$queried" -gt 25 ] && printf '  ... and %d more\n' "$((queried - 25))"
		echo
		echo "  would query : $queried"
		echo "  rejected    :"
		sort /tmp/pp_places_reasons.$$ | uniq -c | sort -rn | sed 's/^/     /'
		rm -f /tmp/pp_places_reasons.$$
		echo
		echo "Nothing was sent. Re-run without --dry-run to query."
		;;
	*)
		# Propagate the refusal. Without this the exit status is places_report's,
		# so a run that declined to start for want of a key looked like a
		# successful no-op -- and printed a coverage table implying it had done
		# something.
		places_resolve "${1:-200}" || exit $?
		places_report
		;;
esac
