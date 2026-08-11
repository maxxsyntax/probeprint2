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
#
# Set-based. The previous form issued one `mysql` UPDATE per row inside a bash
# loop -- on a merged collection that meant ~300k process spawns at 35ms each,
# so it ran for hours and hung analysis.sh. Now the OUI table is loaded into a
# temp table and one UPDATE ... JOIN does the lot. OUI extraction is pure
# parameter expansion in the join (substring + replace), no per-row fork.
mac2vendor () {
	echo "mac2vendor start $(date +"%H:%M:%S.%3N")"
	_load_oui_map

	local sqlf; sqlf=$(mktemp)
	local oui org n=0
	{
		# The OUI map as a temp table, keyed on the uppercase 6-hex assignment.
		# Temp table + the UPDATE must share one mysql session, so both go in
		# this single script piped in below.
		# Collation must match ssid.wlan_sa (utf8mb4_general_ci). Left to the
		# server default -- utf8mb4_uca1400_ai_ci on MariaDB 11 -- the join
		# `o.oui = ...` throws ERROR 1267, illegal mix of collations, and the
		# whole UPDATE silently fails. This is the recurring collation trap in
		# this schema.
		echo "create temporary table _oui (oui char(6) collate utf8mb4_general_ci primary key, org varchar(64)) charset=utf8mb4;"
		# Only 6-hex (MA-L) assignments. oui.csv also carries MA-M (7 hex) and
		# MA-S (9 hex) blocks; truncated to a char(6) key they collide and the
		# duplicate-key error aborts the whole batch before the UPDATE. The
		# original per-row code matched on the MAC's first 6 hex (`cut -b1-6`),
		# so it only ever hit MA-L anyway -- this drops the same rows it did.
		# `insert ignore` is belt-and-suspenders against any residual dup.
		for oui in "${!OUI_MAP[@]}"; do
			[ ${#oui} -eq 6 ] || continue
			org=${OUI_MAP[$oui]//\'/\'\'}     # vendor strings hold apostrophes
			if [ $((n % 1000)) -eq 0 ]; then
				[ "$n" -gt 0 ] && echo ";"
				printf 'insert ignore into _oui (oui,org) values '
			else printf ','; fi
			printf "('%s','%s')" "$oui" "$org"
			n=$((n + 1))
		done
		[ "$n" -gt 0 ] && echo ";"

		# One UPDATE. The subquery is the same "SSID probed by exactly one MAC"
		# filter as before -- an SSID seen from a single address is good evidence
		# that address is the device's real, OUI-bearing one. The OUI is the
		# first three octets of wlan_sa (chars 1-8, "ab:cd:ef"), colons removed,
		# uppercased, matched against _oui. coalesce(...,'.') keeps the "looked
		# up, nothing found" marker display.sh filters on.
		cat <<'SQL'
update ssid s
  join (select ssid_hex from ssid
         where vendor is null
         group by ssid_hex having count(distinct wlan_sa) = 1) one
    on one.ssid_hex = s.ssid_hex
  left join _oui o
    on o.oui = upper(replace(substring(s.wlan_sa, 1, 8), ':', ''))
   set s.vendor = coalesce(o.org, '.')
 where s.vendor is null;
SQL
	} > "$sqlf"
	mysql probeprint < "$sqlf"
	rm -f "$sqlf"

	echo "  vendors resolved : $(mysql -N probeprint <<< "select count(*) from ssid where vendor is not null and vendor <> '.';")"
	echo "mac2vendor stop $(date +"%H:%M:%S.%3N")"
}
