#!/bin/bash

check_oneloc () {
	#set -x
	echo oneloc start $(date +"%H:%M:%S.%3N")
while read ssid_hex; 
	do
	#also need to add case sensitve single matches and not just what wigle says
	#for loc_file in ./locs/$ssid_hex.location; 
		#do 
			#can probably be shortened into a better jq query
		match=$(cat ./locs/$ssid_hex.location 2>/dev/null | jq | grep  -A 8 'lts": 1,' | grep ssid | cut -d\" -f4); 
		if egrep -q '.'  <<<"$match"
			then
			#echo oneresult 
			mysql probeprint <<< "update ssid_intel set is_oneloc='1' where ssid_hex=\"$ssid_hex\";"
			else
				mysql probeprint <<< "update ssid_intel set is_oneloc=0 where ssid_hex=\"$ssid_hex\";"
		fi
	#done

done <<< $(mysql -N probeprint <<< "select ssid_hex from ssid_intel where is_oneloc is null;")

	while read ssid_hex; do 
		city=$(cat ./locs/$ssid_hex.location | jq | grep city | cut -d\" -f4); 
		if [[ -n $city ]] ; 
			then 
			mysql probeprint <<< "update ssid_intel set location=\"$city\" where ssid_hex=\"$ssid_hex\";"
		fi
	done <<<$(mysql -N probeprint <<< "select ssid_hex from ssid_intel where is_oneloc=1 and location is null;")
	mysql probeprint <<< "update ssid_intel set location=\"AMBIGUOUS_LOC\" where is_oneloc=1 and location is null;"

echo oneloc stop $(date +"%H:%M:%S.%3N")
}

check_oneloc
