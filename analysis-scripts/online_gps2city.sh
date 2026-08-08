#!/bin/bash



gps2city () { 

# Input from $1: "21.2621477,-97.93331916"
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

gps2city $1
