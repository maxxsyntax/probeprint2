#!/bin/bash
# Bulk sweep: summarise cached WiGLE responses for every SSID lacking a location.
#
# Offline by design -- it reads whatever is already cached in locs/ and never
# calls the API. Use `summarize_location.sh --new` when you want fetching too.
#
# The jq summarisation itself now lives in location_functions.sh, shared with
# summarize_location.sh, so the two paths cannot drift apart again.
source .env
source ./location_functions.sh

echo "summarize_location start $(date +"%H:%M:%S.%3N")"

while read -r ssid_hex; do
    [ -z "$ssid_hex" ] && continue
    summarize_one "$ssid_hex"
done <<< "$(mysql -N probeprint <<< "SELECT ssid_hex FROM ssid_intel WHERE location IS NULL;")"

echo "summarize_location end $(date +"%H:%M:%S.%3N")"
