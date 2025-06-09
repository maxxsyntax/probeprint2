# probeprint II
## Passive data collection and analysis of IEEE 802.11 and 802.15


## Combining OSINT and SIGINT to Enumerate IRL Threat Actors

Can your organization's security posture be strengthened by monitoring WiFi Probe Requests?  What about Bluetooth Low Energy Beacons? Can identifying names and device information sent in cleartext help you authenticate who you’re talking to? Location data of wireless networks people have previously connected to combined with current location can be used to validate identity.  


Insecure wireless settings can leak information such as names, travel patterns, places of work, language preferences and even types of cars driven.  Imagine a potential candidate at a job fair beaconing in the language of a nation-state threat actor, or a potential business partner with probe requests correlating to a competitor’s office, or even being notified of a flipper zero close enough to clone your RFID badge. 

A real time application of intelligence gained from passively monitoring wireless transmissions from common mobile devices.  An unobtrusive method of collecting and displaying this information.  New acquaintances can be vetted instantly by confirming who they say they are matches the information coming from their devices.  Findings from analyzing large data sets will be presented, demonstrating that this method can be applied to enumerate potential threat actors within a given proximity. 



![diagram](https://github.com/maxxsyntax/probeprint/assets/145410040/e39e1497-a7fa-40f6-b940-123169f70eae)



## Prerequisites

- bettercap
- curl
- aircrack-ng (suite)
- tcpdump
- jq
- python
- geopy.geocoders import Nominatim
- bash
- screen
- tmux
- Wigle API key
- GNU bash, version 5.2.15 
- tshark
- mysql/mariadb




## HOW TO
put wireless interface in monitor mode
build database with build_dbs.sh
run build_ssid.sh



## Assumptions
Randomized Mac does not coincide with a known Vendor OUI

~~BLE MAC's are not randomized~~

Devices burst equally on each channel




## Raspberry Pi Build
 apt-get install git tshark sqlite3 iftop wavemon screen jq curl firmware-realtek firmware-misc-nonfree aircrack-ng hostapd fbi toilet fbterm ntpdate mariadb-server python3-mysqldb xxd bc

git clone https://github.com/darkmentorllc/Blue2thprinting
git clone https://github.com/maxxsyntax/probeprint2

systemctl disable NetworkManager
systemctl disable wpa_supplicant
systemctl disable avahi-daemon
systemctl disable mariadb
systemctl disable ModemManager
sudo systemctl unmask hostapd
sudo systemctl enable hostapd
sudo systemctl start hostapd

add folloing to boot/config.txt
dtoverlay=disable-bt

Configure hosapd.conf 


add to /home/pi/
script.sh
start_cap.sh







