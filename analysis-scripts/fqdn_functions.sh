#!/bin/bash
# check_fqdn -- SSIDs that are domain names.
#
# An SSID like "deltawifi.com" or "aainflight.com" is a domain, and a domain is
# a much stronger identifier than a household nickname: it names an operator
# rather than a person, and it is directly resolvable.
check_fqdn () {
	echo check_fqdn start $(date +"%H:%M:%S.%3N")

	# Load the TLD list once instead of re-reading it for every SSID.
	# https://data.iana.org/TLD/tlds-alpha-by-domain.txt
	local -A tlds=()
	local domain
	while read -r domain; do
		[ -n "$domain" ] && tlds[${domain,,}]=1
	done < lists/domains.txt

	# Batched. This forked `xxd` and `tr` per candidate row and issued a `mysql`
	# per match; on a real collection that made it the slowest pass in the
	# pipeline by a wide margin -- slower than everything else combined.
	#
	# The decode and the non-printable strip both move into SQL. regexp_replace
	# reproduces `tr -cd '[:print:]'` exactly, which matters: a trailing control
	# byte would otherwise leave the TLD as "com\x01" and match nothing.
	#
	# Rows whose hex holds a null byte are excluded -- bash drops NUL in command
	# substitution, so the comparison would silently be against a different
	# string.
	local sqlf; sqlf=$(mktemp)
	local ssid_hex ssid tld n=0

	echo "start transaction;" > "$sqlf"
	while IFS='|' read -r ssid_hex ssid; do
		[ -z "$ssid_hex" ] && continue

		case "$ssid" in
			*.*) tld=${ssid##*.} ;;
			*)   continue ;;
		esac
		[ -z "$tld" ] && continue

		if [[ -n ${tlds[${tld,,}]:-} ]]; then
			printf 'update ssid_intel set category="OTHER_FQDN" where ssid_hex="%s";\n' \
				"$ssid_hex" >> "$sqlf"
			n=$((n + 1))
			[ $((n % 500)) -eq 0 ] && { echo "commit;" >> "$sqlf"; echo "start transaction;" >> "$sqlf"; }
		fi
	done <<< "$(mysql -N probeprint <<< "
		select concat_ws('|', ssid_hex,
		                 regexp_replace(unhex(ssid_hex), '[^[:print:]]', ''))
		  from ssid_intel
		 where (category is null or category = 'OTHER_UNKNOWN')
		   and ssid_hex not like '%00%';")"
	echo "commit;" >> "$sqlf"
	mysql probeprint < "$sqlf"
	rm -f "$sqlf"

	echo "  SSIDs that are domain names: $n"
	echo check_fqdn stop $(date +"%H:%M:%S.%3N")
}
