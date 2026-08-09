#!/bin/bash
# Which SSIDs are too widespread to identify anyone: the is_common flag, and the
# ignore list built from the SSIDs most devices in a capture share.
check_common () {
	while read ssid_hex; 
	do
 	ssid=$(echo -n $ssid_hex | xxd -r -p)
	#bug found matching on anomalous characters
	#mark ignore as common,for simplicity
	#need to include ssids with wigle results > 100
	if egrep -q ",$ssid$" lists/ssid.csv || egrep -q "^$ssid_hex$" lists/ignore.txt;
		then
			#echo common
		#echo $x matches most common ssid
		#bug here "enelguest" should not be labeled as common
		#sqlite3 new.db "update ssid_intel set category = \"OTHER_COMMON\" where ssid_hex=\"$ssid_hex\" and category is NULL;"
		mysql probeprint <<< "update ssid_intel set is_common=1 where ssid_hex=\"$ssid_hex\";"
	else 
		mysql probeprint <<< "update ssid_intel set is_common=0 where ssid_hex=\"$ssid_hex\";"
	fi
# 5a: an embedded 00 byte marks a frame that is not a real network name, so
# exclude %00% and a trailing %00 as well as the anomalous 1/2/8 hex prefixes.
done <<< $(mysql -N probeprint <<<"select ssid_hex from ssid_intel where is_common is null and ssid_hex not like '1%' and ssid_hex not like '2%' and ssid_hex not like '8%' and ssid_hex not like '%00%' and ssid_hex not like '%00';")

}

make_ignore_list () {	
	echo ignore_check $(date +"%H:%M:%S.%3N")
	> lists/ignore.txt
	while read line; do
		count=$(mysql -N probeprint <<< "select count(DISTINCT wlan_sa) from ssid where ssid_hex=\"$line\";")
		if [[ $count -gt 40 ]]
			then
			echo "$line" >> lists/ignore.txt
		fi
	done <<<$(mysql -N probeprint <<< "select ssid_hex from ssid;"  | sort | uniq -c | sort -nr | head -n30 |tr -s \   | cut -d \  -f3)
mysql -N probeprint <<< "select ssid_hex from ssid_intel where category=\"OTHER_ANOMALOUS\";" >> lists/ignore.txt
echo ignore_check end $(date +"%H:%M:%S.%3N")
}
