make_ignore_list () {   
#if more than 40 devices are probing for the most common ssid's, they will be added to the ignore list.  probably super common SSID's that wont add much value.  Also adds anomalous ssids to ignore list
        echo ignore_check $(date +"%H:%M:%S.%3N")
        > lists/ignore.txt
mysql probeprint >lists/ignore.txt <<EOF
SELECT ssid_hex
FROM ssid
GROUP BY ssid_hex
HAVING COUNT(DISTINCT wlan_sa) > 40
ORDER BY COUNT(*) DESC
LIMIT 30;
EOF


}
make_ignore_list
