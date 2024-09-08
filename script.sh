#!/usr/bin/bash
/usr/bin/screen -d -m -S cap /home/pi/start_cap.sh &
/usr/bin/screen -d -m -S cp /home/pi/start_cp.sh &
date >> /home/pi/date
