#!/bin/bash
x=$*

has_radtap=$(tshark -a packets:1  -QVr $x -Y "wlan.fc.type_subtype == 4 and wlan.tag.length != 0" -T fields  -e wlan_radio.frequency | egrep '[0-9]' | wc -l)
if [[ $has_radtap -eq 1 ]]
then
endtime=$(tshark -Vr $x -Y "wlan.fc.type_subtype == 4 and wlan.tag.length != 0" -T fields -e frame.time_epoch -E separator=\    | tail -n1)
end_time=`echo "scale=7;  $endtime + .0001" | bc`
begintime=$(tshark -Vr $x -Y "wlan.fc.type_subtype == 4 and wlan.tag.length != 0" -T fields -e frame.time_epoch -E separator=\    | head -n1 | cut -d. -f1)




tshark -Vr $x -Y "wlan.fc.type_subtype == 4 and wlan.tag.length != 0" -T fields -e wlan.ssid -e wlan.sa -e frame.time_epoch -e radiotap.dbm_antsignal -e wlan_radio.frequency -e wlan.seq -e wlan.vht.capabilities -E separator=\  > /usr/src/probeprint/pipe &

while read line; do
 arr=($line);
echo ssid is ${arr[0]};
echo sa is ${arr[1]}
echo time is ${arr[2]}
echo rssi is ${arr[3]}
echo freq is ${arr[4]}
echo seq is ${arr[5]}
echo vht is ${arr[6]}
#sqlite3 /usr/src/probeprint/new.db "INSERT OR IGNORE INTO ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht) values (\"${arr[0]}\",\"${arr[1]}\",\"${arr[2]}\",\"${arr[3]}\",\"${arr[4]}\",\"${arr[5]}\",\"${arr[6]}\");"
mysql probeprint <<<"insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht) values (\"${arr[0]}\",\"${arr[1]}\",\"${arr[2]}\",\"${arr[3]}\",\"${arr[4]}\",\"${arr[5]}\",\"${arr[6]}\");"
y=$?
while [[ $y -ne 0 ]]; do
	echo retry $(date) $line
	sleep .2
#	sqlite3 /usr/src/probeprint/new.db "INSERT OR IGNORE INTO ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht) values (\"${arr[0]}\",\"${arr[1]}\",\"${arr[2]}\",\"${arr[3]}\",\"${arr[4]}\",\"${arr[5]}\",\"${arr[6]}\");"
mysql probeprint <<<"insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht) values (\"${arr[0]}\",\"${arr[1]}\",\"${arr[2]}\",\"${arr[3]}\",\"${arr[4]}\",\"${arr[5]}\",\"${arr[6]}\");"

	y=$?
done
#sleep 3
done < /usr/src/probeprint/pipe
echo $begintime
echo $end_time
#sqlite3 /usr/src/probeprint/new.db "update ssid set tag=\"$x\" where time>\"$begintime\" and time < \"$end_time\";"
sqlite3 /usr/src/probeprint/new.db "update ssid set tag=\"$x\" where time>$begintime and time < $end_time;"
#echo sqlite3 /usr/src/probeprint/new.db \"update ssid set tag=$x where time\>$begintime and time \< $end_time\;\"
else
	echo $x has No radiotap headers
fi
