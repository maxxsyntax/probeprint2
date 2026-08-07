# probeprint II
## Passive data collection and analysis of IEEE 802.11 and 802.15


## Combining OSINT and SIGINT to Enumerate IRL Threat Actors

Can your organization's security posture be strengthened by monitoring WiFi Probe Requests?  What about Bluetooth Low Energy Beacons? Can identifying names and device information sent in cleartext help you authenticate who you’re talking to? Location data of wireless networks people have previously connected to combined with current location can be used to validate identity.  


Insecure wireless settings can leak information such as names, travel patterns, places of work, language preferences and even types of cars driven.  Imagine a potential candidate at a job fair beaconing in the language of a nation-state threat actor, or a potential business partner with probe requests correlating to a competitor’s office, or even being notified of a flipper zero close enough to clone your RFID badge. 

A real time application of intelligence gained from passively monitoring wireless transmissions from common mobile devices.  An unobtrusive method of collecting and displaying this information.  New acquaintances can be vetted instantly by confirming who they say they are matches the information coming from their devices.  Findings from analyzing large data sets will be presented, demonstrating that this method can be applied to enumerate potential threat actors within a given proximity. 

![image](https://github.com/user-attachments/assets/6464cccc-3178-4bb8-81f6-cd7d17a71772)





## Prerequisites

- curl
- aircrack-ng (suite)
- tcpdump
- jq
- bash
- screen
- Wigle API key
- tshark
- mysql/mariadb




## The three modules

probeprint2 runs as three stages:

1. **Capture** — `build_ssid.sh` sniffs 802.11 probe requests off a monitor-mode
   interface (via tshark) into the `probeprint` database. `pcap2db.sh` backfills
   the same way from saved captures.
2. **Correlate & enrich** — `process.sh` turns raw SSIDs into intel: category,
   name, language, rarity, coordinates, and device identity across MAC rotation.
   It is offline-first — live WiGLE lookups are a separate, opt-in step.
3. **Heads-up display** — `display.sh` shows who is in range now, one block per
   device, with the traits its preferred network list reveals.

## Configuration

Every script reads `.env` from the repo root, and it is gitignored because it
holds credentials. Copy the template and fill it in:

```
cp .env.example .env
$EDITOR .env
```

At minimum set `APIKEY` (WiGLE `name:token`) and `INF` (your monitor-mode
interface); leave `online=0` unless you want live lookups during capture.
`.env.example` documents every option, including geolocation, sequence-graph
tuning, and engagement-specific targeting.

## HOW TO

Run everything from the repo root.

```
# 1. one-time: create or migrate the database (idempotent)
./build_dbs.sh

# 2a. live capture (interface must already be in monitor mode)
./build_ssid.sh
# 2b. or backfill from saved captures instead
./pcap2db.sh capture1.pcap capture2.pcap

# 3. enrich everything captured so far -- offline, incremental, safe to re-run
./process.sh
# fetch new WiGLE locations separately, minding the daily quota
./summarize_location.sh --new

# 4. display who is in range
./display.sh                     # live view (default; ^C to quit)
./display.sh devices             # roster of every device
./display.sh device <id|alias>   # one device's full profile and network list
./display.sh recent [seconds]    # everything seen in the last N seconds
```



## Assumptions
Randomized MAC does not coincide with a known Vendor OUI

~~BLE MAC's are not randomized~~

Devices burst equally on each channel

~~Every probe request carries the SSID of a network the owner has joined~~




## What devices actually send

The preferred network list (PNL) is the set of SSIDs a device has stored for
networks it previously joined and will actively probe for. It is the thing that
makes this pipeline useful — a device fingerprint says *this is one device*, the
PNL says *whose*. But most probe requests are not PNL entries, and the ones that
are have become much rarer since this technique was first published.

### Most probes carry no SSID at all

A probe request with a zero-length SSID field means "any AP, respond". These
carry no network name and are stored with tshark's `<MISSING>` sentinel. In one
real 119,128-frame collection they were **62,594 frames — 52.5% of everything
captured**.

### Directed probes have largely stopped

Cunche et al. published the PNL leak in 2012, and the vendors responded. Since
roughly **iOS 14 and Android 8/9**, phones no longer broadcast their stored
network list in directed probes. The modern pattern is to send wildcard probes,
listen for AP beacons, and associate passively.

So a directed probe carrying a real SSID today usually means one of:

- **A hidden network in the PNL.** Hidden APs omit their SSID from beacons, so a
  client has to ask for them by name. This is the main legitimate remaining case.
- **An older device or OS.**
- **A non-phone device** — IoT, printers, laptops with older stacks.

Two consequences worth planning around:

- **Expect far less than the literature implies.** Cunche measured an average of
  5.34 SSIDs per device on a population that broadcast freely. Do not treat that
  as a target.
- **What you do capture is selection biased, arguably in your favor.** If
  directed probes now come disproportionately from hidden networks, the SSIDs
  harvested skew toward networks someone deliberately tried to hide — usually
  residential, rarely in WiGLE under a common name, and high on the `rarity`
  scale. Fewer entries, but each worth more for linking people.

### Probes that are not PNL entries at all

Not everything with an SSID in it is a network the owner joined:

- **Wi-Fi Direct / P2P discovery** — peer-to-peer service discovery for printing,
  casting and file transfer, typically `DIRECT-` prefixed. The `TECH_PRINTER`
  category already matches these (`DIRECT_`, `HP-Setup`, `Canon_`).
- **Vendor and OS service SSIDs** — setup and provisioning networks probed by the
  device itself, with no user action behind them.
- **Malformed frames** — bit errors and truncation that look like an SSID.
  `check_anomalies` exists for this; it flags hex beginning `00` and runs of
  `ff` as `OTHER_ANOMALOUS`. These are never PNL entries.
- **Stale entries** — networks the owner deleted that some systems keep probing
  for.

### Wildcard probes are still signal

They carry no SSID, but probe rate, burst size and inter-burst timing still
fingerprint the device, and the `<MISSING>` rows preserve all three. This is the
argument for weighting Information Element fingerprinting and sequence-number
device linkage over PNL collection going forward — see
[FINGERPRINTING.md](./FINGERPRINTING.md) for which fields actually discriminate
and which approaches the literature measured as worse.




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

add following to boot/config.txt
dtoverlay=disable-bt

Configure hosapd.conf 


add to /home/pi/
script.sh
start_cap.sh







