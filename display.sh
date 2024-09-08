#!/bin/bash
#set -x
source ./display_functions.sh


#while true; do
	#display_last3s & 
	#display_ssid
#	sleep 3
#echo
#done




###Disblay burst info




#display_burstinfo3s & 

#trap 'kill $(jobs -p)' EXIT
#row_1
date=$(date +%s)
end_date=$(echo $date - 5 | bc)
#echo $date $end_date
while read line; 
	do 
		arr=($line)
		echo ${arr[0]} | xxd -r -p
		rssi2=${arr[1]}

		if [[ $rssi2 -gt -66 ]]
			then
				if [[ $rssi2 -ne 0 ]]; 
				then
					range=near\ by
				fi
			else 
				if [[ $rssi2 -gt -82 ]]
				then 
					range=medium\ range
				else 
					range=far\ away
				fi
		fi
echo \ $range
		mysql -N probeprint <<< "select location,category,is_name,is_airport from ssid_intel where ssid_hex=\"${arr[0]}\";" | sed 's/OTHER_UNKNOWN//g' 
done <<< $(mysql -N probeprint <<< "select distinct ssid_hex,rssi from ssid where time>\"$end_date\" and ssid_hex!=\"<MISSING>\";")

wait