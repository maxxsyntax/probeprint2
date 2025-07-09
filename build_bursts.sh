#!/bin/bash
set -x

source ./bursts_functions.sh

###
#When SSID is seen, match ssid to ssids of burst, pull related burst ssids, pull all info of all ssids from ssid_intel
#Mark VIP as needed
###

ssid_2bursts-wlan_sa
ssid2bursts-seq
ssid2bursts-vht
is_uniq

#find_relatedbursts #1:45
#dice_coef # 2 minutes




#needs 
#score summary
#vht stats?
#avg_rssi
#is_vip
