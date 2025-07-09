source .env
check_industry () {
echo industry start $(date +"%H:%M:%S.%3N")
while read line; do 
ind_hex=$(echo -n $line | xxd -p)
mysql probeprint <<< "update ssid_intel set category=\"INDUSTRY_ORG\" where ssid_hex like \"$ind_hex%\"; "
done < lists/industry.txt
echo industry stop $(date +"%H:%M:%S.%3N")
}
check_industry
