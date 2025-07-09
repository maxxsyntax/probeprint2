#!/bin/bash
#needed variables
source .env
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
categories["LOCATION"]="Marina;beach;Harbor;Apartment;FLAT;Lobby;cdmx;river;Tour_Eiffel;stadium;Athens"
#customize in .env file
#categories["INDUSTRY_VIP"]="XXX"
categories["CULTURE_LUXURY"]="Estates;lux;yatch;social;marina;penthouse;jetex;ginza"




#functions
ssid2ssid_intel () {
mysql probeprint <<< "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid where time > $1;"
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
done <<< $(mysql -N probeprint <<<"select ssid_hex from ssid_intel where is_common is null and ssid_hex not like '1%' and ssid_hex not like '2%' and ssid_hex not like '8%';")

}



categorize () {
while true; do 
	echo categorize start $(date +"%H:%M:%S.%3N")
	mysql probeprint <<< "update ssid_intel set category=\"OTHER_ANOMALOUS\" where (ssid_hex like '%00' or ssid_hex like '%000%' or ssid_hex like '%fff%' or ssid_hex like '8%' or ssid_hex like '1%') and category is null;"
	while
	 read ssid_hex; 
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
	done <<< $(mysql probeprint <<< "select ssid_hex from ssid_intel where category is null;")
#bug where next line is nullifed on ssids starting with special character
	mysql probeprint <<< "update ssid_intel set category = \"OTHER_UNKNOWN\"  where category is null;"
	echo categorize stop $(date +"%H:%M:%S.%3N")
	sleep 5
done
}


check_industry () {
echo industry check $(date +"%H:%M:%S.%3N")
while read line; do 
ind_hex=$(echo -n $line | xxd -p)
mysql probeprint <<< "update ssid_intel set category=\"INDUSTRY_ORG\" where ssid_hex like \"$ind_hex%\"; "
done < lists/industry.txt
}

check_airport () {
	#while true; do
echo Airport check start $(date +"%H:%M:%S.%3N")
IFS=\|; 
while read line; do 
	arr=($line);
	 iata_hex=$(echo -n ${arr[0]} | xxd -p)
	 mysql probeprint <<< "update ssid_intel set is_airport=\"${arr[1]}\" where ssid_hex like \"$iata_hex%\" or ssid_hex like '%$iata_hex%'; "
done < lists/airports.txt
mysql  probeprint <<< "update ssid_intel set is_airport=0 where is_airport is null;"
sleep 10
#done
echo Airport check stop $(date +"%H:%M:%S.%3N")
}


check_name () {
	#todo: look for one space or 2 spaces if there's an iphone
echo check_name start $(date +"%H:%M:%S.%3N")
	#need to only work on unprocessed

#look for 's\ 

while read ssid_hex; do
	name=$(echo $ssid_hex | sed 's/277320.*//g' | xxd -r -p| tr -cd '[:print:]')
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where ssid_hex=\"$ssid_hex\";"
#	echo $ssid_hex $name
done <<< $(mysql probeprint <<< "select ssid_hex from ssid_intel where ssid_hex like \"%277320%\" and is_name is null;")

#look for Familia
while read ssid_hex; do
	name=$(echo $ssid_hex | sed 's/46616d696c696120//g' | xxd -r -p| tr -cd '[:print:]')
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where ssid_hex=\"$ssid_hex\";"
#	#echo $ssid_hex $name
done <<< $(mysql probeprint <<< "select ssid_hex from ssid_intel where ssid_hex like \"46616d696c6961%\" and is_name is null;")

while read ssid_hex; do
	name=$(echo $ssid_hex | sed 's/66616d696c696120//g' | xxd -r -p| tr -cd '[:print:]')
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where ssid_hex=\"$ssid_hex\";"
#	echo $ssid_hex $name
done <<< $(mysql probeprint <<< "select ssid_hex from ssid_intel where ssid_hex like \"66616d696c6961%\" and is_name is null;")

while read ssid_hex; do
	name=$(echo $ssid_hex | sed 's/46616d696c79//g' | xxd -r -p| tr -cd '[:print:]')
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where ssid_hex=\"$ssid_hex\";"
	#echo $ssid_hex $name
done <<< $(mysql probeprint <<< "select ssid_hex from ssid_intel where ssid_hex like \"%46616d696c79\" and is_name is null;")

#iterate through name list
while read name_hex; 
do
	name=$(echo $name_hex | xxd -r -p)
	mysql probeprint <<< "update ssid_intel set is_name=\"$name\" where (ssid_hex like \"$name_hex%\" or ssid_hex like \"%$name_hex%\" or ssid_hex like \"%$name_hex\") and is_name is null;"
done < lists/names_hex.txt
mysql probeprint <<< "update ssid_intel set category=\"NAME\" where is_name!=0 and is_name is not null;"
mysql probeprint <<< "update ssid_intel set is_name=0 where is_name is null;"
echo check_name stop $(date +"%H:%M:%S.%3N")
}


check_fqdn () {
	echo check_fqdn start $(date +"%H:%M:%S.%3N")
	 ssid=$(echo -n $ssid_hex | xxd -r -p)
	while read ssid_hex; do 
#https://data.iana.org/TLD/tlds-alpha-by-domain.txt
while read domain; do

	fqdn=\\.${domain,,}
	len=${#fqdn}
	last4=${ssid: -$len}
	if [[ "${last4,,}" =~ ${fqdn,,} ]]
		then
		#echo Domain $domain Last4 $last4 $ssid
		mysql probeprint <<< "update ssid_intel set category=\"OTHER_FQDN\" where ssid_hex=\"$ssid_hex\";"
	fi
done < lists/domains.txt
done <<< $(mysql probeprint <<< "select ssid_hex from ssid_intel where category is null; or category=\"OTHER_UNKNOWN\";")
echo check_fqdn stop $(date +"%H:%M:%S.%3N")
}


check_address () {
	if egrep -q '^[0-9]{1,5} ?[A-Z][\\.a-z] ?[a-zA-Z]' <<< "$1"
 		then 
		mysql probeprint <<< "update ssid_intel set category=\"LOCATION_SPECIFIC\" where ssid_hex=\"$ssid_hex\";"
	fi
}


check_oneloc () {
	#set -x
	echo oneloc start $(date +"%H:%M:%S.%3N")
while read ssid_hex; 
	do
	#also need to add case sensitve single matches and not just what wigle says
	#for loc_file in ./locs/$ssid_hex.location; 
		#do 
			#can probably be shortened into a better jq query
		match=$(cat ./locs/$ssid_hex.location 2>/dev/null | jq | grep  -A 8 'lts": 1,' | grep ssid | cut -d\" -f4); 
		if egrep -q '.'  <<<"$match"
			then
			#echo oneresult 
			mysql probeprint <<< "update ssid_intel set is_oneloc='1' where ssid_hex=\"$ssid_hex\";"
			else
				mysql probeprint <<< "update ssid_intel set is_oneloc=0 where ssid_hex=\"$ssid_hex\";"
		fi
	#done
done <<< $(mysql -N probeprint <<< "select ssid_hex from ssid_intel where is_oneloc is null;")

	while read ssid_hex; do 
		city=$(cat ./locs/$ssid_hex.location | jq | grep city | cut -d\" -f4); 
		if [[ -n $city ]] ; 
			then 
			mysql probeprint <<< "update ssid_intel set location=\"$city\" where ssid_hex=\"$ssid_hex\";"
		fi
	done <<<$(mysql -N probeprint <<< "select ssid_hex from ssid_intel where is_oneloc=1 and location is null;")
	mysql probeprint <<< "update ssid_intel set location=\"AMBIGUOUS_LOC\" where is_oneloc=1 and location is null;"

echo oneloc stop $(date +"%H:%M:%S.%3N")
}




summarize_location () {
		echo summarize_location start $(date +"%H:%M:%S.%3N")
			#echo $ssid_hex
			ssid_hex=$1
 			ssid=$(echo -n $ssid_hex | xxd -r -p )
 			if [ $? -ne 0 ]
 			then
 				echo $ssid_hex
 			fi
 			#echo $ssid_hex
 			locale=""
 			if [  -f locs/"$ssid_hex".location ]
			#if [  -f locs/"$ssid_uri".location ]
			then
				results=$(cat locs/"$ssid_hex".location | jq | grep totalResults | tr -s \  | cut -d\  -f3 | cut -d, -f1)
				#results=$(cat locs/"$ssid_uri".location | jq | grep totalResults | tr -s \  | cut -d\  -f3 | cut -d, -f1)
				#echo $ssid_hex $ssid $ssid_uri #debugging
				if [ $results -gt 0 ]  &&  [ $results -lt 100 ]; then
					#find uniq country/region/city/road, grep -A 22 is for case sensitivity
					#cc=$(cat locs/$ssid_uri.location | jq | grep -A 22 "$ssid" | grep country | sort | uniq | grep -v null |wc -l)
					cc=$(cat locs/$ssid_hex.location | jq | grep -A 22 "$ssid" | grep country | sort | uniq | grep -v null |wc -l)
					if [ $cc -eq 1 ]
					then
						rc=$(cat locs/"$ssid_hex".location | jq |  grep -A 22 "$ssid" |grep region | sort | uniq | grep -v null| wc -l)
						#rc=$(cat locs/"$ssid_uri".location | jq |  grep -A 22 "$ssid" |grep region | sort | uniq | grep -v null| wc -l)
						if [ $rc -eq 1 ]
						then
							cic=$(cat locs/"$ssid_hex".location | jq | grep -A 22 "$ssid" | grep city | sort | uniq | wc -l)
							#cic=$(cat locs/"$ssid_uri".location | jq | grep -A 22 "$ssid" | grep city | sort | uniq | wc -l)
							if [ $cic -eq 1 ]
							then
					##			#show city and roads, and region in case city is null
								locale=$(echo -n $(cat locs/"$ssid_hex".location | jq |  grep -A 22 "$ssid" |grep region | sort | uniq | grep -v null | tr '\n' ' ' | sed 's/\"region\"://g' | tr -s \  ) && echo -n $(cat locs/"$ssid_hex".location | jq |  grep -A 22 "$ssid"| grep city | sort | uniq | tr '\n' ' ' | sed 's/\"city\"://g' |tr -s \  ) && echo -n $(cat locs/"$ssid_hex".location | jq | grep -A 22 "$ssid" | grep road | sort | uniq | tr '\n' ' ' | sed 's/\"road\"://g' | tr -s \  | sed 's/\ null,//g' | sed 's/\",\ \"/,/g' | tr -s \  ))
								#locale=$(echo -n $(cat locs/"$ssid_uri".location | jq |  grep -A 22 "$ssid" |grep region | sort | uniq | grep -v null | tr '\n' ' ' | sed 's/\"region\"://g' | tr -s \  ) && echo -n $(cat locs/"$ssid_uri".location | jq |  grep -A 22 "$ssid"| grep city | sort | uniq | tr '\n' ' ' | sed 's/\"city\"://g' |tr -s \  ) && echo -n $(cat locs/"$ssid_uri".location | jq | grep -A 22 "$ssid" | grep road | sort | uniq | tr '\n' ' ' | sed 's/\"road\"://g' | tr -s \  | sed 's/\ null,//g' | sed 's/\",\ \"/,/g' | tr -s \  ))
							else
								#show mu ltiple cities
								locale=$(echo -n $cic cities\  && echo -n $(cat locs/"$ssid_hex".location | jq | grep -A 22 "$ssid" | grep city | sort | uniq | tr '\n' ' ' | sed 's/\"city\"://g' | tr -s \  | sed 's/\ null,//g' | sed 's/\",\ \"/,/g'))
								#locale=$(echo -n $cic cities\  && echo -n $(cat locs/"$ssid_uri".location | jq | grep -A 22 "$ssid" | grep city | sort | uniq | tr '\n' ' ' | sed 's/\"city\"://g' | tr -s \  | sed 's/\ null,//g' | sed 's/\",\ \"/,/g'))
							fi
						else
			#				#show multiple regions
							locale=$(echo -n $rc regions\  && echo -n $(cat locs/"$ssid_hex".location | jq | grep -A 22 "$ssid" | grep region | sort | grep -v null |  uniq -c  | sort -nr | tr '\n' ' ' | sed 's/\"region\"://g' | tr -s \  |  sed 's/\",\ \"/,/g' ))
							#locale=$(echo -n $rc regions\  && echo -n $(cat locs/"$ssid_uri".location | jq | grep -A 22 "$ssid" | grep region | sort | grep -v null |  uniq -c  | sort -nr | tr '\n' ' ' | sed 's/\"region\"://g' | tr -s \  |  sed 's/\",\ \"/,/g' ))
						fi
					else
			#		#show multiple countries
					locale=$(echo -n $cc countries\ && echo -n $(cat locs/"$ssid_hex".location | jq | grep -A 22 "$ssid" | grep country | sort | grep -v null | sed 's/\"country\"://g' | tr -s \  |  sed 's/\",\ \"/,/g' | uniq -c | sort -nr | tr -s \   | sed 's/\"country\"\://g'| tr '\n' '\ ' | tr -s \ ))
					#locale=$(echo -n $cc countries\ && echo -n $(cat locs/"$ssid_uri".location | jq | grep -A 22 "$ssid" | grep country | sort | grep -v null | sed 's/\"country\"://g' | tr -s \  |  sed 's/\",\ \"/,/g' | uniq -c | sort -nr | tr -s \   | sed 's/\"country\"\://g'| tr '\n' '\ ' | tr -s \ ))
					fi
				fi
				#echo $locale
			locale=$(echo $locale | tr -d \" | sed 's/0 countries//g')
			mysql probeprint <<< "update ssid_intel set location=\"$locale\" where ssid_hex=\"$ssid_hex\";"
			mysql probeprint <<< "update ssid_intel set location=0 where ssid_hex=\"$ssid_hex\" and location is NULL;"
			fi
	echo summarize_location end $(date +"%H:%M:%S.%3N")
}

check_anomalies () {
	mysql probeprint <<< "update ssid_intel set category=\"OTHER_ANOMALOUS\" where (ssid_hex like '%00' or ssid_hex like '%00%' or ssid_hex like '%ff%' or ssid_hex >=8 or ssid_hex <= 2) and category is null;";
	mysql probeprint <<< "update ssid_intel set category=\"OTHER_ANOMALOUS\" where (ssid_hex like '7c%') and category is null;"
}


make_ignore_list () {	
	echo ignore_check $(date +"%H:%M:%S.%3N")
	> lists/ignore.txt
	while read line; do
		count=$(mysql probeprint <<< "select count(DISTINCT wlan_sa) from ssid where ssid_hex=\"$line\";")
		if [[ $count -gt 40 ]]
			then
			echo "$line" >> lists/ignore.txt
		fi
	done <<<$(mysql probeprint <<< "select ssid_hex from ssid;"  | sort | uniq -c | sort -nr | head -n30 |tr -s \   | cut -d \  -f3)
mysql probeprint <<< "select ssid_hex from ssid_intel where category=\"OTHER_ANOMALOUS\";" >> lists/ignore.txt
echo ignore_check end $(date +"%H:%M:%S.%3N")
}




mac2vendor () {

arr=()
IFS=\|
while read line; do 
arr=($line)	
oui=$(echo "${arr[0]}" |tr -d \: | cut -b1-6)

#echo $line
vendor=$(grep -i $oui lists/oui.csv | cut -d, -f3,4 | cut -b 1-20 | tr -d \")
if [[  -n $vendor ]]
then
#echo ${arr[0]} $vendor ${arr[1]}
#update prints with vendor type
#sqlite3 new.db "update prints set cat_notes2=\"$vendor\" where primary_burst=(select related_burst from bursts where ssids like \"%:${arr[1]}:%\" or ssids like \"%:${arr[1]}\" or ssids like \"${arr[1]}:%\") ;"
mysql probeprint <<< "update ssid set vendor=\"$vendor\" where ssid_hex=\"${arr[1]}\" and wlan_sa=\"${arr[0]}\"; "
else
	mysql probeprint <<< "update ssid set vendor=\".\" where ssid_hex=\"${arr[1]}\" and wlan_sa=\"${arr[0]}\"; "

fi
#select SSIDS with only 1 mac address associated.  The idea being, a mac will randomize and then probe for the same ssid; thus 2+ wlan_sa per ssid.  This will leave some false negatives but will tune out the majority of dynamic mac addresses (which would have no vendor)
#needs to account for ssid's already analyzed
done <<< $(mysql probeprint <<< "select wlan_sa,ssid_hex from ssid where vendor is null group by ssid_hex HAVING count(DISTINCT wlan_sa) =1;")
}



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
for a in `grep oo\ many locs/* | cut -d\: -f1`; do rm $a;done
}


#}
