#!/usr/bin/bash
/usr/bin/sleep 24
/usr/sbin/airodump-ng -t wep -c 1-11 -w /home/pi/caps/ad_$(date +%s).cap wlan1mon

