source .env
#set -x
locale=""
summarize_location () {
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
							echo
			#			show multiple cities
						locale=$(echo -n $cic cities\  && echo -n $(cat locs/"$ssid_hex".location | jq | grep -A 22 "$ssid" | grep city | sort | uniq | tr '\n' ' ' | sed 's/\"city\"://g' | tr -s \  | sed 's/\ null,//g' | sed 's/\",\ \"/,/g'))
						#locale=$(echo -n $cic cities\  && echo -n $(cat locs/"$ssid_uri".location | jq | grep -A 22 "$ssid" | grep city | sort | uniq | tr '\n' ' ' | sed 's/\"city\"://g' | tr -s \  | sed 's/\ null,//g' | sed 's/\",\ \"/,/g'))
					fi
					else
			#		#show multiple regions
					locale=$(echo -n $rc regions\  && echo -n $(cat locs/"$ssid_hex".location | jq | grep -A 22 "$ssid" | grep region | sort | grep -v null |  uniq -c  | sort -nr | tr '\n' ' ' | sed 's/\"region\"://g' | tr -s \  |  sed 's/\",\ \"/,/g' ))
					#locale=$(echo -n $rc regions\  && echo -n $(cat locs/"$ssid_uri".location | jq | grep -A 22 "$ssid" | grep region | sort | grep -v null |  uniq -c  | sort -nr | tr '\n' ' ' | sed 's/\"region\"://g' | tr -s \  |  sed 's/\",\ \"/,/g' ))
				fi
				else
			#	#show multiple countries
				locale=$(echo -n $cc countries\ && echo -n $(cat locs/"$ssid_hex".location | jq | grep -A 22 "$ssid" | grep country | sort | grep -v null | sed 's/\"country\"://g' | tr -s \  |  sed 's/\",\ \"/,/g' | uniq -c | sort -nr | tr -s \   | sed 's/\"country\"\://g'| tr '\n' '\ ' | tr -s \ ))
				#locale=$(echo -n $cc countries\ && echo -n $(cat locs/"$ssid_uri".location | jq | grep -A 22 "$ssid" | grep country | sort | grep -v null | sed 's/\"country\"://g' | tr -s \  |  sed 's/\",\ \"/,/g' | uniq -c | sort -nr | tr -s \   | sed 's/\"country\"\://g'| tr '\n' '\ ' | tr -s \ ))
			fi
		fi
		#echo $locale
		locale=$(echo $locale | tr -d \" | sed 's/0 countries//g')
		#echo $locale
		#sqlite3 new.db "update ssid_intel set location=\"$locale\" where ssid_hex=\"$ssid_hex\";"
		#sqlite3 new.db "update ssid_intel set location=0 where ssid_hex=\"$ssid_hex\" and location is NULL;"
	echo results $results
	fi
}
ssid_hex=$1
ssid=$(echo $ssid_hex | xxd -r -p)
ssid2loc (){
	echo running ssid2loc
if [ ! -f locs/"$ssid_hex".location ]
then
	echo running curl
curl  -H 'Accept:application/json' -u $APIKEY --basic https://api.wigle.net/api/v2/network/search?ssid="$ssid_uri" -o locs/"$ssid_hex".location    
sleep 2
fi
grep -q oo\ many locs/"$ssid_hex".location 
if [ $? -eq 0 ]
then
	echo stop now
	for a in `grep oo\ many locs/* | cut -d\: -f1`; do rm $a;done
	sleep 10
	return
fi
}
#ssid2loc
#summarize_location
#echo $ssid_hex
#echo $ssid
#echo $locale

