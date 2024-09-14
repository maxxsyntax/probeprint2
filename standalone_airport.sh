#!/bin/bash
#set -x
check_airport () {
	#while true; do
echo Airport check start $(date +"%H:%M:%S.%3N")
IFS=\|; 
while read line; do 
#	echo $line
	arr=($line);
	#echo ${arr[*]}
#	echo ${arr[0]}
#	echo ${arr[1]}
	 iata_hex=$(echo -n ${arr[0]} | xxd -p)
#	 echo $iata_hex 
 #echo update ssid_intel set is_airport=\"${arr[1]}\" where ssid_hex like \"$iata_hex%\" or ssid_hex like \"%$iata_hex%\"
	 mysql probeprint <<< "update ssid_intel set is_airport=\"${arr[1]}\" where ssid_hex like \"$iata_hex%\" or ssid_hex like \"%$iata_hex%\";"
done < lists/airports.txt
mysql  probeprint <<< "update ssid_intel set is_airport=0 where is_airport is null;"
#sleep 10
#done
echo Airport check stop $(date +"%H:%M:%S.%3N")
}
check_airport

