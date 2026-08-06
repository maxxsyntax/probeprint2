#!/bin/bash
# Resolve SSIDs and directed-probe BSSIDs to coordinates and street addresses.
#
# Enrichment is post-capture by design. Nothing here runs during capture unless
# you ask for it: every provider makes rate-limited network calls, and putting
# those in the ingest path costs frames.
#
# Usage:
#   ./standalone_geolocate.sh                 offline only: coordinates from the
#                                             locs/ WiGLE cache. Safe default,
#                                             no network calls at all.
#   ./standalone_geolocate.sh --addresses [n] reverse geocode via Nominatim
#                                             (network, 1 req/sec, default 500)
#   ./standalone_geolocate.sh --bssids        harvest BSSIDs from directed probes
#   ./standalone_geolocate.sh --google        locate capture points via Google
#   ./standalone_geolocate.sh --recompute     redo coordinates already set
#   ./standalone_geolocate.sh --report        coverage summary
#
# Configuration lives in .env:
#   GOOGLE_GEOLOCATION_KEY, GEO_ENABLE_APPLE, GEO_USER_AGENT, GEO_NOMINATIM_SLEEP
#
# The providers answer different questions and are not interchangeable --
# geolocate_functions.sh opens with the details. In short: WiGLE is the only one
# that takes an SSID; Google locates the observer rather than an AP; Apple is
# the only per-AP lookup and has no public API, so it ships disabled.
[ -f .env ] && source .env
source ./geolocate_functions.sh

case "${1:-}" in
	--addresses)
		geo_reverse_addresses "${2:-500}"
		geo_report
		;;
	--import-cache)
		geo_import_locs_cache
		;;
	--bssids)
		geo_harvest_bssids
		geo_report
		;;
	--google)
		# Google needs two or more APs heard together, so the BSSIDs are grouped
		# by the capture window they were seen in. The answer is where the
		# sensor was, which is worth knowing but is not a per-SSID location.
		if [ -z "${GOOGLE_GEOLOCATION_KEY:-}" ]; then
			echo "GOOGLE_GEOLOCATION_KEY is not set in .env" >&2
			exit 1
		fi
		geo_harvest_bssids
		mapfile -t bssids < <(mysql -N probeprint <<< \
			"select bssid from bssid_geo order by probe_count desc limit 10;")
		if [ "${#bssids[@]}" -lt 2 ]; then
			echo "Only ${#bssids[@]} directed-probe BSSID(s) in this capture."
			echo "Google needs at least 2 heard together to return a fix."
			exit 0
		fi
		echo "Asking Google where a sensor hearing these ${#bssids[@]} APs would be:"
		geo_google_observer "${bssids[@]}"
		;;
	--definitive)
		geo_definitive
		;;
	--report)
		geo_report
		;;
	--recompute)
		geo_from_wigle_cache --recompute
		geo_report
		;;
	*)
		geo_from_wigle_cache
		geo_report
		;;
esac
