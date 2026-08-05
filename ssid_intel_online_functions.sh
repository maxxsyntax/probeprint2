#!/bin/bash
source .env

test_online () {

	#missing space before ] made this a "command not found" every time
	if ping -c1 -q 4.2.2.2 >/dev/null 2>&1 && nslookup wigle.net >/dev/null 2>&1
	then
		echo has internet
		return 0
	fi
	return 1

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
