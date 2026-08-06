#!/bin/bash
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
categories["TECH_PHONE"]="AndroidAP;Pixel;Galaxy;Huawei;iPad;LGWiFi;nova;POCO;X3;Samsung;tmobile;TMOBILE;TMobile;Xiaom;Verizon;telefono;phone"
categories["TECH_PRINTER"]="Canon_;DIRECT_;HP_Print_;HP-Setup"
categories["TRAVEL"]="Lounge;AERO;AIRPORT;United;Lounge;Airlines;Amtrak;Delta;Boingo;GoGo;_Free;Fly;SouthwestWiFi;Terminal;aainflight.com;SANfreewifi;trein;aa-guest"
categories["LOCATION_VAGUE"]="Marina;beach;Harbor;Apartment;FLAT;Lobby;cdmx;river;Tour_Eiffel;stadium;Athens"
#customize in .env file
#categories["INDUSTRY_VIP"]="XXX"
categories["CULTURE_LUXURY"]="Estates;lux;yatch;social;marina;penthouse;jetex;ginza"

source .env
source ./vendor_functions.sh
source ./rarity_functions.sh
source ./industry_functions.sh
source ./geolocate_functions.sh
source ./location_functions.sh


#functions
ssid2ssid_intel () {
#	while true; do 
echo Populating ssid_intel
mysql probeprint <<< "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid;"
sleep 5; 
#done
}


check_common () {
	while read ssid_hex; 
	do
 	ssid=$(echo -n $ssid_hex | xxd -r -p)
	#bug found matching on anomalous characters
	#mark ignore as common,for simplicity
	#need to include ssids with wigle results > 100
	if egrep -q ",$ssid$" lists/ssid.csv || egrep -q "^$ssid_hex$" lists/ignore.txt;
		then
			#echo common
		#echo $x matches most common ssid
		#bug here "enelguest" should not be labeled as common
		#sqlite3 new.db "update ssid_intel set category = \"OTHER_COMMON\" where ssid_hex=\"$ssid_hex\" and category is NULL;"
		mysql probeprint <<< "update ssid_intel set is_common=1 where ssid_hex=\"$ssid_hex\";"
	else 
		mysql probeprint <<< "update ssid_intel set is_common=0 where ssid_hex=\"$ssid_hex\";"
	fi
# 5a: an embedded 00 byte marks a frame that is not a real network name, so
# exclude %00% and a trailing %00 as well as the anomalous 1/2/8 hex prefixes.
done <<< $(mysql -N probeprint <<<"select ssid_hex from ssid_intel where is_common is null and ssid_hex not like '1%' and ssid_hex not like '2%' and ssid_hex not like '8%' and ssid_hex not like '%00%' and ssid_hex not like '%00';")

}



categorize () {
#while true;
#do
	echo categorize start $(date +"%H:%M:%S.%3N")
	mysql probeprint <<< "update ssid_intel set category=\"OTHER_ANOMALOUS\" where (ssid_hex like '%00' or ssid_hex like '%000%' or ssid_hex like '%fff%' or ssid_hex like '8%' or ssid_hex like '1%') and category is null;"
	while read ssid_hex; 
	do
 		ssid=$(echo -n $ssid_hex | xxd -r -p)
		for cat in "${!categories[@]}"; do
			keywords="${categories[$cat]}"	
			#echo $cat $keywords
			IFS=";" read -r -a arr <<< "${keywords}"
 			for keyword in ${arr[@]}; do
 				if [[ "${ssid,,}" =~ ${keyword,,} ]] 
				then
					#echo $ssid contains $keyword and category is $cat
					mysql probeprint <<< "update ssid_intel set category = \"$cat\" where ssid_hex = \"$ssid_hex\";"
					#echo $ssid $cat
				fi
 			done
		done
	done <<< $(mysql -N probeprint <<< "select ssid_hex from ssid_intel where category is null;")
#bug where next line is nullifed on ssids starting with special character
	mysql probeprint <<< "update ssid_intel set category = \"OTHER_UNKNOWN\"  where category is null;"
	echo categorize stop $(date +"%H:%M:%S.%3N")
#done
}


# check_industry now lives in industry_functions.sh, sourced at the top of
# this file, so the standalone script and this one cannot drift.


check_airport () {
	#while true; do
echo Airport check start $(date +"%H:%M:%S.%3N")
#IFS is scoped to the read rather than set globally. This file is sourced into
#one shell, so a bare `IFS=\|` leaked into every function that ran afterwards --
#and because mysql -N output is tab separated, a leaked pipe IFS made
#`arr=($row)` swallow whole rows into arr[0].
while IFS='|' read -r iata description; do
	 iata_hex=$(printf '%s' "$iata" | xxd -p)
	 mysql probeprint <<< "update ssid_intel set is_airport=\"$description\" where ssid_hex like \"$iata_hex%\" or ssid_hex like '%$iata_hex%'; "
done < lists/airports.txt
mysql probeprint <<< "update ssid_intel set is_airport=0 where is_airport is null;"
#done
echo Airport check stop $(date +"%H:%M:%S.%3N")
}


check_name () {
	#need to look for one space or 2 spaces if there's an iphone
	#while true; do
echo check_name start $(date +"%H:%M:%S.%3N")
	#need to only work on unprocessed

#look for 's\ 

while read ssid_hex; do
	name=$(echo $ssid_hex | sed 's/277320.*//g' | xxd -r -p| tr -cd '[:print:]')
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where ssid_hex=\"$ssid_hex\";"
#	echo $ssid_hex $name
done <<< $(mysql -N probeprint <<< "select ssid_hex from ssid_intel where ssid_hex like \"%277320%\" and is_name is null;")

#look for Familia
while read ssid_hex; do
	name=$(echo $ssid_hex | sed 's/46616d696c696120//g' | xxd -r -p| tr -cd '[:print:]')
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where ssid_hex=\"$ssid_hex\";"
#	#echo $ssid_hex $name
done <<< $(mysql -N probeprint <<< "select ssid_hex from ssid_intel where ssid_hex like \"46616d696c6961%\" and is_name is null;")

while read ssid_hex; do
	name=$(echo $ssid_hex | sed 's/66616d696c696120//g' | xxd -r -p| tr -cd '[:print:]')
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where ssid_hex=\"$ssid_hex\";"
#	echo $ssid_hex $name
done <<< $(mysql -N probeprint <<< "select ssid_hex from ssid_intel where ssid_hex like \"66616d696c6961%\" and is_name is null;")

while read ssid_hex; do
	name=$(echo $ssid_hex | sed 's/46616d696c79//g' | xxd -r -p| tr -cd '[:print:]')
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where ssid_hex=\"$ssid_hex\";"
	#echo $ssid_hex $name
done <<< $(mysql -N probeprint <<< "select ssid_hex from ssid_intel where ssid_hex like \"%46616d696c79\" and is_name is null;")

#iterate through name list
while read name_hex;
do
	name=$(echo $name_hex | xxd -r -p)
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where (ssid_hex like \"$name_hex%\" or ssid_hex like \"%$name_hex%\" or ssid_hex like \"%$name_hex\") and is_name is null;"
done < lists/names_hex.txt
mysql probeprint <<< "update ssid_intel set category=\"NAME\" where is_name!='' and is_name is not null;"
mysql probeprint <<< "update ssid_intel set is_name=0 where is_name is null;"
echo check_name stop $(date +"%H:%M:%S.%3N")
}


check_fqdn () {
	echo check_fqdn start $(date +"%H:%M:%S.%3N")

# Load the TLD list once instead of re-reading it for every SSID.
#https://data.iana.org/TLD/tlds-alpha-by-domain.txt
local -A tlds=()
while read -r domain; do
	[ -n "$domain" ] && tlds[${domain,,}]=1
done < lists/domains.txt

while read -r ssid_hex; do
	# Decode per row. This used to sit above the loop with ssid_hex unset,
	# so $ssid was empty every iteration and nothing ever matched.
	ssid=$(printf '%s' "$ssid_hex" | xxd -r -p 2>/dev/null | tr -cd '[:print:]')

	case "$ssid" in
		*.*) tld=${ssid##*.} ;;
		*)   continue ;;
	esac
	[ -z "$tld" ] && continue

	if [[ -n ${tlds[${tld,,}]:-} ]]; then
		mysql probeprint <<< "update ssid_intel set category=\"OTHER_FQDN\" where ssid_hex=\"$ssid_hex\";"
	fi
#the stray semicolon after `is null` made this a SQL syntax error
done <<< $(mysql -N probeprint <<< "select ssid_hex from ssid_intel where category is null or category=\"OTHER_UNKNOWN\";")
echo check_fqdn stop $(date +"%H:%M:%S.%3N")
}


check_address () {
	echo address start $(date +"%H:%M:%S.%3N")
	while read ssid_hex; do
		ssid=$(echo $ssid_hex | xxd -r -p)
	if egrep -q '^[0-9]{1,5} ?[A-Z][\\.a-z] ?[a-zA-Z]' <<< "$ssid"
 		then
		echo $ssid_hex
		mysql probeprint <<< "update ssid_intel set category=\"LOCATION_SPECIFIC\" where ssid_hex=\"$ssid_hex\";"
	fi
done <<< $( mysql -N probeprint <<< "select ssid_hex from ssid_intel where ssid_hex like '3%';")
	echo check address stop $(date +"%H:%M:%S.%3N")
}


check_oneloc () {
	#set -x
	# The body of this pass now lives in geolocate_functions.sh as
	# derive_is_oneloc, sourced at the top of this file, so the two generations
	# of the codebase cannot drift apart on it.
	#
	# It used to grep the cached WiGLE body for `"totalResults": 1`. That number
	# counts case-INSENSITIVE matches, so "MyNet" and "mynet" -- different
	# networks, different owners, different cities -- inflated it together, and
	# the flag was wrong for most of its positives in both directions. It is now
	# derived from geo_match_count, which counts results matching the probed
	# SSID byte-for-byte.
	#
	# The old "AMBIGUOUS_LOC" placeholder is gone with it: a row can only reach
	# is_oneloc=1 by having a resolved coordinate, so there is nothing ambiguous
	# left to mark.
	derive_is_oneloc "$@"
}





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


make_ignore_list () {	
	echo ignore_check $(date +"%H:%M:%S.%3N")
	> lists/ignore.txt
	while read line; do
		count=$(mysql -N probeprint <<< "select count(DISTINCT wlan_sa) from ssid where ssid_hex=\"$line\";")
		if [[ $count -gt 40 ]]
			then
			echo "$line" >> lists/ignore.txt
		fi
	done <<<$(mysql -N probeprint <<< "select ssid_hex from ssid;"  | sort | uniq -c | sort -nr | head -n30 |tr -s \   | cut -d \  -f3)
mysql probeprint <<< "select ssid_hex from ssid_intel where category=\"OTHER_ANOMALOUS\";" >> lists/ignore.txt
echo ignore_check end $(date +"%H:%M:%S.%3N")
}


score () {
	
	while read -r line; do
#echo $line
IFS='|' read -r ssid_hex category <<<"$line"


case $category in
TECH_PHONE)
score=2
;;
TECH_CPE)
score=1
;;
TECH_PRINTER)
score=1
;;
TECH_OTHER)
score=1
;;
LOCATION_SPECIFIC)
score=2
;;
LOCATION|LOCATION_VAGUE)
score=1
;;
BIZ_HOTEL)
score=1
;;
BIZ_EATERY)
score=1
;;
BIZ_OTHER)
score=1
;;
BIZ_INSTITUTION)
score=2
;;
BIZ_COWORK)
score=2
;;
BIZ_HEALTHCARE)
score=2
;;
BIZ_CLUB)
score=2
;;
NAME)
score=1
;;
NAME_SPECIFIC)
score=2
;;
TRAVEL)
score=1
;;
TRAVEL_AIRPORT)
score=1
;;
INDUSTRY_ORG)
score=2
;;
INDUSTRY_VIP)
score=2
;;
INDUSTRY_PERSON)
score=2
;;
INDUSTRY_EVENT)
score=1
;;
INDUSTRY_VENUE)
score=1
;;
INDUSTRY_VC)
score=2
;;
CULTURE_CAR)
score=2
;;
CULTURE_RELIGION)
score=1
;;
CULTURE_MUSIC)
score=1
;;
CULTURE_OTHER)
score=1
;;
CULTURE_LANGUAGE)
score=2
;;
CULTURE_LUXURY)
score=2
;;
CULTURE_*)
score=2
;;
OTHER_ANOMALOUS)
score=0
;;
OTHER_COMMON)
score=0
;;
OTHER_CREATIVESSID)
score=1
;;
OTHER_UNKNOWN)
score=0
;;
BIZ_STAFF)
score=2
;;
OTHER_HOUSEHOLD)
score=2
;;
TECH_GUEST)
score=1
;;
TECH_IOT)
score=1
;;
OTHER_NUMERIC)
score=0
;;
OTHER_FQDN)
score=1
;;
esac
#echo $rowid $category $score
mysql probeprint <<< "update ssid_intel set score=\"$score\" where ssid_hex=\"$ssid_hex\";"
done <<<$(mysql -N probeprint <<< "select concat_ws('|',ssid_hex,category) from ssid_intel where score is null and category is not null;")
}


bump_score () {
while read line; 
do 
score=$(mysql -N probeprint <<< "select score from ssid_intel where ssid_hex=\"$line\";")
((score++))
mysql probeprint <<< "update ssid_intel set score=\"$score\" where ssid_hex=\"$line\";"
#echo updating score for row $line
done <<< $(mysql -N probeprint <<< "select ssid_hex from ssid_intel where is_oneloc=1;")
}



# mac2vendor now lives in vendor_functions.sh, sourced at the top of this file,
# so build_ssid_intel.sh and standalone_mac2vendor.sh share one implementation.


check_language () {

	#https://www.loc.gov/marc/specifications/specchareacc/KoreanHangul.html
#	#'%e38[1,2,3]%' - japanese#

#sqlite3 new.db "update ssid_intel set category=CULTURE_LANGUAGE where category ssid_hex like 'e%';"
mysql probeprint <<< "update ssid_intel set category='CULTURE_JAPANESE' where (ssid_hex like '%e381%' or ssid_hex like '%e382%' or ssid_hex like '%e383%') and ssid_hex like 'e%';"
mysql probeprint <<< "update ssid_intel set category='CULTURE_KOREAN' where (ssid_hex like '%e384%' or ssid_hex like '%e385%' or ssid_hex like '%eab%'  or ssid_hex like '%eb8%'  or ssid_hex like 'ec%'  or ssid_hex like '%ead%') and ssid_hex like 'e%';"
mysql probeprint <<< "update ssid_intel set category='CULTURE_ARABIC' where ssid_hex like 'd98%' or ssid_hex like 'd89%' or ssid_hex like 'd8a%' or ssid_hex like 'd8b%' or ssid_hex like 'daa%' or ssid_hex like 'dab%' or ssid_hex like 'dbb%' ;"
mysql probeprint <<< "update ssid_intel set category='CULTURE_HEBREW' where ssid_hex like 'd6%' or ssid_hex like 'd7%' ;"
mysql probeprint <<< "update ssid_intel set category='CULTURE_CRYLIC' where ssid_hex like 'd1%' or ssid_hex like 'd0%' or ssid_hex like 'd2%';"
mysql probeprint <<< "update ssid_intel set category='CULTURE_KANJI' where ssid_hex like 'e4%' or ssid_hex like 'e5%' or ssid_hex like 'e6%' or ssid_hex like 'e7%' or ssid_hex like 'e8%' or ssid_hex like 'e9%';"
mysql probeprint <<< "update ssid_intel set category='CULTURE_GREEK' where ssid_hex like 'cc%' or ssid_hex like 'cd%' or ssid_hex like 'ce%'  or ssid_hex like 'cd%' or ssid_hex like 'ce%' or ssid_hex like 'cf%' ;"
mysql probeprint <<< "update ssid_intel set category='CULTURE_EMOJI' where ssid_hex like '%efb88f%' or ssid_hex like 'f09f%' or ssid_hex like 'e29%' ;"

}

#check local wigle db
#check_localwigle () {}


remove_empty_locs () {
	# Retroactively drop quota-exhaustion bodies so those SSIDs retry next run.
	# Single source of the cleanup, shared via location_functions.sh.
	wigle_purge_quota_files
}


#}
