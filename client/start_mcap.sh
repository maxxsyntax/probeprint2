#!/usr/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
date >> /home/pi/cap
#/usr/bin/sleep 15;
echo sleep done >> /home/pi/cap

x=1
interfaces=$(iwconfig 2>/dev/null | egrep '^w' | awk '{print $1}' | grep -v 'wlan0')
echo interfaces are $interfaces
for interface in $interfaces; do
 ip link set $interface down
airmon-ng start $interface
# iw dev $interface interface add wlan"$x"mon type monitor
((x++))
echo $x
#/usr/bin/screen -d -m -S wlan"$x"mon bash -c "./build_ssid2.sh wlan\"$x\"mon $x" &
done


x=1
interfaces=$(iwconfig 2>/dev/null | egrep '^w' | awk '{print $1}' | grep -v 'wlan0')
for interface in $interfaces; do
intmon=$(iw dev $interface info | grep -B4 monitor | grep Interface | cut -d\  -f2)
ip link set $intmon up
iwconfig $intmon channel $x
#/usr/bin/screen -d -m -S $intmon /usr/sbin/airodump-ng -c $x $intmon
/usr/bin/screen -d -m -S "$intmon"_db ./build_ssid.sh $intmon
((x++))
done

