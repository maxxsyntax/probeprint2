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

###dont require input
#check_airport
#check_industry
#check_name  # Bug ERROR 1292 (22007) at line 1: Truncated incorrect DECIMAL value: ''
#check_anomalies
#make_ignore_list #borken, needed?
mac2vendor
#check_language
#check_common


#run functions in the backgound constantly

###Checks that require a ssid
#ssid2ssid_intel 
#categorize &
#summarize_location &
#check_name & 
#check_airport &
#check_fqdn
#check_oneloc



#check_address
#continuous updating
#while true; do
#     ./standalone_ssid2ssid_intel.sh
#     ./standalone_address.sh
#     ./standalone_airport.sh
#     ./standalone_categorize.sh
#     ./standalone_check_industry
#     ./standalone_common.sh
#     ./standalone_name.sh
#     ./standalone_oneloc.sh
#     ./standalone_summarize_loc.sh
#     sleep 20
#done

#wait
