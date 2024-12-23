#!/bin/bash
#set -x
source .env
INF=$1
mkfifo pipe_$INF 2>/dev/null

listen () {
#iwconfig $INF channel 6
 while true; do 

tshark -QVi $INF -a duration:3 -f "wlan subtype probe-req" -T fields -e wlan.ssid -e wlan.sa -e frame.time_epoch -e radiotap.dbm_antsignal -e wlan_radio.frequency -e wlan.seq -e wlan.vht.capabilities -E separator=\  2>/dev/null > pipe_$INF
done
}

tshark2db () {

###bug here vht or ht is null, moves up in arr[#], can only do vht for no

while true; do 
while read line; do
 arr=($line);
#echo ssid_hex is ${arr[0]};
ssid_hex=${arr[0]}
ssid=$(echo ${arr[0]}| xxd -r -p)
#echo ssid is $(echo ${arr[0]}| xxd -r -p)
if [ $ssid_hex != "<MISSING>" ]

then
echo ssid_hex is ${arr[0]};
echo ssid is $(echo ${arr[0]}| xxd -r -p)
echo sa is ${arr[1]}
echo time is ${arr[2]}
echo rssi is ${arr[3]}
echo freq is ${arr[4]}
echo seq is ${arr[5]}
echo vht is ${arr[6]}

else

echo Broadcast Detected ${arr[1]} time is ${arr[2]} ${arr[3]} seq is ${arr[5]}
fi

mysql -u pi -h 192.168.1.10 probeprint <<< "INSERT ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht) values (\"${arr[0]}\",\"${arr[1]}\",\"${arr[2]}\",\"${arr[3]}\",\"${arr[4]}\",\"${arr[5]}\",\"${arr[6]}\");"

#sleep 3
done < pipe_$INF
sleep .1
done
}

listen &
tshark2db &



trap 'kill $(jobs -p)' EXIT
wait
