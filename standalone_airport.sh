#!/bin/bash
#set -x
check_airport () {
	#while true; do
echo Airport check start $(date +"%H:%M:%S.%3N")
#IFS scoped to the read rather than set globally, so it cannot affect anything
#that runs after this loop.
while IFS='|' read -r iata description; do
	 iata_hex=$(printf '%s' "$iata" | xxd -p)
	 mysql probeprint <<< "update ssid_intel set is_airport=\"$description\" where ssid_hex like \"$iata_hex%\" or ssid_hex like \"%$iata_hex%\";"
done < lists/airports.txt
mysql  probeprint <<< "update ssid_intel set is_airport=0 where is_airport is null;"
#sleep 10
#done
echo Airport check stop $(date +"%H:%M:%S.%3N")
}
check_airport

