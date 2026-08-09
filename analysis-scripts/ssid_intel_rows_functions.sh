#!/bin/bash
# Populate ssid_intel with one row per distinct SSID. Every enrichment pass is
# driven by null columns on those rows, so this runs before all of them.
ssid2ssid_intel () {
#	while true; do 
echo ssid2ssid_intel start $(date +"%H:%M:%S.%3N")
mysql probeprint <<< "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid;"
echo ssid2ssid_intel stop $(date +"%H:%M:%S.%3N")
}
