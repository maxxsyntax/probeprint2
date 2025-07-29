#!/bin/bash
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



categorize () {
#while true;
#do
	echo categorize start $(date +"%H:%M:%S.%3N")
	mysql probeprint <<< "update ssid_intel set category=\"OTHER_ANOMALOUS\" where ssid_hex like '%00' or ssid_hex like '%000%' or ssid_hex like '%fff%' or ssid_hex like '8%' or ssid_hex like '1%';"
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
	done <<< $(mysql probeprint <<< "select ssid_hex from ssid_intel where category is null;")
#bug where next line is nullifed on ssids starting with special character
	mysql probeprint <<< "update ssid_intel set category = \"OTHER_UNKNOWN\"  where category is null;"
	echo categorize stop $(date +"%H:%M:%S.%3N")
#done
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


check_language () {

        #https://www.loc.gov/marc/specifications/specchareacc/KoreanHangul.html
#       #'%e38[1,2,3]%' - japanese#

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




check_anomalies
check_common
check_language
categorize
