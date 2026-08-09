#!/bin/bash
# Keyword categorization: the `categories` table, the pass that applies it, and
# the anomaly filter that runs first.
#
# The table is declared before `.env` is sourced, which is what lets an
# engagement add categories["INDUSTRY_ORG"] and friends from there. Anything
# needing the table must source this file rather than redeclaring it.
#needed variables
declare -A categories
declare -A categories_hex
categories["BIZ_HOTEL"]="Hotel;\ Inn;casa;Suites;Room;Hostel;Villa;Marriott;Hyatt;Hilton;Stay;Renaissance;Resort;Westin;Radisson;Sofitel;Cottage;IHG;BNB;cabin;Guesthouse;aloft;Courtyard;FourSeasons;ibis\ styles;Lodge"
categories["BIZ_CLUB"]="Member;Members;Club;Social"
categories["BIZ_COWORK"]="Cowork;Wework;Thrive;Officeworks;Cubico;works"
categories["BIZ_EATERY"]="cafe;coffee;brew;burger;grill;starbucks;bakery;Café;Ramen;bar;restaurant;Hortons;mcDonalds;eatery;Bottle;Kaffeine;koffee;PANERA;pizza;kafe;Caffe;Bistro;Krispy;deli;Espresso;Pret;Waffle;bubbletea"
categories["BIZ_HEALTHCARE"]="Health;Podiatry;Kiaser;Medical;Surgery;Patient;skin;Carenow;nci"
categories["BIZ_INSTITUTION"]="University;Hall;Library;Connect;Academy;Oxford;Harvard;Stanford;Berekely;UCLA;Stamford;erudome;MIT;UCONN;myresnet;georgetown;museum;students;Estudiantes"
categories["BIZ_OTHER"]="Store;Business;Visitors;Massage;Health;LLC;Warehouse;carwash;Gucci;Studio;Club;casino;spa;Mall;SAFEWAY;Customer;Adobe;ltd;Shopify;GeekSquad;mercado;shopping"
categories["CULTURE_CAR"]="audi;honda;align;lexus;lube;toyota;tesla;bmw;schwab;HYUNDAI;lube;Datsun;nissan;Cayenne;ford"
categories["CULTURE_RELIGION"]="Jesus"
#customize industry specific in .env file
#categories["INDUSTRY_EVENT"]="attendees"
#categories["INDUSTRY_PERSON"]="N1MJF"
#categories["NAME"]="Family;'s;familia"
categories["OTHER_CREATIVE"]="tubez;nacho"
categories["TECH_CPE"]="TeleCable;Hyperoptic;ARRIS;aWiFi;_extender;MOVISTAR;Bbox_;BELL;BSNL;BTHub;Buffalo;TurkNet;CBCI;CenturyLink;ChinaNet;Claro;CLARO;Direct_;FASTWEB;Fibertel;Fios;Franklin;T10;Freebox_;FREEBOX_;Frontier;Google;H3C_;HOME_;KT_GiGA;LIB_;lib_;Livebox_Hex;MEO_Hex;MiFibra_Hex;MIFI;MOTO;MyAltice;MySpectrum;NET_;NETGEAR;Nokia_;Starlink;ORBI;Zyxel_;Ziggo;WLAN_;Vodafone;Verizion;TP_Link_;TELUS;SpectrumSetup;SINGTEL;SETUP_;Redmi;2WIRE;Linksys;CoxWiFi;attwifi;livebox;tigo;MEGACABLE;TP-Link;eduroam;CDMX-Internet;ATTfiber;MIWIFI;LIB-;Telekom-;ATT;skyfi;NextGenTel;FRITZ!Box;ubnt;Freebox;Xfinity;Tienda;LinkNYC;5099251212;Proximus"
categories["TECH_OTHER"]="ASUS;Apple;WebOS;ZHIYUN;Sonos_"
# `X3` was here for the POCO X3, but every keyword is matched as an unanchored
# substring, so it claimed any SSID containing those two characters -- and cost
# real intel doing it. BTHub3-GX3R, ChinaNet-DQX3, Fios-X3WPS and SINGTEL-KX3M
# are CPE with an identifiable operator, and TECH_PHONE swallowed them: because
# recategorize only examines OTHER_UNKNOWN, their cpe_isp was then never
# derived, losing BT, China Telecom, Verizon Fios and Singtel. `POCO` on its own
# already catches the phone.
categories["TECH_PHONE"]="AndroidAP;Pixel;Galaxy;Huawei;iPad;LGWiFi;nova;POCO;Samsung;tmobile;TMOBILE;TMobile;Xiaom;Verizon;telefono;phone"
categories["TECH_PRINTER"]="Canon_;DIRECT_;HP_Print_;HP-Setup"
categories["TRAVEL"]="Lounge;AERO;AIRPORT;United;Lounge;Airlines;Amtrak;Delta;Boingo;GoGo;_Free;Fly;SouthwestWiFi;Terminal;aainflight.com;SANfreewifi;trein;aa-guest"
categories["LOCATION_VAGUE"]="Marina;beach;Harbor;Apartment;FLAT;Lobby;cdmx;river;Tour_Eiffel;stadium;Athens"
#customize in .env file
#categories["INDUSTRY_VIP"]="XXX"
categories["CULTURE_LUXURY"]="Estates;lux;yatch;social;marina;penthouse;jetex;ginza"


source .env

check_anomalies () {
	mysql probeprint <<< "UPDATE ssid_intel
SET category = \"OTHER_ANOMALOUS\"
WHERE (
    ssid_hex LIKE '%00'
    OR ssid_hex LIKE '%00%'
    OR ssid_hex LIKE '%ff%'
    OR CONV(LEFT(ssid_hex, 1), 16, 10) >= 8
    OR CONV(LEFT(ssid_hex, 1), 16, 10) <= 2
)
AND category IS NULL;";
	mysql probeprint <<< "update ssid_intel set category=\"OTHER_ANOMALOUS\" where (ssid_hex like '7c%') and category is null;"
}

categorize () {
	echo categorize start $(date +"%H:%M:%S.%3N")
	mysql probeprint <<< "update ssid_intel set category=\"OTHER_ANOMALOUS\" where (ssid_hex like '%00' or ssid_hex like '%000%' or ssid_hex like '%fff%' or ssid_hex like '8%' or ssid_hex like '1%') and category is null;"

	# Batched. The previous form cost, per SSID: an `xxd` fork to decode it, a
	# re-split of every category's keyword string, ~700 individual regex tests,
	# and a separate `mysql` invocation for every keyword that matched. On this
	# host a `mysql` invocation is 35ms against 0.82ms for the same statement in
	# an open session, so the process spawn dominated everything.
	#
	# Three changes, no change to what matches:
	#   - decode in SQL (`convert(unhex(...))`), so no fork per row
	#   - build the keyword regexes ONCE, one alternation per category, so a row
	#     costs ~20 regex tests instead of ~700
	#   - collect the verdicts and write them as chunked `IN (...)` updates
	#
	# Category order is sorted rather than the hash order of `${!categories[@]}`.
	# The loop does not stop at the first match, so the last matching category
	# wins -- which under hash order made the result non-deterministic between
	# runs. Sorted, the same SSID always lands in the same category.
	local -a cat_name=() cat_re=()
	local cat k re
	local -a arr
	while read -r cat; do
		IFS=";" read -r -a arr <<< "${categories[$cat]}"
		re=""
		for k in "${arr[@]}"; do
			[ -z "$k" ] && continue
			# Each keyword is used as a regex, as it always has been -- that is
			# why `aainflight.com` and `FRITZ!Box` work. Joining them with `|`
			# keeps that and tests the whole category in one go.
			re="${re:+$re|}${k,,}"
		done
		[ -z "$re" ] && continue
		cat_name+=("$cat")
		cat_re+=("($re)")
	done < <(printf '%s\n' "${!categories[@]}" | sort)
	echo "  ${#cat_name[@]} categories, matched as one alternation each"

	local sqlf; sqlf=$(mktemp)
	local -A hits=()
	local ssid_hex ssid hit i n=0

	# An SSID containing a null byte cannot survive command substitution -- bash
	# drops the NUL and warns -- so those rows are left for the OTHER_UNKNOWN
	# sweep below rather than being matched against a mangled string.
	while IFS='|' read -r ssid_hex ssid; do
		[ -z "$ssid_hex" ] && continue
		hit=""
		for ((i = 0; i < ${#cat_re[@]}; i++)); do
			[[ "${ssid,,}" =~ ${cat_re[i]} ]] && hit=${cat_name[i]}
		done
		[ -z "$hit" ] && continue
		hits[$hit]="${hits[$hit]:-} \"$ssid_hex\""
		n=$((n + 1))
	done <<< "$(mysql -N probeprint <<SQL
select concat_ws('|', ssid_hex, convert(unhex(ssid_hex) using utf8mb4))
  from ssid_intel
 where category is null
   and ssid_hex not like '%00%';
SQL
)"

	# One statement per category, chunked so none grows unbounded.
	local -a ids
	for cat in "${!hits[@]}"; do
		read -r -a ids <<< "${hits[$cat]}"
		for ((i = 0; i < ${#ids[@]}; i += 1000)); do
			printf 'update ssid_intel set category="%s" where ssid_hex in (%s);\n' \
				"$cat" "$(printf '%s,' "${ids[@]:i:1000}" | sed 's/,$//')" >> "$sqlf"
		done
	done
	[ -s "$sqlf" ] && mysql probeprint < "$sqlf"
	rm -f "$sqlf"
	echo "  categorized by keyword : $n"

	mysql probeprint <<< "update ssid_intel set category = \"OTHER_UNKNOWN\"  where category is null;"
	echo categorize stop $(date +"%H:%M:%S.%3N")
}
