#!/bin/bash
make_ignore_list () {
#if more than 40 devices are probing for the most common ssid's, they will be added to the ignore list.  probably super common SSID's that wont add much value.  Also adds anomalous ssids to ignore list
        echo ignore_check $(date +"%H:%M:%S.%3N")

# -N matters here: without it the column header is written into the file, so
# the literal string "ssid_hex" became an ignore-list entry.
mysql -N probeprint >lists/ignore.txt <<EOF
SELECT ssid_hex
FROM ssid
GROUP BY ssid_hex
HAVING COUNT(DISTINCT wlan_sa) > 40
ORDER BY COUNT(*) DESC
LIMIT 30;
EOF

# Anomalous SSIDs are worth ignoring too. The original make_ignore_list in
# ssid_intel_functions.sh appended these; the standalone rewrite dropped it.
mysql -N probeprint >>lists/ignore.txt <<EOF
SELECT ssid_hex FROM ssid_intel WHERE category = "OTHER_ANOMALOUS";
EOF

        echo ignore_check end $(date +"%H:%M:%S.%3N")
}
make_ignore_list
