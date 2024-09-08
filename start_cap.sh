#!/usr/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
date >> /home/pi/cap
/usr/bin/sleep 20;
echo sleep done >> /home/pi/cap
/usr/sbin/airmon-ng start wlan1  | tee -a /home/pi/cap
while true; do /usr/bin/tshark -Vi wlan1mon -a duration:300 -w /tmp/$(date +%s) -f "wlan subtype probe-req" | tee -a /home/pi/cap; /usr/bin/sleep 60; done

