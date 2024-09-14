#!/bin/bash
#set -x

check_name () {
	#todo: look for one space or 2 spaces if there's an iphone
echo check_name start $(date +"%H:%M:%S.%3N")
	#need to only work on unprocessed

#look for 's\ 

while read ssid_hex; do
	name=$(echo $ssid_hex | sed 's/277320.*//g' | xxd -r -p| tr -cd '[:print:]')
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where ssid_hex=\"$ssid_hex\";"
#	echo $ssid_hex $name
done <<< $(mysql probeprint <<< "select ssid_hex from ssid_intel where ssid_hex like \"%277320%\" and is_name is null;")

#look for Familia
while read ssid_hex; do
	name=$(echo $ssid_hex | sed 's/46616d696c696120//g' | xxd -r -p| tr -cd '[:print:]')
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where ssid_hex=\"$ssid_hex\";"
#	#echo $ssid_hex $name
done <<< $(mysql probeprint <<< "select ssid_hex from ssid_intel where ssid_hex like \"46616d696c6961%\" and is_name is null;")

while read ssid_hex; do
	name=$(echo $ssid_hex | sed 's/66616d696c696120//g' | xxd -r -p| tr -cd '[:print:]')
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where ssid_hex=\"$ssid_hex\";"
#	echo $ssid_hex $name
done <<< $(mysql probeprint <<< "select ssid_hex from ssid_intel where ssid_hex like \"66616d696c6961%\" and is_name is null;")

while read ssid_hex; do
	name=$(echo $ssid_hex | sed 's/46616d696c79//g' | xxd -r -p| tr -cd '[:print:]')
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where ssid_hex=\"$ssid_hex\";"
	#echo $ssid_hex $name
done <<< $(mysql probeprint <<< "select ssid_hex from ssid_intel where ssid_hex like \"%46616d696c79\" and is_name is null;")

#iterate through name list
while read name_hex; 
do
	name=$(echo $name_hex | xxd -r -p)
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where (ssid_hex like \"$name_hex%\" or ssid_hex like \"%$name_hex%\" or ssid_hex like \"%$name_hex\") and is_name is null;"
done < lists/names_hex.txt
mysql probeprint <<< "update ssid_intel set category=\"NAME_VAGUE\" where is_name!=0 and is_name is not null;"
mysql probeprint <<< "update ssid_intel set is_name=0 where is_name is null;"
echo check_name stop $(date +"%H:%M:%S.%3N")
}
check_name
