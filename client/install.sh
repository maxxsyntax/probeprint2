#!/usr/bin/bash
apt-get install git tshark iftop wavemon screen jq curl firmware-realtek firmware-misc-nonfree aircrack-ng ntpdate mariadb-client python3-mysqldb xxd bc
echo NTP=192.168.1.10 >> /etc/systemd/timesyncd.conf


#startup scripts
systemctl disable hciuart.service 
systemctl disable bluealsa.service
systemctl disable bluetooth.service
systemctl disable NetworkManager
systemctl disable wpa_supplicant
systemctl disable avahi-daemon
systemctl disable mariadb
systemctl disable ModemManager
systemctl disable hostapd
#disable onboard bluetooth
echo dtoverlay=disable-bt >> /boot/firmware/config.txt


#configure networking
x=$(((RANDOM%3)+1))
sed -i "s/raspberrypi/node$x/g" /etc/hostname
sed -i "s/raspberrypi/node$x/g" /etc/hosts

nmcli con add con-name C2 type wifi ssid C2 ifname wlan0 ip4 192.168.1.$x/24 gw4 192.168.1.10 ipv4.dns "4.2.2.2,8.8.8.8"
nmcli device set wlan0 autoconnect yes
