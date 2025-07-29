mac2vendor() {
    # Build an associative array mapping OUI -> vendor (once!)
    declare -A oui_map
    while IFS=, read -r prefix _ vendor1 vendor2 _; do
        oui="${prefix//[^a-fA-F0-9]/}"  # Remove non-hex chars
        vendor="${vendor1:0:20} ${vendor2:0:20}"
        oui_map["${oui^^}"]="${vendor//\"/}"  # Uppercase, strip quotes
    done < lists/oui.csv

    # Process rows from MySQL
    mysql -N -B probeprint <<< "
        SELECT wlan_sa, ssid_hex
        FROM ssid
        WHERE vendor IS NULL
        GROUP BY ssid_hex
        HAVING COUNT(DISTINCT wlan_sa) = 1;
    " | while IFS=$'\t' read -r mac ssid_hex; do

        oui="${mac//:/}"        # Remove colons
        oui="${oui:0:6}"        # First 6 hex chars
        vendor="${oui_map[${oui^^}]}"

        if [[ -n "$vendor" ]]; then
            mysql probeprint <<< "
                UPDATE ssid
                SET vendor = '$(mysql_escape "$vendor")'
                WHERE ssid_hex = '$ssid_hex' AND wlan_sa = '$mac';
            "
        else
            mysql probeprint <<< "
                UPDATE ssid
                SET vendor = '.'
                WHERE ssid_hex = '$ssid_hex' AND wlan_sa = '$mac';
            "
        fi
    done
}
mac2vendor

