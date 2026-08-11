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

1. **Capture** — `capture-scripts/build_ssid.sh` sniffs 802.11 probe requests off a monitor-mode
   interface (via tshark) into the `probeprint` database. `capture-scripts/pcap2db.sh` backfills
   the same way from saved captures.
2. **Correlate & enrich** — `analysis.sh` turns raw SSIDs into intel: category,
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

### Tagging observations by source

Every row in `ssid` carries an optional `tag` recording where it came from, so a
database that accumulates several engagements — or mixes live capture with
imported pcaps — can be sliced back apart:

```sql
select * from ssid where tag = 'acme-red-team-2026';
```

Two ways it gets set, both optional:

- **Live capture** tags rows with the `ENGAGEMENT` name from `.env`. Set it per
  engagement; leave it unset and live rows are tagged `NULL`.
- **`pcap2db.sh` backfill** tags each row with the **pcap filename** it came
  from, regardless of `ENGAGEMENT` — the file is the source of record for
  imported data.

The field is free-form and never required; nothing downstream depends on it. It
exists purely so a merged collection stays separable by provenance.

## HOW TO

Run everything from the repo root.

```
# 1. one-time: create or migrate the database (idempotent)
./build_dbs.sh

# 2a. live capture (interface must already be in monitor mode)
./capture.sh                     # preflight, then live capture
# 2a'. or let start.sh set monitor mode up first, then capture -- this is the
#      crontab/@reboot entry point for an unattended node (needs root)
sudo ./start.sh
# 2b. or backfill from saved captures instead
./capture.sh --pcap capture1.pcap capture2.pcap
./capture.sh --pcap-dir ../wifi_research/caps

# 3. enrich everything captured so far -- offline, incremental, safe to re-run
./analysis.sh
# fetch new WiGLE locations separately, minding the daily quota
./analysis-scripts/online_wigle_fetch.sh --new
# place SSIDs that name a business, for the ones WiGLE could not (see below)
./analysis-scripts/online_places.sh --dry-run

# 3b. how much of what was transmitted did we actually capture?
#     read-only and offline, safe to run during capture
./analysis-scripts/fidelity.sh

# 4. display who is in range
./display.sh                     # live view (default; ^C to quit)
./display.sh devices             # roster of every device
./display.sh device <id|alias>   # one device's full profile and network list
./display.sh recent [seconds]    # everything seen in the last N seconds
```



## Reading the display

Each device in range is one dossier block, headed by the device fingerprint --
that is the thing always present -- with the person's identity below it, on a
`SUBJECT` line and the fields under it, when the network list reveals one.

```
=== Brave Falcon [Apple]   [near by]   SEEN BEFORE: 3 days ago
  Fingerprint  : 3 rotating MACs
  Preferred nets: 8, identifiability 71
  Soft target  : Casa-Perez (password known)
  SUBJECT     : Maria
  Household    : Familia Perez
  Employer     : Vertex Labs Staff
  Language     : es
  Home region  : Bouygues Telecom (FR)
  Frequents    : Amsterdam Schiphol; Hotel Ibis Paris
  Notable nets : Casa-Perez, VertexLabs-Staff
```

What each line means:

| Line | Meaning |
|---|---|
| **header** | The device's fingerprint alias (a stable handle, not a name it broadcast), its hardware vendor, and a coarse proximity band -- **near by / medium range / far away**. RSSI is deliberately banded, never shown as a false-precision distance; see `FINGERPRINTING.md`. |
| **SEEN BEFORE** | This device was here on an earlier visit, at least an hour before the current one. A returning subject is a stronger lead than anything in its network list. |
| **Fingerprint** | How many rotating MAC addresses were collapsed into this one device. "3 rotating MACs" means randomization was defeated -- three addresses proven to be one device. |
| **Preferred nets** | The size of the preferred network list (how many distinct networks the device probes for), and its **identifiability** -- see below. |
| **Soft target** | A network in the list whose WPA password is publicly known (`lists/cracked.txt`) *and* which is rare. It can be impersonated with the known key to lure this specific device. Shown only for rare networks: a cracked `linksys` is on thousands of devices and targets nobody. |
| **SUBJECT** | The perceived human: a personal name probed for, else a household or workplace name standing in. Absent when nothing human is known. |
| **Household / Employer** | Networks categorized as a residence or a workplace/institution. |
| **Language** | Language inferred from the vocabulary of the network names (Latin script), or their script (non-Latin). Only a confident single-language match is shown. |
| **Home region** | The operator/ISP of a device's home-network name, with the country it identifies -- a residential-origin signal. |
| **Frequents** | Every place the network list locates the person: geocoded venues, airports, hotels and travel, eateries, merged under one heading. |
| **Notable nets** | The device's rare networks -- the ones that most single this person out. |

### Identifiability

The **identifiability** score is the sum of the *rarity* of every network the
device probes for. Rarity of one network is `-ln(f)`, where `f` is that SSID's
share of sightings in the global reference corpus (`lists/ssid.csv`): a network
seen everywhere scores near zero, one never seen before scores about 20.

Summed across the list, it answers **how uniquely could this person be picked
out of a crowd by their networks alone**. A device probing only `xfinitywifi`
and `attwifi` scores near zero -- it looks like everyone. A device probing three
household and workplace names nobody else has scores 50+ -- it is effectively a
fingerprint. The higher the number, the more a person stands out, and the more
the rest of the dossier can be trusted to be about one individual.

This is derived directly from Cunche et al.'s finding that the *rarity* of
shared networks, not their count, is what links devices to people; the method
and the thresholds are in `FINGERPRINTING.md`.

## How complete is the capture?

Every pass here treats the `ssid` table as the population. It is a sample. A
passive monitor never hears everything, and the loss is not uniform — so before
concluding that a device was absent, it is worth knowing how much was missed.

`analysis-scripts/fidelity.sh` measures that from data already collected. An 802.11
sequence number is a per-transmitter frame counter, so the gap between two
consecutive captured frames from one address says how many of that device's
frames are missing from the trace. No reference capture is needed.

```
./analysis-scripts/fidelity.sh              whole collection
./analysis-scripts/fidelity.sh --since 300  last 5 minutes
./analysis-scripts/fidelity.sh --load       completeness against channel load
./analysis-scripts/fidelity.sh --channels   which channels were listened to
```

Read-only, offline, safe to run during capture.

### Read the number correctly

It is a **lower bound**. Ingest keeps probe requests only, so a sequence gap has
two causes that cannot be told apart: a frame the monitor missed, and a frame
the device sent that was filtered out on purpose. An associated device browsing
the web therefore looks far worse than an idle one.

That does not spoil the main use. The sequence graph decides two addresses are
one device partly on how large a sequence gap it will tolerate, and for that
purpose both causes are the same event — the counter advanced unobserved. This
measures the gap distribution `SEQGRAPH_ALPHA` and `SEQGRAPH_BETA` should be
fitted to, per venue, instead of the current fixed defaults.

What it is not is a verdict on the radio.

### Channel coverage

The report also lists which channels produced frames, and warns when a band is
effectively unlistened. That matters more than any percentage: a device probing
only on 5 GHz while the rig listens on 2.4 GHz is absent from the collection
entirely, and no enrichment pass recovers it.

Method: Schulman, Levin & Spring, *On the Fidelity of 802.11 Packet Traces*,
PAM 2008 — <http://www.cs.umd.edu/projects/wifidelity/>. The thresholds used
here are ours; see `analysis-scripts/fidelity_functions.sh`.

## Pulling WiGLE locations after an engagement

Capture runs offline (`online=0`), so no SSID is sent to WiGLE while you are in
the field — that would be egress during collection. Geolocation is a deliberate
**post-engagement** step, run when you are back on a network you are willing to
query from.

The location data flows through a cache, so it is a two-stage process:

```
# 1. FETCH: send unlocated SSIDs to WiGLE, cache the JSON responses, summarize.
#    Rarest-first, so the names that identify a person are spent on before the
#    daily quota runs out; common SSIDs are skipped (they place nobody).
./analysis-scripts/online_wigle_fetch.sh --new           # stops when quota is hit
./analysis-scripts/online_wigle_fetch.sh --new --limit 50 # just the 50 most identifying
./analysis-scripts/online_wigle_fetch.sh --new --wait     # block through quota windows, grind

# 2. RESOLVE: turn the cached responses into coordinates and a one-location
#    verdict. Offline -- reads the cache, makes no calls.
./analysis-scripts/geolocate.sh
./analysis-scripts/oneloc.sh
```

Notes:

- **The quota is the constraint, not the corpus.** WiGLE allows a few hundred
  lookups a day on the free tier, and a real capture has tens of thousands of
  unlocated SSIDs — so it takes many days, and the *order* matters. `--new`
  sends the rarest, most recently seen networks first (see the fetch script for
  the ranking) and skips `is_common` ones. Run it daily, or `--wait` it
  unattended.
- **Point `GEO_LOCS_DIR` at your cache.** The response cache lives wherever
  `GEO_LOCS_DIR` says (`wifi_research/locs` in this workspace). Set it in `.env`
  so fetch, geolocate and the summarizer all agree; otherwise they default to
  `./locs`.
- **Re-running is free.** Both stages are idempotent and cache-backed — an SSID
  already fetched is never fetched again, and geolocate only re-reads the cache.
- For SSIDs WiGLE cannot place because nobody wardrove them but which *name* a
  venue, see the Google Places step below.

## Placing SSIDs that name a business

WiGLE can only place an SSID somebody drove past with a radio. Everything else
is a name with no location attached, and on a real collection that is the large
majority. But an SSID like `Cafe Marguerite` names a venue, and the venue is on
the map whether or not anyone ever wardrove it.

`analysis-scripts/online_places.sh` looks those names up through the **Google Places API** and
writes the street address and coordinates.

```
./analysis-scripts/online_places.sh --dry-run   # list what would be sent -- sends nothing
./analysis-scripts/online_places.sh 25          # query at most 25 candidates
./analysis-scripts/online_places.sh             # query at most 200
./analysis-scripts/online_places.sh --report    # coverage summary, no network
```

Set `GOOGLE_PLACES_KEY` in `.env` first, on a key with **Places API (New)**
enabled. This is a different API and a different key from
`GOOGLE_GEOLOCATION_KEY`: that one takes BSSIDs and answers "where is the
observer", this one takes a name and answers "where is that venue". Without the
key the pass refuses to start rather than silently doing nothing.

### A Places answer is weaker evidence than a WiGLE one

WiGLE reports an **observation** — a radio broadcasting this SSID was heard at
these coordinates. Places reports where a **venue of that name is**, which only
becomes a person's location if the SSID really is that venue's network. It is a
good inference for `Cafe Marguerite` and a bad one for a household that named
its router after a favorite restaurant.

So the two are kept apart. Results are written with `geo_source='google_places'`;
filter on that column wherever only observations will do:

```sql
select * from ssid_intel where geo_source = 'wigle';         -- sightings only
select * from ssid_intel where geo_source = 'google_places';  -- inferred
```

**Only SSIDs WiGLE could not place are ever queried.** A row already carrying
observed coordinates is skipped, so a measurement is never overwritten by a
guess — and you never pay to make your data worse.

### Matching is exact, on purpose

Google's text search is fuzzy, so taking its first result would invent locations
for real people. Both sides are normalized first — lowercased, router decoration
stripped (`_5G`, `guest`, `wifi`, `-ext`, …), non-alphanumerics removed — and
then compared exactly:

| SSID | normalized | result |
|---|---|---|
| `Cafe Marguerite` | `cafemarguerite` | matches |
| `CafeMarguerite_5G` | `cafemarguerite` | matches — same venue |
| `Cafe Marguerite Guest` | `cafemarguerite` | matches — same venue |
| `Tortilleria Alice` | `tortilleriaalice` | **refused** |

A name shared by several distant venues — a chain — yields no coordinates at
all, only a recorded `place_match_count`, exactly as the WiGLE path treats an
SSID seen in several cities. Venues clustered inside about a kilometer still
yield a fix. Names shorter than five normalized characters never cost a request.

### Which SSIDs get asked about

Every request costs money and sends a name to Google, so most SSIDs are
rejected before one is spent. `--dry-run` shows the list and the tally:

```
  would query : 912
  rejected    :
         717 mostly digits          unit numbers, serials, phone numbers
         634 street address         "1190 Lowell" -- an address, not a venue
         502 too short              under five letters; matches half a city
         232 router default         NETGEAR, Tenda, MySpectrum: a device, not a place
           3 no vowel               'CptnC' and hex fragments cannot be looked up
```

Also skipped: SSIDs flagged `is_common`, ones `check_name` identified as
somebody's personal or family name, and the `TECH_*` and `OTHER_ANOMALOUS`
categories.

Set `PLACES_REQUIRE_MULTIWORD=1` to additionally require a name of more than one
word. That removes about another 45% — household nicknames tend to be single
tokens — at the cost of dropping genuine one-word businesses. It is off by
default because losing those defeats the point of the pass.

`PLACES_CATEGORY` narrows to a single category. Note that
`LOCATION_SPECIFIC` is **not** the venue category despite the name:
`check_address()` assigns it on the shape `<number> <Word>`, so it holds street
addresses, and the pass excludes it.

### Cost and egress

This sends SSIDs to Google and is billed per request. It is therefore capped per
run, cached under `places/` so a name is never paid for twice, and **not part of
`analysis.sh`** — like `summarize_location.sh`, you run it deliberately. Start
with `--dry-run`, then a small number.

Rows already asked about are never re-queried: the pass is driven by
`place_match_count is null`, so re-running is free.

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

**Full capture-node setup — USB-gadget networking (`g_ether`), the `@reboot`
crontab entry, and why an accurate clock is critical on a Pi with no RTC — is in
[platforms/pi/README.md](platforms/pi/README.md).** Read the time
section before deploying: a node that captures before its clock is set corrupts
`ssid.time`, which is the primary key, and poisons every time-based pass.







