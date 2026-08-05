#!/bin/bash

check_fqdn () {
        echo check_fqdn start $(date +"%H:%M:%S.%3N")

# Load the TLD list once. The old shape re-read all ~1500 lines of
# lists/domains.txt for every SSID, and issued one UPDATE per matching domain
# rather than stopping at the first hit.
# https://data.iana.org/TLD/tlds-alpha-by-domain.txt
local -A tlds=()
while read -r domain; do
        [ -n "$domain" ] && tlds[${domain,,}]=1
done < lists/domains.txt

while read -r ssid_hex; do
        # The decode has to happen per row. It used to sit above this loop,
        # where ssid_hex was still unset, so $ssid was empty on every iteration
        # and check_fqdn could never match anything at all.
        ssid=$(printf '%s' "$ssid_hex" | xxd -r -p 2>/dev/null | tr -cd '[:print:]')

        # Only text after a final dot can be a TLD; an SSID with no dot is not
        # an FQDN.
        case "$ssid" in
                *.*) tld=${ssid##*.} ;;
                *)   continue ;;
        esac
        [ -z "$tld" ] && continue

        if [[ -n ${tlds[${tld,,}]:-} ]]; then
                #echo "$ssid ends in .$tld"
                mysql probeprint <<< "update ssid_intel set category=\"OTHER_FQDN\" where ssid_hex=\"$ssid_hex\";"
        fi
done <<< $(mysql -N probeprint <<< "select ssid_hex from ssid_intel where category is null or category=\"OTHER_UNKNOWN\";")
echo check_fqdn stop $(date +"%H:%M:%S.%3N")
}

check_fqdn
