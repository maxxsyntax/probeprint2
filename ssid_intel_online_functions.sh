#!/bin/bash
source .env

test_online () {

	ping -c1 -q 4.2.2.2 >/dev/null && nslookup wigle.net >/dev/null
	if [ $? -eq 0]
	then 
		echo has internet
	fi

}


ssid2loc (){
if [ ! -f locs/"$ssid_hex".location ]
then
curl -s -H 'Accept:application/json' -u $APIKEY --basic https://api.wigle.net/api/v2/network/search?ssid="$ssid_uri" -o locs/"$ssid_hex".location    
sleep .2
fi
grep -q oo\ many locs/"$ssid_hex".location
if [ $? -eq 0 ]
then
	for a in `grep oo\ many locs/* | cut -d\: -f1`; do rm -v $a;done
	echo stop now
	sleep 600
fi
}




#unknown2chatgpt
#address2streetview
