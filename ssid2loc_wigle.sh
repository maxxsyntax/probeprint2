#!/bin/bash
source .env
#source ./ssid_intel_online_functions.sh
#source ./gps2city.sh
#set -x
#need to fix null byte bug







ssid2loc (){
if [ ! -f locs/"$ssid_hex".location ]
then
curl -s -H 'Accept:application/json' -u $APIKEY --basic https://api.wigle.net/api/v2/network/search?ssid="$ssid_uri" -o locs/"$ssid_hex".location
echo $ssid_hex found in wigle
fi
grep -q oo\ many locs/"$ssid_hex".location
if [ $? -eq 0 ]
then
        echo out of API queries 
        for a in `grep oo\ many locs/"$ssid_hex".location | cut -d\: -f1`; do rm $a;done
        exit
        break
        exit
fi
}

gps2city () {

# Input from $1: "41.8625477,-87.91438916"
input="$1"

IFS=',' read -r  lat lon <<< "$input"

# Query OpenStreetMap Nominatim reverse geocoding API
response=$(curl -s "https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json&zoom=18&addressdetails=1" \
  -H "User-Agent: bash-reverse-geocoder")

# Extract fields with fallbacks
house_number=$(echo "$response" | jq -r '.address.house_number // empty')
street=$(echo "$response" | jq -r '.address.road // .address.pedestrian // .address.footway // .address.path // empty')
city=$(echo "$response" | jq -r '.address.city // .address.town // .address.village // .address.hamlet // .address.county // empty')
state=$(echo "$response" | jq -r '.address.state // empty')
country=$(echo "$response" | jq -r '.address.country // empty')

# Output as CSV-style line
echo "$house_number,$street,$city,$state,$country"

}





while read ssid_hex; do 
       # echo $ssid_hex
        ssid="$(echo -n $ssid_hex | xxd -r -p)"
        ssid_uri=$(echo -n "$ssid" | jq -sRr @uri)


#if grep -q "$ssid" /root/wigle_output/*csv; then
#echo $ssid_hex
#gps=$(grep ,"$ssid", /root/wigle_output/*csv| cut -d, -f7,8 | head -n1)
#gps2city $gps | tee locs/$ssid_hex.location
#
#else
#fi


match=$(grep -a -m1 ",$ssid," /root/wigle_output/*csv | grep -i WIFI | head -n1)

if [ -n "$match" ]; then
    echo "$ssid_hex" local match 
    gps=$(echo "$match" | cut -d,  -f7,8,9 | egrep -o '\-?[0-9]{1,3}\.[0-9]+,\-?[0-9]{1,3}\.[0-9]+')
#    echo $gps
gps2city $gps | tee -a locs/$ssid_hex.location

#else 
#ssid2loc
fi

#ssid2loc

done <<< $(mysql -N probeprint <<< "select distinct ssid_hex from ssid_intel where ssid_hex not like '%00%' and ssid_hex not like '%fff%' and (location='no file' or location='0' or location is null ) order by rand();" )
