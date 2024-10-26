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
done

hostname=$(cat /etc/hostname)
y=1
interfaces=$(iwconfig 2>/dev/null | egrep '^w' | awk '{print $1}' | grep -v 'wlan0')
for interface in $interfaces; do
#start(n)=4(n−1)+1
#y(n)={start(n),start(n)+1,start(n)+2,start(n)+3}
channel=`echo $((4*$((${hostname:0-1}-1))+$y))`
intmon=$(iw dev $interface info | grep -B4 monitor | grep Interface | cut -d\  -f2)

if [[ -n $intmon ]]
then
ip link set $intmon up
iwconfig $intmon channel $channel 
#/usr/bin/screen -d -m -S $intmon /usr/sbin/airodump-ng -c $channel $intmon
/usr/bin/screen -d -m -S "$intmon"_db ./build_ssid.sh $intmon
((y++))
fi
done

