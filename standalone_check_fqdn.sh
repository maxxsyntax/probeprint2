#!/bin/bash

#needs refactor, convert fqdn to hex and update where ssid_hex like fqdn_hex


check_fqdn () {
        echo check_fqdn start $(date +"%H:%M:%S.%3N")
         ssid=$(echo -n $ssid_hex | xxd -r -p)
        while read ssid_hex; do 
#https://data.iana.org/TLD/tlds-alpha-by-domain.txt
while read domain; do

        fqdn=\\.${domain,,}
        len=${#fqdn}
        last4=${ssid: -$len}
        if [[ "${last4,,}" =~ ${fqdn,,} ]]
                then
                #echo Domain $domain Last4 $last4 $ssid
                mysql probeprint <<< "update ssid_intel set category=\"OTHER_FQDN\" where ssid_hex=\"$ssid_hex\";"
        fi
done < lists/domains.txt
done <<< $(mysql probeprint <<< "select ssid_hex from ssid_intel where category is null or category=\"OTHER_UNKNOWN\";")
echo check_fqdn stop $(date +"%H:%M:%S.%3N")
}

check_fqdn
