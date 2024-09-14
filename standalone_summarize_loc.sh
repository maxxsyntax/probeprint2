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
		mysql probeprint <<<"update ssid_intel set location=\"$locale\" where ssid_hex=\"$ssid_hex\";"
		mysql probeprint <<<"update ssid_intel set location=\"no results\" where ssid_hex=\"$ssid_hex\" and location is null;"	
	echo results $results
	fi
if [ -n "$results" ]
then
	if [ $results -gt 100 ]; then
		locale="too many results"
		mysql probeprint <<<"update ssid_intel set location=\"$locale\" where ssid_hex=\"$ssid_hex\";"
	fi
	if [ $results -lt 1 ]; then
		locale="no results"
		mysql probeprint <<<"update ssid_intel set location=\"$locale\" where ssid_hex=\"$ssid_hex\";"
	fi
else
	locale="no file"
fi
mysql probeprint <<<"update ssid_intel set location=\"no file\" where ssid_hex=\"$ssid_hex\" and location is null;"	

echo $ssid_hex
echo $ssid
echo $locale

}
ssid_hex=$1
ssid=$(echo $ssid_hex | xxd -r -p)
#summarize_location

while read line; do summarize_location $line; done <<< $(mysql -N probeprint <<< "select ssid_hex from ssid_intel where location is null;")



