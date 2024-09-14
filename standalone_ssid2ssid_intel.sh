ssid2ssid_intel () {
echo ssid2ssid_intel start $(date +"%H:%M:%S.%3N")
mysql probeprint <<< "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid ;"
echo ssid2ssid_intel stop $(date +"%H:%M:%S.%3N")
}
