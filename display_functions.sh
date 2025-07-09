#!/bin/bash

display_last3s () {
while true; do 

#find new ssids in last 3 seconds

x=1

while read -r line; do 
	rssi2=0
	range=''
IFS='|' read -r -a arr <<<"$line"
ssid="$(echo -n ${arr[0]} | xxd -r -p)" 
ssid_hex="${arr[0]}"
wlan_sa=${arr[1]}
rssi=${arr[2]}
rssi2=$(echo ${arr[2]}| cut -d\, -f1)
if [[ $rssi2 -gt -66 ]]
then
	if [[ $rssi2 -ne 0 ]]; then
	range=near\ by 
fi
else 
	if [[ $rssi2 -gt -82 ]]
	then 
	range=medium
else 
	range=far
fi
fi
vendor=$(sqlite3 ssid.db "select distinct vendor from ssid where wlan_sa=\"$wlan_sa\" and vendor is not null;")
if [[ -n $ssid ]]; then


echo  -e Network: $ssid \\nProxity: $range $rssi2 \\nVendor: $vendor  | grep -v "Vendor: ." | egrep -v 'Vendor:$'
fi
sqlite3 ssid_intel.db ".mode line" ".headers on" "select category,location,is_name,is_airport,is_common,is_oneloc from ssid_intel where ssid_hex=\"$ssid_hex\";" | egrep -v '= 0' | egrep -v 'location = $'



related_burst=$(sqlite3 bursts.db "select distinct related_burst from bursts where ssids like \"%:$ssid_hex:%\" or ssids like \":$ssid_hex%\" or ssids like \"%$ssid_hex:\";")

 #IFS=\:
   while read a
   do 
   	if [[ -n $a ]]; then
   		if [ "$a" != "$ssid_hex" ]; then
   	echo
   	echo  Related Network: $(echo -n $a | xxd -r -p)
   fi
fi
   	sqlite3 ssid_intel.db ".mode line" ".headers on" "select category,location,is_name,is_airport,is_common,is_oneloc from ssid_intel where ssid_hex=\"$a\";" | egrep -v '= 0'
   done  <<< $(sqlite3 bursts.db "select ssids from bursts where related_burst=\"$related_burst\";"| tr \: \\n  | sort -u)
#tput cup 4 4
#sqlite3 new.db "select * from ssid_intel where ssid_hex=\"$ssid_hex\"; "
#sqlite3 new.db "select vendor from ssid where ssid_hex=\"$ssid_hex\"; "
#((x++))
ssid_hex=''
done <<<$(sqlite3 ssid.db "select  ssid_hex,wlan_sa,rssi from ssid where time > $(date +%s --date=30000\ sec\ ago) group by ssid_hex order by rssi;")
#display intel
sleep 3
#echo
done

}




display_burstinfo3s () {
	while true; do 

	#When SSID is seen, match ssid to ssids of burst, pull related burst ssids, pull all info of all ssids from ssid_intel
#Mark VIP as needed
###


while read -r ssid_hex; do
	related_burst=$(sqlite3 bursts.db "select distinct related_burst from bursts where ssids like \"%:$ssid_hex:%\" or ssids like \":$ssid_hex%\" or ssids like \"%$ssid_hex:\";")
    
   IFS=\:
   for a in $(sqlite3 bursts.db "select ssids from bursts where related_burst=\"$related_burst\";")
   do 
   	echo -n $a | xxd -r -p
   	echo 
   	sqlite3 ssid_intel.db $"select * from ssid_intel where ssid_hex=\"$a\";"
   done




done <<<$(sqlite3 ssid.db "select distinct ssid_hex from ssid where time > $(date +%s --date=3\ sec\ ago) group by ssid_hex order by rssi;")
sleep 3
done
}


display_ssid () {
while read -r line; do
	#echo $line

	rssi2=0
	range=''
IFS='|' read -r -a arr <<<"$line"
ssid="$(echo -n ${arr[0]} | xxd -r -p)" 
ssid_hex="${arr[0]}"
wlan_sa=${arr[1]}
rssi=${arr[2]}
rssi2=$(echo ${arr[2]}| cut -d\, -f1)

vendor=$(sqlite3 ssid.db  "PRAGMA journal_mode=WAL;" "select distinct vendor from ssid where wlan_sa=\"$wlan_sa\" and vendor is not null;" | sed 's/wal//g')

if [[ -n $ssid ]]; then
echo $ssid $rssi2 $vendor
sleep .5
fi



#done <<<$(sqlite3 new.db "select distinct ssid_hex from ssid where time > $(date +%s --date=3\ sec\ ago) group by ssid_hex order by time;")


done <<<$(sqlite3 ssid.db "PRAGMA journal_mode=WAL;" "select  ssid_hex,wlan_sa,rssi from ssid where time > $(date +%s --date=3\ sec\ ago) group by ssid_hex order by rssi;")
}
































displayburst_simple_vht () {

time=$(date +%s)
begintime=$( echo "scale=7; $time - .000001" | bc)
row=$(sqlite3 ssid.db "select * from ssid ssid_hex not like '%000%' and ssid_hex not like '%fff%' and rssi is not null and vht is not null limit 1;")
IFS=\|
arr=($row)
if [[ -z ${arr} ]]
then 
	echo ending vht
sleep 5
return
fi
ssid_hex=${arr[0]}
wlan_sa=${arr[1]}
time=${arr[2]}
rssi=$(echo ${arr[3]} | cut -d, -f1)
#echo $rssi
vht=${arr[4]}
end_time=`echo "scale=7;  $time + 1" | bc`
#endtime=`echo $end_time | cut -d\. -f1`
endtime=$end_time
#time3=`echo $time | cut -d. -f1`
#begintime=$time
begintime=$( echo "scale=7; $time - .000001" | bc)
((rssi_max=rssi+5))
((rssi_min=rssi-5))
while read line; 
do
#echo $line
if [[ -z $line ]]
then 
sqlite3 ssid.db "update ssid set is_processed=2 where wlan_sa = \"$wlan_sa\" and time =\"$time\";"
echo no other vhts found, breaking $vht $ssid_hex
break
fi
IFS=\|
arr2=($line)
ssid_hex2=${arr2[0]}
wlan_sa2=${arr2[1]}
time2=${arr2[2]}
rssi2=${arr2[3]}
vht2=${arr2[4]}
#append ssid of matching mac address to burst
#unset IFS
burst+=("$ssid_hex2")
sqlite3 ssid.db "update ssid set is_processed=100 where wlan_sa = \"$wlan_sa2\" and time =\"$time2\";"
final_time=$time2

#query for 1 second in the future and iterate through probes to find match
#sqlite3 messes up on greater/less than of negative numbers so operators are reversed
done <<<$(sqlite3 ssid.db "SELECT ssid_hex,wlan_sa,time,rssi,vht from ssid where time < \"$endtime\" and time > \"$begintime\" and rssi > \"$rssi_max\" and rssi < \"$rssi_min\" and vht=\"$vht\";")
bcount=${#burst[@]}
newburst=$(echo ${burst[*]} | tr \  \:)
bdur=$(echo "scale=7; $final_time - $time" | bc)
if [[ $bcount -gt "1" ]]
then
echo ${#burst[@]}
fi
}


row_1() {
	
x=0
#date=$(date -d '08/09/2024 19:40:22' +"%s")
#date=1720470846
#date=$(date +"%s")
date=$((($(date +%s)-5)))
x=1

while read -r line; do 
	rssi2=0
	range=''
IFS='|' read -r -a arr <<<"$line"
ssid="$(echo -n ${arr[0]} | xxd -r -p)" 
ssid_hex="${arr[0]}"
wlan_sa=${arr[1]}
rssi=${arr[1]}
rssi2=$(echo ${arr[1]}| cut -d\, -f1)
if [[ $rssi2 -gt -66 ]]
then
	if [[ $rssi2 -ne 0 ]]; then
	range=close 
fi
else 
	if [[ $rssi2 -gt -82 ]]
	then 
	range=medium\ range
else 
	range=far
fi
fi
#tput cup $x 0
echo
echo $ssid $range
((x++))
#tput cup $x 0
echo -n $(sqlite3 ssid_intel.db "select category from ssid_intel where ssid_hex=\"$ssid_hex\";")
echo $(sqlite3 ssid_intel.db "select location from ssid_intel where ssid_hex=\"$ssid_hex\";")
((x++))
airport=$(sqlite3 ssid_intel.db "select is_airport from ssid_intel where ssid_hex=\"$ssid_hex\" and is_airport!=0;")
#tput cup $x 0
echo  $airport
((x++))
#tput cup $x 0
echo -n $(sqlite3 ssid_intel.db "select is_name from ssid_intel where ssid_hex=\"$ssid_hex\" and is_name!=0;")  \ 
is_oneloc=$(sqlite3 ssid_intel.db "select is_oneloc from ssid_intel where ssid_hex=\"$ssid_hex\" and is_name!=0;")
if [[ $is_oneloc -eq 1 ]]
then
	echo Single Location
fi



((x++))
done <<< $(sqlite3 ssid.db "select ssid_hex,rssi from ssid where ssid_hex!=\"<MISSING>\" and time>$date group by ssid_hex;")


}
