#!/bin/bash
source ./ssid_intel_functions.sh
#set -x

#echo task every10s done  $(date +"%H:%M:%S.%3N")

trap 'kill $(jobs -p) 2>/dev/null' EXIT

#   startup 
     #  every3s &
      # every10s0s &
 #      every60s &
###one offs add here and then remove
#

###dont require ssid
#check_airport
#check_name
#check_anomalies
#make_ignore_list
#mac2vendor
#check_language
#check_common


#run functions in the backgound constantly

###Checks that require a ssid
ssid2ssid_intel 
categorize &
summarize_location &
check_name & 
check_airport &
#check_fqdn
#check_oneloc



#check_industry

#check_address

wait
