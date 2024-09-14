check_common () {
	echo check_common start $(date +"%H:%M:%S.%3N")
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
done <<< $(mysql -N probeprint <<<"select ssid_hex from ssid_intel where ssid_hex not like \"00%\" and is_common is null;")
echo check_common stop $(date +"%H:%M:%S.%3N")
}
check_common