#!/bin/bash

check_address () {
	echo address start $(date +"%H:%M:%S.%3N")
	while read ssid_hex; do
		ssid=$(echo $ssid_hex | xxd -r -p)
	if egrep -q '^[0-9]{1,5} ?[A-Z][\\.a-z] ?[a-zA-Z]' <<< "$ssid"
 		then 
		mysql probeprint <<< "update ssid_intel set category=\"LOCATION_SPECIFIC\" where ssid_hex=\"$ssid_hex\";"
	fi
done <<< $( mysql -N probeprint <<< "select ssid_hex from ssid_intel where ssid_hex like '3%';")
	echo check address stop $(date +"%H:%M:%S.%3N")
}
check_address
