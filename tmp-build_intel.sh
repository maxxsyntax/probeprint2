#!/bin/bash
source ./ssid_intel_functions_contd.sh
date_start=$(date +%s)

while true; do




ssid2ssid_intel $date_start
#check_airport
#check_name 
categorize &
#check_oneloc
#check_anomalies
#check_language

#while read ssid_hex; do 
#	check_address $ssid_hex
#	summarize_location $ssid_hex

#done <<< $(mysql -N probeprint <<<"select ssid_hex from ssid where time > \"$date_start\";")




	while read ssid_hex; do
		ssid=$(echo -n $ssid_hex | xxd -r -p)


	done <<< $(mysql -N probeprint <<< "select distinct ssid_hex from ssid where time>\"$date_start\" and ssid_hex!=\"<MISSING>\";")
done


trap 'kill $(jobs -p)' EXIT
wait