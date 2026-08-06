#!/bin/bash
# OUI -> vendor lookup for probe-request source addresses.
#
# Shared by ssid_intel_functions.sh (sourced by build_ssid_intel.sh) and
# standalone_mac2vendor.sh, so the two cannot drift.
#
# Selecting SSIDs probed by exactly one MAC is deliberate: a device with a
# randomized address re-probes the same SSID under several addresses, so an SSID
# seen from a single MAC is good evidence that MAC is the device's real,
# OUI-bearing address. This leaves false negatives but filters out most
# randomized addresses, which have no registered OUI anyway.

# _load_oui_map
# Read lists/oui.csv once into the OUI_MAP associative array, keyed by uppercase
# 6-hex-digit assignment. The previous implementation ran `grep -i $oui` against
# the 3MB csv once per row.
_load_oui_map () {
	declare -gA OUI_MAP=()
	local registry assignment org rest

	while IFS=, read -r registry assignment org rest; do
		[ "$registry" = "Registry" ] && continue     # header
		[ -z "$assignment" ] && continue
		# Organization Name is quoted when it contains a comma ("Google, Inc.").
		# Strip the quotes; the trailing fragment after the comma lands in
		# $rest, which is fine because the address is not wanted anyway.
		org=${org#\"}
		org=${org%\"}
		OUI_MAP[${assignment^^}]=${org:0:20}
	done < lists/oui.csv
}

# mac2vendor
# Fill ssid.vendor for every SSID probed by exactly one MAC address.
mac2vendor () {
	echo "mac2vendor start $(date +"%H:%M:%S.%3N")"
	_load_oui_map

	local row wlan_sa ssid_hex oui vendor

	# concat_ws with an explicit delimiter: mysql -N separates columns with
	# tabs, and this function used to set a global `IFS=\|` before splitting
	# with `arr=($line)`. That meant the tab was never a delimiter, so arr[1]
	# was always empty and every UPDATE matched zero rows -- mac2vendor has
	# never actually written a vendor.
	while IFS='|' read -r wlan_sa ssid_hex; do
		[ -z "$wlan_sa" ] && continue

		oui=$(printf '%s' "$wlan_sa" | tr -d ':' | cut -b1-6)
		vendor=${OUI_MAP[${oui^^}]:-}

		# '.' is the established "looked up, nothing found" marker; display.sh
		# filters it out of the operator view.
		[ -z "$vendor" ] && vendor='.'

		# Single-quote the value and double any embedded quote: vendor strings
		# come from a third-party CSV and contain apostrophes ("W. L. Gore",
		# "O'Neil").
		vendor=${vendor//\'/\'\'}

		mysql probeprint <<< "update ssid set vendor='$vendor' where ssid_hex=\"$ssid_hex\" and wlan_sa=\"$wlan_sa\";"
	done <<< "$(mysql -N probeprint <<< "select concat_ws('|',wlan_sa,ssid_hex) from ssid where vendor is null group by ssid_hex HAVING count(DISTINCT wlan_sa) = 1;")"

	echo "mac2vendor stop $(date +"%H:%M:%S.%3N")"
}
