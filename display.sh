#!/usr/bin/bash
#set -x

clear
#row_1
start_date=$(date +%s)
#end_date=$(echo $date - 5 | bc)
#echo $date $end_date


while true; do 
clear
date=$(date +%s)
end_date=$(echo $date - 5 | bc)
range=''
tput cup 0 40; /usr/bin/mysql -u pi -h 192.168.1.10 -N probeprint <<< "select count(*) from ssid where time > \"$start_date\";"
tput cup 1 38; vcgencmd measure_temp
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

if [ -n "$range" ]; then 
echo \ $range
fi
		/usr/bin/mysql -u pi -h 192.168.1.10 -N probeprint <<< "select location,category,is_name,is_airport from ssid_intel where ssid_hex=\"${arr[0]}\" and ssid_hex!=\"<MISSING>\";" | sed 's/OTHER_UNKNOWN//g' 

#done <<< $(/usr/bin/mysql -u pi -h 192.168.1.10 -N probeprint <<< "select distinct ssid_hex,rssi from ssid where time>\"$end_date\" and ssid_hex!=\"<MISSING>\" ;")
done <<< $(/usr/bin/mysql -h 192.168.1.10 -u pi  -N probeprint <<< "select distinct ssid_hex,rssi from ssid where time>\"$end_date\" and ssid_hex!=\"<MISSING>\" ;")

sleep 5
done
wait
