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
#categories["NAME_VAGUE"]="Family;'s;familia"
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

categorize