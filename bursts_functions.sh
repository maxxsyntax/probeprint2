#!/bin/bash
#0 = unprocessed
#1 = no burst found by mac address
#2 = no burst found by sequence number
#3 = no burst found by vht

ssid_2bursts-wlan_sa () {
	#set -x
echo ssid_2bursts-wlan_sa start $(date +"%H:%M:%S.%3N")
#pull unproccessed SSID and break into array
es=0
#es exit status and until loop to iterate through all unprocessed lines
until [[ $es -ne 0 ]]; do
#select unprocessed row
row=$(mysql -N probeprint <<< "select ssid_hex,wlan_sa,time from ssid where is_processed=0 wlan_sa is not null order by time limit 1;")
es=$?
arr=($row)
if [[ -z ${arr} ]]
	then echo No rows found for wlan_sa
	echo finishing ssid_2bursts-wlan_sa $(date) 
	sleep 5
	return
	#exit 0
fi
ssid_hex=${arr[0]}
wlan_sa=${arr[1]}
time=${arr[2]}
#echo $ssid_hex $wlan_sa $time
#sleep 1
###analyze probes in the next 1 second
end_time=$(echo "scale=7;  $time + 1" | bc)
#echo $end_time
#sleep 2
endtime=$end_time
begintime=$( echo "scale=7; $time - .000001" | bc)
#echo $begintime
#sleep 3 
burst=()
#burst+=("$ssid_hex")
### future probe loop
while read line; 
do
#sleep 1
#IFS=\|
arr2=($line)
ssid_hex2=${arr2[0]}
wlan_sa2=${arr2[1]}
time2=${arr2[2]}

#append ssid of matching mac address to burst
#unset IFS
burst+=("$ssid_hex2")
#mark child probes as processed, if considered a burst
if [[ "$time" != "$time2" ]]; then
mysql -N probeprint <<< "update ssid set is_processed=100 where wlan_sa = \"$wlan_sa2\" and time =\"$time2\";"
#else
	#sqlite3 new.db "update ssid set is_processed=1 where wlan_sa = \"$wlan_sa2\" and time =\"$time2\";"
fi
final_time=$time2
#query for 1 second in the future and iterate through probes to find match ## sqlite3 reverses < and > because numbers are negatives, treats them as positive
done <<<$(mysql -N probeprint <<< "SELECT ssid_hex,wlan_sa,time from ssid where time < \"$endtime\" and time > \"$begintime\" and wlan_sa=\"$wlan_sa\" order by time;")

#mark partent probe as processed
mysql probeprint <<< "update ssid set is_processed=1 where wlan_sa = \"$wlan_sa\" and time = \"$time\";"

bcount=${#burst[@]}
#mark parent is_processed 100 where burst is found
if [[ $bcount -gt "1" ]]
then 
mysql probeprint <<< "update ssid set is_processed=100 where wlan_sa = \"$wlan_sa\" and time =\"$time\";"
newburst=`echo ${burst[*]} | tr \  \:`
bdur=`echo "scale=7; $final_time - $time" | bc`
#sqlite3 bursts.db "insert into bursts(ssids,time,burst_size,burst_duration,bmethod) values (\"$newburst\",\"$time\",\"${#burst[@]}\",\"$bdur\", \"wlan_sa\") on conflict(ssids) do update set time=\"$final_time\";"
echo $newburst >> /tmp/ssids.log
mysql probeprint <<< "insert into bursts(ssids,time,burst_size,burst_duration,bmethod) values (\"$newburst\",\"$time\",\"${#burst[@]}\",\"$bdur\", \"wlan_sa\");"
fi
done
echo ssid_2bursts-wlan_sa done $(date +"%H:%M:%S.%3N")
}







































ssid2bursts-seq () {
	#needs to include rssi

echo ssid_2bursts-seq start $(date +"%H:%M:%S.%3N")
#pull unproccessed SSID and break into array
es=0
until [[ $es -ne 0 ]]; do
row=$(mysql -N probeprint <<< "select ssid_hex,wlan_sa,time,seq,rssi from ssid where is_processed=1 and seq!=null order by time limit 1;")
es=$?
arr=($row)
if [[ -z ${arr} ]]
then echo ending no seq_row 
echo ssid_2bursts-seq stop $(date +"%H:%M:%S.%3N")
sleep 5
return
#exit 0
fi
ssid_hex=${arr[0]}
wlan_sa=${arr[1]}
time=${arr[2]}
seq=${arr[3]}
rssi=$(echo ${arr[4]} | cut -d, -f1)
rssi_max=$(echo $rssi +2 |bc)
rssi_min=$(echo $rssi -2 | bc)
end_time=$(echo "scale=7;  $time + 1" | bc)
endtime=$end_time
begintime=$( echo "scale=7; $time - .000001" | bc)
seq_end=$(($seq +60))
burst=()

while read line; 
do
#echo child PR with rssi_min max $line
#sleep 1
arr2=($line)
ssid_hex2=${arr2[0]}
wlan_sa2=${arr2[1]}
time2=${arr2[2]}
#proc2=${arr2[4]}
#append ssid of matching mac address to burst
#unset IFS
burst+=("$ssid_hex2")

#ensure child probe is not the same as parent probe
if [[ "$time" != "$time2" ]]; then
	#mark child probes as processed, if considered a burst
	#echo will run update ssid set is_processed=100 where wlan_sa = \"$wlan_sa2\" and time =\"$time2\"
mysql probeprint <<< "update ssid set is_processed=100 where wlan_sa = \"$wlan_sa2\" and time =\"$time2\";"
else
	#selected parent probe as child probe, marking as no burst found
	#echo will run update ssid set is_processed=2 where wlan_sa = \"$wlan_sa2\" and time =\"$time2\"
	mysql probeprint <<< "update ssid set is_processed=2 where wlan_sa = \"$wlan_sa2\" and time =\"$time2\";"
fi
#updating final_time
final_time=$time2
#mark partent probe as processed
#echo will run  "update ssid set is_processed=2 where wlan_sa = \"$wlan_sa\" and time = \"$time\";"
mysql probeprint <<< "update ssid set is_processed=2 where wlan_sa = \"$wlan_sa\" and time = \"$time\";"

done <<<$(mysql -N probeprint <<< "SELECT ssid_hex,wlan_sa,time from ssid where time < \"$endtime\" and time > \"$begintime\" and seq >= \"$seq\" and seq <= \"$seq_end\" and rssi <= \"$rssi_max\" and rssi >= \"$rssi_min\" order by time;")

bcount=${#burst[@]}
if [[ $bcount -gt "1" ]]
then 
	#mark parent probe as part of burst if burst is found
mysql probeprint <<< "update ssid set is_processed=100 where wlan_sa = \"$wlan_sa\" and time=\"$time\";"
fi
newburst=`echo ${burst[*]} | tr \  \:`
bdur=$(echo "scale=7; $final_time - $time" | bc)
#echo $bdur
#only insert bursts with burst count greater than 1 because otherwise it's not a burst
if [[ "${#burst[@]}" -gt 1 ]]; then
mysql probeprint <<< "insert into bursts(ssids,time,burst_size,burst_duration,bmethod) values (\"$newburst\",\"$time\",\"${#burst[@]}\",\"$bdur\", \"seq\");"
fi
done
echo ssid_2bursts-seq stop $(date +"%H:%M:%S.%3N")
}

































ssid2bursts-vht () {
	echo ssid_2bursts-vht start $(date +"%H:%M:%S.%3N")
#pull unproccessed SSID and break into array
es=0
until [[ $es -ne 0 ]]; do
row=$(mysql -N probeprint <<< "select ssid_hex,wlan_sa,time,vht,rssi from ssid where is_processed=2 order by time limit 1;")
es=$?
arr=($row)
if [[ -z ${arr} ]]
then echo ending no vht_row 
echo ssid_2bursts-vht stop $(date +"%H:%M:%S.%3N")
sleep 50
return
#exit 0
fi
ssid_hex=${arr[0]}
wlan_sa=${arr[1]}
time=${arr[2]}
vht=${arr[3]}
rssi=$(echo ${arr[4]} | cut -d, -f1)
rssi_max=$(echo $rssi +2 |bc)
rssi_min=$(echo $rssi -2 | bc)
end_time=$(echo "scale=7;  $time + 1" | bc)
endtime=$end_time
begintime=$( echo "scale=7; $time - .000001" | bc)
burst=()

while read line; 
do
#echo child PR with rssi_min max $line
#sleep 1
arr2=($line)
ssid_hex2=${arr2[0]}
wlan_sa2=${arr2[1]}
time2=${arr2[2]}
#append ssid of matching mac address to burst
#unset IFS
burst+=("$ssid_hex2")

#ensure child probe is not the same as parent probe
if [[ "$time" != "$time2" ]]; then
	#mark child probes as processed, if considered a burst
	#echo will run update ssid set is_processed=100 where wlan_sa = \"$wlan_sa2\" and time =\"$time2\"
mysql probeprint <<< "update ssid set is_processed=100 where wlan_sa = \"$wlan_sa2\" and time =\"$time2\";"
else
	#selected parent probe as child probe, marking as no burst found
	#echo will run update ssid set is_processed=2 where wlan_sa = \"$wlan_sa2\" and time =\"$time2\"
	mysql probeprint <<< "update ssid set is_processed=3 where wlan_sa = \"$wlan_sa2\" and time =\"$time2\";"
fi
#updating final_time
final_time=$time2
#mark partent probe as processed
#echo will run  "update ssid set is_processed=2 where wlan_sa = \"$wlan_sa\" and time = \"$time\";"
mysql probeprint <<< "update ssid set is_processed=3 where wlan_sa = \"$wlan_sa\" and time = \"$time\";"

done <<<$(mysql -N probeprint <<< "SELECT ssid_hex,wlan_sa,time from ssid where time < \"$endtime\" and time > \"$begintime\" and vht = \"$vht\" and rssi <= \"$rssi_max\" and rssi >= \"$rssi_min\" order by time;")

bcount=${#burst[@]}
if [[ $bcount -gt "1" ]]
then 
	#mark parent probe as part of burst if burst is found
mysql probeprint <<< "update ssid set is_processed=100 where wlan_sa = \"$wlan_sa\" and time=\"$time\";"
fi
newburst=`echo ${burst[*]} | tr \  \:`
bdur=$(echo "scale=7; $final_time - $time" | bc)
#echo $bdur
#only insert bursts with burst count greater than 1 because otherwise it's not a burst
if [[ "${#burst[@]}" -gt 1 ]]; then
mysql probeprint <<< "insert into bursts(ssids,time,burst_size,burst_duration,bmethod) values (\"$newburst\",\"$time\",\"${#burst[@]}\",\"$bdur\", \"vht\");"
fi
done
echo ssid_2bursts-vht stop $(date +"%H:%M:%S.%3N")
}


























































is_uniq () {
	echo is_uniq start $(date +"%H:%M:%S.%3N")
#set -x
ssids=.
until [ -z $ssids ]; do
ssids=$(mysql -N probeprint <<< "select ssids from bursts where is_uniq is null limit 1")
uniq=0
uniq=$(echo ${ssids[*]} | tr \:  \\n |  sort | uniq  | wc -l)
	if [[ $uniq -lt 2 ]]; then
		mysql probeprint <<< "update bursts set is_uniq=0 where ssids=\"$ssids\";"
	else   
		mysql probeprint <<< "update bursts set is_uniq=1 where ssids=\"$ssids\";"
	fi
done
	echo is_uniq stop $(date +"%H:%M:%S.%3N")
}
























find_relatedbursts () {
echo starting find_relatedbursts $(date +"%H:%M:%S.%3N")
while true; do
IFS=:;
###
###set related_burst to ignore for bursts of non-unique common ssids
###
#select unprocessed rowid and break into array
ssids=($(mysql -N probeprint <<< "select time,ssids from bursts where burst_duration != 0 and burst_size > 1 and related_burst = 0 and is_uniq=1 limit 1;")); 
echo ${ssids[*]}
#check for value
if [[ -z ${ssids} ]]
	then echo nothing to do, no ssids
	echo find_relatedbursts stop $(date +"%H:%M:%S.%3N")
sleep 10
break
fi
#set a count of all the ssids
ssidn="${#ssids[@]}"
# number of ssid to examine, ssid[0] = time
ssidi=1
echo working on ${ssids[$ssidi]}

#find bursts of uniq ssids only ; could be taken care of by is_uniq
uniq=0
uniq=$(echo ${ssids[*]} | tr \  \\n |  sort | uniq  | wc -l)
((uniq--))
#echo $uniq


if [[ $uniq -lt 2 ]]
	then 
	echo only 1 unique ssid in burst
	echo doing ignore check
	ignore_check=$(mysql -N probeprint <<< "select ssid_hex from ssid_intel where (is_common=1 or is_airport IS NOT NULL) and ssid_hex=\"${ssids[1]}\";")
	if [ -n $ignore_check ]; 
		then
		echo ssid ${ssids[1]} is on ignore list, setting related burst to self
		mysql probeprint <<< "update bursts set related_burst=\"${ssids[0]}\" where time=\"${ssids[0]}\";"
		echo exit was here
		#exit 1
	fi
#continue process for ssids not on ignore list
	echo finding similar bursts for time = ${ssids[0]}
	mysql probeprint <<< "update bursts set related_burst=\"${ssids[0]}\" where (ssids like \"%:${ssids[1]}:%\" or ssids like \"%:${ssids[1]}\" or ssids like \"${ssids[1]}:%\") AND related_burst != \"IGNORE\";"
	#mark parent burst as complete
	mysql probeprint <<< "update bursts set related_burst=\"${ssids[0]}\" where time=\"${ssids[0]}\";"
fi
#done processing bursts with only 1 ssid


#for non uniq ssids
#check for ignored ssids.  super common ssid, like name of current location wifi
#ignored is wrong answer, need to iterate to next in array

until [[ "$ssidi" == "$ssidn" ]]
	do
	#echo $ssidi
	#echo ${ssids[$ssidi]}
	echo doing ignore check
	ignore_check=$(mysql -N probeprint <<< "select ssid_hex from ssid_intel where (is_common=1 or is_airport IS NOT NULL) and ssid_hex=\"${ssids[$ssidi]}\";")
	if [ -z $ignore_check ]; 
		then
		#No value so not on the ignore list
		mysql probeprint <<< "update bursts set related_burst=\"${ssids[0]}\" where (ssids like \"%:${ssids[$ssidi]}:%\" or ssids like \"${ssids[$ssidi]}:%\" or ssids like \"%${ssids[$ssidi]}\" or ssids=\"{ssids[$ssidi]}\") AND related_burst != \"IGNORE\";"
		echo updated ssids like ${ssids[$ssidi]} with time  ${ssids[0]}
		#end extra action
		else echo ${ssids[$ssdi]} is on ignore list
	fi
	#move to next ssid for both ignore and not ignore
	((ssidi++))
	echo will be working on ${ssids[$ssidi]}
done
#done for until

#set parenent burst related burst
mysql probeprint <<< "update bursts set related_burst=\"${ssids[0]}\" where time=\"${ssids[0]}\";"
echo exit 0 was here
#exit 0
done
echo find_relatedbursts stop  $(date +"%H:%M:%S.%3N")
}
