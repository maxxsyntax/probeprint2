#!/bin/bash
source .env
source ./ssid_intel_online_functions.sh

#set -x
#need to fix null byte bug
while read ssid_hex; do 
        echo $ssid_hex
        ssid="$(echo -n $ssid_hex | xxd -r -p)"
        ssid_uri=$(echo -n "$ssid" | jq -sRr @uri)

ssid2loc
done <<< $(mysql -N probeprint <<< "select distinct ssid_hex from ssid where ssid_hex not like '%00%' and ssid_hex not like '%fff%' ;")
# done < ssid_list_june22.db       
