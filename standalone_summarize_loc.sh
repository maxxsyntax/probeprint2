#!/bin/bash
source .env
#set -x
locale=""

summarize_location () {
    ssid_hex=$1
    ssid=$(echo "$ssid_hex" | xxd -r -p)
    file="locs/$ssid_hex.location"
    locale=""
    
    if [[ ! -f "$file" ]]; then
        mysql probeprint <<< "UPDATE ssid_intel SET location='no file' WHERE ssid_hex='$ssid_hex' AND location IS NULL;"
        echo "$ssid_hex (no file)"
        return
    fi

    results=$(jq -r '.totalResults' "$file" 2>/dev/null)

    if [[ -z "$results" || "$results" -lt 1 ]]; then
        mysql probeprint <<< "UPDATE ssid_intel SET location='no results' WHERE ssid_hex='$ssid_hex';"
        echo "$ssid_hex (no results)"
        return
    fi

    if [[ "$results" -gt 100 ]]; then
        mysql probeprint <<< "UPDATE ssid_intel SET location='too many results' WHERE ssid_hex='$ssid_hex';"
        echo "$ssid_hex (too many results)"
        return
    fi

    # Parse matching entries
    matches=$(jq ".results[] | select(.ssid==\"$ssid\")" "$file")
    if [[ -z "$matches" ]]; then
        mysql probeprint <<< "UPDATE ssid_intel SET location='no match for ssid' WHERE ssid_hex='$ssid_hex';"
        echo "$ssid_hex (no ssid match)"
        return
    fi

    # Collect unique values
    countries=($(echo "$matches" | jq -r '.country' | grep -v null | sort -u))
    regions=($(echo "$matches" | jq -r '.region' | grep -v null | sort -u))
    cities=($(echo "$matches" | jq -r '.city' | grep -v null | sort -u))
    roads=($(echo "$matches" | jq -r '.road' | grep -v null | sort -u))

    if [[ ${#countries[@]} -eq 1 && ${#regions[@]} -eq 1 && ${#cities[@]} -eq 1 ]]; then
        locale="${regions[0]} ${cities[0]} ${roads[*]}"
    elif [[ ${#countries[@]} -eq 1 && ${#regions[@]} -eq 1 ]]; then
        locale="${regions[0]} (${#cities[@]} cities)"
    elif [[ ${#countries[@]} -eq 1 ]]; then
        locale="${countries[0]} (${#regions[@]} regions)"
    else
        locale="${#countries[@]} countries"
    fi

    locale=$(echo "$locale" | tr -d '"'| sed "s/'/''/g")
    mysql probeprint <<< "UPDATE ssid_intel SET location='${locale}' WHERE ssid_hex='$ssid_hex';"

    echo "$ssid_hex → $locale"
}

# Run on all entries where location is null
while read -r ssid_hex; do
    summarize_location "$ssid_hex"
done <<< "$(mysql -N probeprint <<< "SELECT ssid_hex FROM ssid_intel WHERE location IS NULL;")"

