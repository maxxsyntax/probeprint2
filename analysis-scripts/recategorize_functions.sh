#!/bin/bash
# Second-pass categorization for SSIDs the keyword tables could not place, and
# operator/market enumeration for the ones that are consumer premises equipment.
#
# categorize() assigns OTHER_UNKNOWN to everything its keyword lists miss, which
# on a real collection is most of the corpus. Two things can still be recovered
# from those names without any new data source:
#
#   structure   Router defaults have shapes, not just brand names. A trailing
#               MAC fragment, a band suffix, an extender marker -- none of which
#               any keyword can enumerate, because the variable part is the
#               device's own address.
#   operator    lists/cpe_isp.txt maps CPE brands to the market they sell in.
#               That turns "this is a router" into "this is a router belonging
#               to a Bouygues subscriber in France", which is the strongest
#               residential-origin signal this pipeline produces.
#
# Nothing here ever overwrites a category that was already decided. The pass
# reads OTHER_UNKNOWN and NULL only, so it is safe to re-run and cannot undo
# the work of categorize(), check_name(), check_fqdn() or check_language().

# --- keyword-free structural patterns ---------------------------------------
#
# Each is a shape a human would recognize as a router or appliance name, chosen
# for precision rather than reach. Anything ambiguous is deliberately left as
# OTHER_UNKNOWN rather than guessed at.

# A trailing fragment of the device's own MAC. Covers ARRIS-177A, Claro-4DD1,
# casttv-3F17, HUB42NK1_1E85, TURBONETT_05A97F and the rest of that family.
RECAT_RE_MACSUFFIX='[-_][0-9A-Fa-f]{4,12}$'

# Band-split SSIDs, where a router publishes the same name on both radios. Only
# matched as a suffix: "Galaxy A53 5G 0F92" is a phone, "Jacaranda-5G" is not.
RECAT_RE_BAND='[-_. ](5|2\.4|24)[Gg]([Hh]z)?$'

# Range extenders and repeaters, which are CPE by any reading.
RECAT_RE_EXT='[-_](ext|EXT|Ext|rpt|RPT|repeater|Repeater|extender|Extender|plus|PLUS)$'

# Nothing but digits and separators: phone numbers, street numbers, dates,
# and the occasional IP address left in a router's factory name.
RECAT_RE_NUMERIC='^[0-9][0-9.:_-]*$'

# Guest access, in the languages this collection actually sees.
RECAT_RE_GUEST='guest|invitado|invitados|invit[eé]s|g[aä]ste|ospiti|convidado|h[uú]espede?s?|visitante'

# Consumer appliances that publish their own SSID.
RECAT_RE_IOT='chromecast|casttv|roku|firetv|kindle|alexa|echodot|nest|wyze|shelly|tasmota|lednet|smartlife|tuya|govee|meross|ecovacs|roborock|printer|scanner|thermostat|doorbell|camera|ipcam'

# --- patterns found by mining the residual set on a real collection ----------
#
# The three below came out of tokenizing 41,093 leftover names and keeping only
# tokens shared by five or more SSIDs -- a token in one SSID is somebody's
# surname, a token in fifty is a category.

# Generic "this is a network" words, matched only as a trailing token so that a
# name merely containing them is not swept up. On the mined collection the
# trailing forms alone accounted for over a thousand names: _network 337,
# _wifi 117, -wifi 113, -fi 112, -net 59, -wireless 53, -home 47.
RECAT_RE_NETNAME='[-_ ](net|network|netzwerk|netwerk|rete|red|wifi|wi-?fi|fi|wlan|wireless|lan|router|hotspot|ap|link|adsl|fibra|fibre)$'

# Workplace and access-tier markers. These say "this network belongs to an
# organization", which is the employer signal the engagement is after.
RECAT_RE_ORG='(^|[^a-z])(staff|corp|corporate|office|oficina|admin|clientes|personal|empleados|employees|reception|recepcion|bureau|buro)([^a-z]|$)'

# Household markers. Distinct from check_name(), which extracts an actual given
# name -- these say "a residence" even when no name is recoverable, and on this
# collection they were among the most frequent leftover tokens: family 49,
# fam 29, dom 25.
RECAT_RE_HOUSE='(^|[^a-z])(family|famille|familie|fam|casa|maison|haus|huis|dom|hogar|household|home)([^a-z]|$)'

# recategorize_unknown [--include-null]
#
# Walk everything still marked OTHER_UNKNOWN and try the structural patterns and
# the CPE brand list against it.
recategorize_unknown () {
	local scope="category = \"OTHER_UNKNOWN\""
	[ "${1:-}" = "--include-null" ] && scope="(category = \"OTHER_UNKNOWN\" or category is null)"

	echo "recategorize_unknown start $(date +"%H:%M:%S.%3N")"

	# CPE brand keywords, lowercased once for case-insensitive matching.
	local -a CPE_KW CPE_ISP CPE_CC CPE_SCOPE
	local kw isp cc sc
	while IFS='|' read -r kw isp cc sc; do
		case "$kw" in ''|'#'*) continue ;; esac
		CPE_KW+=("${kw,,}"); CPE_ISP+=("$isp"); CPE_CC+=("$cc"); CPE_SCOPE+=("$sc")
	done < lists/cpe_isp.txt
	echo "  loaded ${#CPE_KW[@]} CPE brand keywords"

	local ssid_hex ssid lower i cat isp_hit cc_hit sc_hit
	local n_cpe_brand=0 n_cpe_shape=0 n_guest=0 n_iot=0 n_numeric=0 n_left=0 batch=0
	local n_org=0 n_house=0 n_netname=0

	# unhex() in SQL rather than xxd per row -- a subprocess per SSID is what
	# made assign_aliases unusable at scale. Newlines are flattened so the
	# line-oriented read below stays aligned; the decoded text is only used for
	# matching, never stored.
	local _sqlf; _sqlf=$(mktemp)
	{
		echo "start transaction;"
		while IFS='|' read -r ssid_hex ssid; do
			[ -z "$ssid_hex" ] && continue
			lower=${ssid,,}
			cat=""; isp_hit=""; cc_hit=""; sc_hit=""

			# 1. A known operator brand is the most informative answer.
			for i in "${!CPE_KW[@]}"; do
				case "$lower" in
					*"${CPE_KW[$i]}"*)
						cat="TECH_CPE"
						isp_hit=${CPE_ISP[$i]}; cc_hit=${CPE_CC[$i]}; sc_hit=${CPE_SCOPE[$i]}
						break ;;
				esac
			done
			[ -n "$cat" ] && n_cpe_brand=$((n_cpe_brand+1))

			# 2. Otherwise, does it have the shape of a router default?
			if [ -z "$cat" ]; then
				if [[ "$ssid" =~ $RECAT_RE_MACSUFFIX ]] \
				   || [[ "$ssid" =~ $RECAT_RE_BAND ]] \
				   || [[ "$ssid" =~ $RECAT_RE_EXT ]]; then
					cat="TECH_CPE"; n_cpe_shape=$((n_cpe_shape+1))
				fi
			fi

			# 3. Then the narrower classes, most informative first. Workplace
			#    and residence markers are what the engagement is actually
			#    after, so they are tried before the generic network words that
			#    only say "this is a router".
			if [ -z "$cat" ] && [[ "$lower" =~ $RECAT_RE_GUEST ]]; then
				cat="TECH_GUEST"; n_guest=$((n_guest+1))
			fi
			if [ -z "$cat" ] && [[ "$lower" =~ $RECAT_RE_ORG ]]; then
				cat="BIZ_STAFF"; n_org=$((n_org+1))
			fi
			if [ -z "$cat" ] && [[ "$lower" =~ $RECAT_RE_HOUSE ]]; then
				cat="OTHER_HOUSEHOLD"; n_house=$((n_house+1))
			fi
			if [ -z "$cat" ] && [[ "$lower" =~ $RECAT_RE_IOT ]]; then
				cat="TECH_IOT"; n_iot=$((n_iot+1))
			fi
			if [ -z "$cat" ] && [[ "$lower" =~ $RECAT_RE_NETNAME ]]; then
				cat="TECH_CPE"; n_netname=$((n_netname+1))
			fi
			if [ -z "$cat" ] && [[ "$ssid" =~ $RECAT_RE_NUMERIC ]]; then
				cat="OTHER_NUMERIC"; n_numeric=$((n_numeric+1))
			fi

			if [ -z "$cat" ]; then
				n_left=$((n_left+1)); continue
			fi

			printf 'update ssid_intel set category="%s"' "$cat"
			[ -n "$isp_hit" ] && printf ', cpe_isp="%s"' "${isp_hit//\"/}"
			[ -n "$cc_hit" ]  && printf ', cpe_country="%s"' "${cc_hit//\"/}"
			[ -n "$sc_hit" ]  && printf ', cpe_scope="%s"' "${sc_hit//\"/}"
			printf ' where ssid_hex="%s";\n' "$ssid_hex"

			batch=$((batch+1))
			[ $((batch % 500)) -eq 0 ] && { echo "commit;"; echo "start transaction;"; }
		done <<< "$(mysql -N probeprint <<< "
			select concat_ws('|', ssid_hex,
			                 replace(replace(unhex(ssid_hex), '\n', ' '), '\r', ' '))
			  from ssid_intel
			 where $scope
			   and ssid_hex not like '%00%'
			   and ssid_hex not like '%fff%';")"
		echo "commit;"
	} > "$_sqlf"
	mysql probeprint < "$_sqlf"
	rm -f "$_sqlf"

	echo "  -> TECH_CPE from an operator brand : $n_cpe_brand"
	echo "  -> TECH_CPE from name shape only   : $n_cpe_shape"
	echo "  -> TECH_GUEST                      : $n_guest"
	echo "  -> BIZ_STAFF (workplace marker)    : $n_org"
	echo "  -> OTHER_HOUSEHOLD (residence)     : $n_house"
	echo "  -> TECH_CPE from generic net word  : $n_netname"
	echo "  -> TECH_IOT                        : $n_iot"
	echo "  -> OTHER_NUMERIC                   : $n_numeric"
	echo "  still OTHER_UNKNOWN                : $n_left"
	echo "recategorize_unknown stop $(date +"%H:%M:%S.%3N")"
}

# enumerate_cpe_region
#
# Fill cpe_isp / cpe_country / cpe_scope for every SSID already sitting in
# TECH_CPE, including the ones categorize() placed there by keyword long before
# this pass existed.
#
# scope is carried through deliberately. 'country' is a single national market
# and worth acting on; 'region' narrows to a group of markets; 'global' and
# 'vendor' carry no geography at all, and vendor rows are recorded precisely so
# that a NETGEAR router is never mistaken for evidence of a location.
enumerate_cpe_region () {
	echo "enumerate_cpe_region start $(date +"%H:%M:%S.%3N")"

	local -a CPE_KW CPE_ISP CPE_CC CPE_SCOPE
	local kw isp cc sc
	while IFS='|' read -r kw isp cc sc; do
		case "$kw" in ''|'#'*) continue ;; esac
		CPE_KW+=("${kw,,}"); CPE_ISP+=("$isp"); CPE_CC+=("$cc"); CPE_SCOPE+=("$sc")
	done < lists/cpe_isp.txt

	local ssid_hex ssid lower i n=0 batch=0
	local _sqlf; _sqlf=$(mktemp)
	{
		echo "start transaction;"
		while IFS='|' read -r ssid_hex ssid; do
			[ -z "$ssid_hex" ] && continue
			lower=${ssid,,}
			for i in "${!CPE_KW[@]}"; do
				case "$lower" in
					*"${CPE_KW[$i]}"*)
						printf 'update ssid_intel set cpe_isp="%s", cpe_country="%s", cpe_scope="%s" where ssid_hex="%s";\n' \
							"${CPE_ISP[$i]//\"/}" "${CPE_CC[$i]//\"/}" "${CPE_SCOPE[$i]//\"/}" "$ssid_hex"
						n=$((n+1)); batch=$((batch+1))
						break ;;
				esac
			done
			[ $((batch % 500)) -eq 0 ] && [ "$batch" -gt 0 ] && { echo "commit;"; echo "start transaction;"; }
		done <<< "$(mysql -N probeprint <<< "
			select concat_ws('|', ssid_hex,
			                 replace(replace(unhex(ssid_hex), '\n', ' '), '\r', ' '))
			  from ssid_intel
			 where category = 'TECH_CPE' and cpe_isp is null
			   and ssid_hex not like '%00%';")"
		echo "commit;"
	} > "$_sqlf"
	mysql probeprint < "$_sqlf"
	rm -f "$_sqlf"

	echo "  operators identified: $n"
	echo "enumerate_cpe_region stop $(date +"%H:%M:%S.%3N")"
}

# cpe_region_report
#
# Which national markets the collection's routers belong to. Only 'country'
# scope is a claim about one place; the rest are shown separately so a Vodafone
# or a NETGEAR is never read as evidence of origin.
cpe_region_report () {
	echo "=== residential origin, by operator market ==="
	printf '  %-30s %-26s %6s\n' "operator" "market" "ssids"
	mysql -N probeprint <<'SQL' | awk -F'\t' '{ printf "  %-30s %-26s %6s\n", $1, $2, $3 }'
select ifnull(cpe_isp,'-'), ifnull(cpe_country,'-'), count(*)
  from ssid_intel
 where cpe_scope = 'country'
 group by cpe_isp, cpe_country
 order by count(*) desc
 limit 25;
SQL
	echo
	echo "=== weaker: operator spans several markets ==="
	mysql -N probeprint <<'SQL' | awk -F'\t' '{ printf "  %-30s %-40s %6s\n", $1, $2, $3 }'
select cpe_isp, cpe_country, count(*)
  from ssid_intel where cpe_scope = 'region'
 group by cpe_isp, cpe_country order by count(*) desc limit 10;
SQL
	echo
	echo "=== no geography: hardware vendors and global operators ==="
	mysql -N probeprint <<'SQL' | awk -F'\t' '{ printf "  %-30s %-12s %6s\n", $1, $2, $3 }'
select ifnull(nullif(cpe_isp,''),'(unbranded vendor)'), cpe_scope, count(*)
  from ssid_intel where cpe_scope in ('vendor','global','academic')
 group by cpe_isp, cpe_scope order by count(*) desc limit 15;
SQL
}

# recategorize_report
recategorize_report () {
	echo "=== category distribution ==="
	mysql -N probeprint <<'SQL' | awk -F'\t' '{ printf "  %-22s %8s\n", $1, $2 }'
select ifnull(category,'(null)'), count(*)
  from ssid_intel group by category order by count(*) desc limit 30;
SQL
}
