#!/bin/bash
# check_airport -- IATA codes in SSIDs.
check_airport () {
	#while true; do
echo Airport check start $(date +"%H:%M:%S.%3N")
#IFS is scoped to the read rather than set globally. This file is sourced into
#one shell, so a bare `IFS=\|` leaked into every function that ran afterwards --
#and because mysql -N output is tab separated, a leaked pipe IFS made
#`arr=($row)` swallow whole rows into arr[0].
while IFS='|' read -r iata description; do
	 iata_hex=$(printf '%s' "$iata" | xxd -p)
	 mysql probeprint <<< "update ssid_intel set is_airport=\"$description\" where ssid_hex like \"$iata_hex%\" or ssid_hex like '%$iata_hex%'; "
done < lists/airports.txt
mysql probeprint <<< "update ssid_intel set is_airport=0 where is_airport is null;"
#done
echo Airport check stop $(date +"%H:%M:%S.%3N")
}
