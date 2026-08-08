#!/bin/bash
# READ ONLY. Reports rows that look like they were written by the old ingest
# parser, which shifted columns left past any empty tshark field.
#
# This script never writes to the database. It exists because the ingest fix
# stops new corruption but cannot repair rows already stored -- run it against a
# collection to find out whether historical data is affected, and how badly,
# before deciding whether a re-import from the original captures is worth it.
#
# Usage: ./analysis-scripts/diagnose_legacy_rows.sh
set -uo pipefail

echo "=============================================================="
echo " probeprint2 legacy row diagnostic (read-only)"
echo "=============================================================="
echo

total=$(mysql -N probeprint -e "select count(*) from ssid;")
echo "total rows in ssid: $total"
if [ "$total" -eq 0 ]; then
	echo "nothing to check"
	exit 0
fi

report () {
	local label=$1 where=$2
	local n
	n=$(mysql -N probeprint -e "select count(*) from ssid where $where;")
	printf '  %-52s %8s\n' "$label" "$n"
}

echo
echo "-- signatures of a left-shifted row ------------------------------"
# An epoch timestamp landing in rssi is the clearest tell: it means the ssid or
# wlan_sa field was empty and everything moved up one place.
report "rssi holds an epoch timestamp"          "rssi regexp '^1[0-9]{9}'"
# A frequency outside the wifi bands means the sequence number shifted into it.
report "freq outside 2400-7200 MHz"             "freq is not null and (freq < 2400 or freq > 7200)"
# vht should be 0x-prefixed hex; a bare integer there is a shifted seq.
report "vht looks like a sequence number"       "vht is not null and vht <> '' and vht not like '0x%'"
# A MAC always contains colons.
report "wlan_sa is not MAC-shaped"              "wlan_sa is not null and wlan_sa not regexp '^([0-9a-f]{2}:){5}[0-9a-f]{2}\$'"
# ssid_hex must be hex, or the <MISSING> sentinel.
report "ssid_hex is neither hex nor <MISSING>"  "ssid_hex <> '<MISSING>' and ssid_hex regexp '[^0-9a-fA-F]'"
# seq is a 12-bit field, so anything above 4095 did not come from wlan.seq.
report "seq above the 12-bit 802.11 maximum"    "seq is not null and seq > 4095"

echo
echo "-- context -------------------------------------------------------"
report "rows with no rssi"                      "rssi is null or rssi = ''"
report "rows with no vht"                       "vht is null or vht = ''"
report "broadcast (<MISSING>) rows"             "ssid_hex = '<MISSING>'"

echo
suspect=$(mysql -N probeprint -e "
select count(*) from ssid where
    rssi regexp '^1[0-9]{9}'
 or (freq is not null and (freq < 2400 or freq > 7200))
 or (vht is not null and vht <> '' and vht not like '0x%')
 or (seq is not null and seq > 4095);")

echo "=============================================================="
printf ' suspect rows: %s of %s\n' "$suspect" "$total"
if [ "$suspect" -eq 0 ]; then
	echo " No evidence of shifted rows."
else
	pct=$(echo "scale=2; 100 * $suspect / $total" | bc)
	echo " ${pct}% of rows look shifted."
	echo
	echo " These cannot be repaired in place -- the discarded field is gone."
	echo " If the original captures still exist, re-importing them with the"
	echo " fixed pcap2db.sh is the only way to recover the real values."
	echo " Nothing has been modified by this script."
fi
echo "=============================================================="
