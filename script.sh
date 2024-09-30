#!/usr/bin/bash
/usr/bin/screen -d -m -S cap /home/pi/start_cap.sh &
###To enable Channel hopping
#/usr/bin/screen -d -m -S airodump /home/pi/start_ad.sh &
date >> /home/pi/date
