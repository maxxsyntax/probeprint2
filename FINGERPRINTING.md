# Device fingerprinting: what the research says, and what this repo implements

Working notes behind the fingerprinting passes. Sources are three papers kept in
`../wifi_research/`:

| Short name | Paper |
|---|---|
| **Pintor 2022** | Pintor & Atzori, *Analysis of Wi-Fi Probe Requests Towards Information Element Fingerprinting*, IEEE GLOBECOM 2022 |
| **Cunche 2012** | Cunche, Kaafar & Boreli, *I know who you will meet this evening! Linking wireless devices using Wi-Fi probe requests*, IEEE WoWMoM 2012 |
| **Cheshire 2019** | Soundararaj, Cheshire & Longley, *Estimating Real-Time Highstreet Footfall from Wi-Fi Probe Requests*, UCL 2019 |
| **Vanhoef 2016** | Vanhoef, Matte, Cunche, Cardoso & Piessens, *Why MAC Address Randomization is not Enough: An Analysis of Wi-Fi Network Discovery Mechanisms*, ACM ASIA CCS 2016 |

---

## Which Information Elements actually discriminate

Pintor 2022 measured this directly: 22 devices, 18 of which randomize their MAC,
315 captures of 20 minutes each, across six behavioral modes (screen on/off ×
connected/not × power-saving). Random Forest Gini importance, mode A:

| IE | Name | % of frames | Gini | Captured here |
|---|---|---|---|---|
| 127 | Extended Capabilities | 83.6% | **0.34** | `ssid.extcap` |
| 45 | HT Capabilities | 96.8% | **0.175** | `ssid.ht` |
| 221 | Vendor Specific | 91.1% | **0.162** | `ssid.vendor_oui` |
| 255 | Element ID Extension (HE/EHT) | 14.4% | 0.081 | not yet |
| 0 | SSID | 100% | 0.088 | `ssid.ssid_hex` |
| 191 | VHT Capabilities | **11.1%** | **0.073** | `ssid.vht` |
| 1 | Supported Rates | 100% | 0.056 | no |
| 50 | Extended Supported Rates | 99.9% | 0.024 | no |
| 3 | DS Parameter Set | 97.9% | 0.024 | no |
| 107 | Interworking | 3.3% | 0.001 | no |

DBSCAN over **just {45, 127, 221}** clustered probe requests to the correct
device about **92%** of the time (mode A: 21 devices → 21 clusters, homogeneity
0.967). Adding the weaker IEs made results *worse*, not better.

**Why this mattered here:** until this work the pipeline captured IE 191 (VHT)
and nothing else — the rarest of the ten IEs in their dataset and roughly a
fifth as discriminative as Extended Capabilities. `ingest_functions.sh` now also
captures IE 45, 127 and 221 plus `wlan.tag.number`, the IE presence-and-ordering
list, which fingerprints a device independently of any IE's contents. The
combination is hashed into the generated column `ssid.ie_fp`.

`ssid.vht` is kept for continuity with historical rows, not because it earns its
place.

### Two caveats that limit IE fingerprinting

- **It identifies a device model and OS build, not a person.** Pintor 2022 calls
  this out for iOS specifically: devices on the same updated version emit
  identical IEs and become indistinguishable. In an Apple-heavy crowd, IE
  fingerprinting collapses toward counting models rather than people.
- **IE 3 (DS Parameter Set) being empty is poison.** When it is absent the
  *other* IEs change content, so one device splits across two clusters. Pintor
  discarded those frames — under 4% of packets. Not yet handled here.

---

## SSID rarity, and why binary "common" throws away the signal

Cunche 2012 collected 8,834 devices and 26,262 SSIDs over six months in Sydney,
plus a control set of 30 device pairs with known social links.

- A preferred network list averages only **5.34 SSIDs**, but because most SSIDs
  are unique to one device, each list is close to a unique identifier.
- **100%** of socially-linked device pairs shared at least one SSID.
  **Over 90%** of unlinked pairs shared none.
- Intersection *size* alone is not enough. What separates a real link from a
  coincidence is the **rarity** of the shared SSIDs.

Their metric comparison, best to worst:

| Metric | Formula | Notes |
|---|---|---|
| **Psim-3** | `Σ 1/f(z)³` over shared SSIDs | Best. `q=3` beat other exponents |
| Cosine-IDF | `Σ IDF²/(√Σ IDF²·√Σ IDF²)` | Comparable, but degenerate: identical lists always score exactly 1.0 regardless of how large or rare they are |
| Adamic | `Σ 1/log f(z)` | Poor |
| **Jaccard** | `\|X∩Y\| / \|X∪Y\|` | **Worst** — ignores rarity entirely |

Operating points on their control set (Psim-3):

| Threshold | TPR | FPR |
|---|---|---|
| 0.162 | 0.10 | **0** |
| 1.57 × 10⁻⁵ | 0.80 | 0.077 |
| 1.19 × 10⁻⁸ | 1.00 | 0.262 |

At the middle threshold the classifier reduced 8,000+ devices to an average of
**28 candidates** — 0.35% of the dataset.

**Why this mattered here:** `is_common` is a binary in-the-list / not-in-the-list
test, which is precisely the Jaccard failure mode. It cannot distinguish
`xfinitywifi` (21.8M sightings) from an SSID seen 250 times; both are simply
"common". `rarity_functions.sh` adds the continuous score:

```
f(z)      = sightings of z / total sightings in lists/ssid.csv
rarity(z) = -ln f(z)
```

On the shipped list (208,028 SSIDs, 368.6M sightings) that spans roughly **2.83**
for `xfinitywifi` to **19.72** for any SSID absent from the corpus. Those absent
ones — personal, family and workplace network names — carry nearly all the
linkage signal.

`is_common` is untouched; nothing that reads it needs to change.

### Not yet built

Rarity is the *input* to linkage, not linkage itself. The obvious next step is a
pairwise Psim-3 scorer over per-device SSID sets, producing candidate links
between devices and therefore between people. The data it needs is now all
present: `ssid_intel.rarity` and per-device SSID sets from `ssid.device_id`.

---

## Sequence-number graphs beat sequence-number windows

The core observation — that the 12-bit sequence counter is **not reset when a
device rotates its randomized MAC** — is Vanhoef 2016's. They pair it with the IE
fingerprint (§3, below): cluster probes by IE fingerprint first, then split each
cluster by sequence-number continuity, and you track a device across MAC rotation
without any stable identifier. On real datasets that recovered as much as 50% of
devices over 20 minutes. It is the method this repo's `seqgraph` is a variant of;
Cheshire 2019 refined the same idea into an explicit graph, which is what we
implement.

Cheshire 2019's graph:

- nodes are probe requests
- edges go forward in time only, and low → high sequence number
- an edge spans at most α seconds and β sequence numbers
- each node keeps at most one incoming and one outgoing edge, the shortest in
  both dimensions

Connected components are devices. They measured wrap-around at 4096 causing a
split in only **0.5%** of a Google-randomized sample.

**Why this mattered here:** the old `ssid2bursts-seq` searched a fixed
one-second box for probes with `seq` within +60 and RSSI within ±2. It could
group frames *inside* one burst but never chain two bursts, so a device that
rotated its MAC between bursts appeared as two unrelated devices.
`seqgraph_functions.sh` implements the graph, with union-find in awk, and writes
component ids to `ssid.device_id`. Defaults: `SEQGRAPH_ALPHA=90` seconds (Cunche
measured 50–60s between bursts from one device), `SEQGRAPH_BETA=400`. Both
tunable from `.env`.

### Identity, and why the alias is not the identity

`devices.id` is an autoincrement surrogate key. `devices.device_key` is derived
from the component's **earliest observation** — `substr(md5(anchor_time),1,16)`
— which makes it merge-stable: when two components join, the merged component's
earliest frame belongs to whichever started first, so that key survives and the
other is absorbed. Two analysts recomputing independently get the same keys.

An earlier scheme used the per-run array index (`dev-%06d`). It was not stable:
incremental runs restarted the index at zero and reissued ids already in use, so
unrelated devices shared one. Reproduced and fixed.

`devices.alias` is an adjective-noun handle from `lists/adjectives.txt` ×
`lists/nouns.txt` (347 × 282 = 97,854 combinations; 50% chance of a duplicate at
368 devices, handled with a numeric discriminator). It exists because an
operator in a room can hold "Brave Falcon" in their head and cannot hold
`device 4127`. It is a **non-key attribute** and nothing joins on it.

Two deliberate choices. The name is derived from `device_key`, so a recompute
never renames a device — a memorable name that silently changes is worse than a
number, because it manufactures false confidence in continuity. And the name is
**stored, not recomputed on read**, so two devices can never display the same
handle.

An earlier idea was to source the noun from the device *class* so that same-model
devices shared a noun. Dropped: `ie_fp` says two devices are the same class, not
*which* class, and there is no public corpus mapping 802.11 probe IE signatures
to models. Naming a slot after something unresolvable makes the name arbitrary
while implying it is not. Vendor — which *is* partially resolvable, from a
non-randomized MAC OUI or the IE 221 vendor OUI — is shown as its own field.

### Burst-derived features: weak as identity, useful as a gate

Pintor 2022 §V.C computed exactly the burst-level features that look promising —
"the number of packets sent in a burst, the difference between the
first-intra-burst sequence number and the last one, and other characteristics" —
and clustering on them was **worse** than per-frame. So burst structure is not
built here as a competing identity signal. Two better uses:

- **Gate the graph's edges.** `SEQGRAPH_GATE_IE=1` refuses an edge between two
  frames whose IE fingerprints positively disagree, since one device cannot
  change its signature mid-capture. This converts the confidence flag from
  after-the-fact detection into prevention. Measured on the test fixtures: two
  interleaved real devices merge without it and stay separate with it.
- **Behavioral state.** The intra-burst sequence delta is a clean
  associated/unassociated discriminator — if N probes advance the counter by
  exactly N−1 the device is sending nothing else. Combined with Pintor's finding
  that probe rate tracks screen state, that is an attention signal, orthogonal
  to identity.

### Burst boundaries: gap-based, not a fixed window

Burst detection used to claim everything within one second of whichever frame
happened to anchor the burst, then anchor the next burst on the first unclaimed
frame. That splits a continuous run at an arbitrary point and caps
`burst_duration` at the window by construction — the value could never report
anything longer, whatever the traffic did.

Six frames from one MAC, each 0.8s after the last:

| shape | bursts | sizes | durations |
|---|---|---|---|
| `window` | 3 | 2, 2, 2 | 0.8s each |
| `gap` | 1 | 6 | 4.0s |

`BURST_SHAPE=gap` (the default) instead continues a burst for as long as frames
keep arriving within `BURST_GAP` of the previous one, with no ceiling.
`BURST_SHAPE=window` is retained so the two can be compared on a given capture.

Measured on a real collection the aggregate effect was modest — slightly fewer,
slightly larger bursts — but the duration ceiling was absolute, and the tail is
where the long bursts are. Check both shapes on your own capture before treating
`burst_size` or `burst_duration` as a feature; the numbers for any particular
collection belong in that engagement's notes, not here.

### RSSI is not an identity signal

Both the sequence and VHT burst passes used to require two frames to be within
**±2 dBm** to be considered the same burst. Measured against Pintor & Atzori's
labelled corpus — 22 known devices, stationary, in a semi-anechoic chamber,
which is about the quietest environment such a capture can have:

| | |
|---|---|
| mean jump between consecutive frames from **one** device | **9.6 dBm** |
| consecutive same-device pairs exceeding 2 dBm | **40%** |
| exceeding 10 dBm | **23%** |
| within-device standard deviation | **13.4 dBm** |
| between-device spread of per-device means | **3.0 dBm** |

The noise is **4.5× the signal**: one device's own readings scatter four times
wider than the devices differ from each other. The ±2 dBm gate was therefore
rejecting about 40% of genuine same-device pairs, and the `seq` pass — the one
that can see through MAC randomization — was almost entirely disabled by it.
Both gates are gone.

This is Cheshire 2019's conclusion reached from the other direction, and it
matches Pintor 2022 finding that adding weaker features made IE clustering
worse. RSSI remains right for qualitative proximity in `display.sh`. It carries
no identity.

### Static MACs are free ground truth

The minority of devices that do not randomize are the most useful thing in a
capture, and not as a fingerprint. For them the MAC *is* the identity, with no
inference, which makes them labeled data present in every real capture:

- two globally-unique MACs in one cluster → **provable false merge**
- one globally-unique MAC across two clusters → **provable false split**

`seqgraph_validate` (`standalone_seqgraph.sh --validate`) scores the clustering
against them and prints both rates plus the offending MACs. That is a measured
error rate at the current α/β in the real environment, rather than a number from
a synthetic fixture, and it is the right way to tune α and β per site.

Randomized addresses are the locally-administered ones — bit 1 of the first
octet set, bit 0 clear for a unicast source — so the second hex digit is one of
`2`, `6`, `a`, `e`. This is Cheshire's shortcut.

**They are an input, not only a check.** For a long time this was used solely to
score the clustering afterwards, while the graph itself never saw `wlan_sa` — it
selected only time, sequence number and IE fingerprint. A device that does not
randomize could therefore be held together only by sequence continuity, and
fragmented whenever that broke. Against labelled ground truth one device with a
single address and a single IE fingerprint came out as **137 separate devices**.

`seqgraph_assign` now unions frames sharing a globally-administered MAC before
any inference runs. On the same corpus that alone took the total from 1,102
clusters to 852 and made every non-randomizing device whole, without introducing
a single false merge. If the answer is known, do not infer it.

### Calibrating α and β against labelled data

`--validate` measures error on your own capture, which is what matters at a
site, but it can only score the static minority. Pintor & Atzori publish a
labelled corpus where every capture is one known device *including* the
randomizing ones (CC-BY-4.0; see `../wifi_research/DATASETS.md`), which turns
α/β from a guess into a measurement.

Sweeping it produced a clear result: **α=90/β=400, the defaults, are far too
tight**, over-splitting roughly ninefold against the achievable floor while
producing no false merges to justify the caution. Widening to α=1200/β=4095 —
β=4095 being the ceiling, since the counter is 12 bits — reached within 14% of
the floor, still with zero false merges.

Two caveats before copying those numbers into `.env`. That corpus is 22 devices
in a chamber; a false merge needs two devices whose counters coincidentally
align, and the risk of that scales with the population in range, so a conference
floor is a different problem. And the floor itself is set by capture sessions —
frames from one device days apart cannot and should not be linked by any α.

What transfers is the direction and the method: the defaults are too
conservative, and the boundary should be found by widening until `--validate`
reports the first merge, not assumed.

### Its real failure mode

The test fixtures surfaced this by accident and it is worth recording. Given 19
unrelated devices — different MACs, different SSIDs — that happened to be
stamped within 18 microseconds of each other with sequential sequence numbers,
the graph merged all 19 into a single device. That is correct behavior on
incoherent input, but it is exactly what a dense environment produces: **in a
crowded space, unrelated devices whose sequence counters happen to interleave
inside α will be falsely merged.**

Mitigations, none implemented yet: tighten α in dense captures; require IE
fingerprint (`ie_fp`) agreement before allowing an edge; require RSSI
consistency. Sanity-check any deployment with `standalone_seqgraph.sh --report`,
which lists devices by how many MAC addresses each absorbed — an implausibly
large MAC count is the signature of a false merge.

---

## Note on burst-level vs per-frame analysis

**This is the item deliberately not acted on, recorded so the tension is not
rediscovered later.**

Pintor 2022 §V.C tried clustering at burst granularity rather than per frame and
found it **reduced** accuracy. Their reason is sample starvation: compacting
69,700 probe requests into 4,789 bursts and taking one representative frame from
each "drastically reduces the amount of input data for the classifier."

This repo is burst-centric throughout — `bursts_functions.sh`, the `bursts`
table, `related_burst`, `is_uniq`. So the finding reads as a warning against the
architecture. It mostly is not, for one specific reason:

- **They took one frame per burst; this pipeline aggregates the SSID set across
  the burst.** Those are different operations. Discarding frames loses IE
  samples, which is what hurt their classifier. Aggregating SSIDs *gains*
  information, and produces exactly the preferred-network-list structure that
  Cunche 2012 links people with.

The practical rule, and the reason both code paths are kept:

| Task | Granularity | Where |
|---|---|---|
| Assembling a device's preferred network list | **Burst** | `bursts_functions.sh` |
| IE fingerprinting a device model/OS | **Per frame** | `ssid.ie_fp` |
| Chaining a device across MAC rotation | **Per frame** | `seqgraph_functions.sh` |

Do not feed burst representatives into IE fingerprinting — that is the case
Pintor measured as worse, and it would throw away roughly 93% of the IE samples.

`ssid2bursts-seq` is therefore left in place rather than replaced by the
sequence graph. It still drives the `is_processed` state machine that the VHT
pass consumes, and burst rows remain the right shape for PNL assembly. The two
answer different questions: bursts group SSIDs, the graph groups frames into
devices.

---

## Methods identified but not implemented

Roughly in descending order of value for this engagement:

1. **Psim-3 PNL linkage** (Cunche 2012) — links *people*, not devices. Every
   input now exists as a table: `device_ssid` holds each device's list and
   `ssid_intel.rarity` holds the per-SSID weight, so the metric is a join away:
   `Psim-3(X,Y) = Σ 1/f(z)³` over the SSIDs two devices share. This is the
   highest-value remaining gap.
2. **Wi-Fi ↔ Bluetooth correlation** — a stated goal of the engagement (see the
   workspace `../CLAUDE.md`), still entirely unimplemented: it would join this
   database to Blue2thprinting's `bt2`, and nothing links the two today.
   Correlate by co-presence window, RSSI correlation and joint
   appear/disappear. BLE frequently carries a real human name where Wi-Fi does
   not.
3. **Multi-node trilateration** — the `client/` tree that deployed three capture
   nodes into one database was deleted in Aug 2026; recover it from git history to
   revive this. The Pi-side glue survives as `capture-scripts/pi/`.
4. **Timing and behavioral signal** — inter-burst interval, frames per burst,
   channel rotation order are all driver and chipset specific. Pintor's six
   modes show probe rate changes with screen state, which makes it an
   attention signal, not just a presence signal.
5. **Frame length and IE ordering as standalone features** — `ie_order` is now
   captured but nothing consumes it yet beyond the `ie_fp` hash.
6. **WPS UUID → real MAC.** Vanhoef 2016 §3.2 showed the WPS Universal Unique
   Identifier some devices include in probe requests is `wpa_supplicant`'s
   `SHA-1(real_MAC, fixed_salt)` truncated to 16 bytes. The MAC space is small
   enough to brute-force, so the UUID **reverses to the real, non-randomized
   MAC** — they recovered it for ~75% of WPS-advertising devices, and the real
   MAC is directly WiGLE-able. Only a minority of devices emit the element
   (single-digit percentages in their datasets), but for those it defeats
   randomization outright with a purely passive capture. This is the one new
   finding here that is exploitable on commodity monitor-mode hardware; it needs
   `wps.uuid_e` captured in `ingest_functions.sh` and an offline reversal pass.
   The same element's presence/stability is also a weak IE feature (Pintor's
   "WPS UUID" row).
7. **PHY-layer fingerprinting** — scrambler seed (Vo-Huu 2016, Bloessl 2015;
   Vanhoef 2016 §5 found commodity radios use predictable seeds, adding ~7 bits
   and up to +10% tracking), clock skew / carrier frequency offset, IQ
   imbalance. Survives MAC randomization *and* IE homogenisation. Requires an
   SDR, not commodity monitor mode. Out of scope for this hardware.

Two active attacks from the same paper are noted but deliberately **out of
scope** — this is a passive collector. Vanhoef 2016 §6 revealed the real MAC of
17.4% of devices by broadcasting popular SSIDs (a revived Karma attack) and 5.2%
via a fake Hotspot 2.0 AP soliciting ANQP queries. Both require transmitting, so
they belong to an engagement's active phase, not this pipeline.

## Trace fidelity: measuring what was not captured

Every pass here treats the `ssid` table as the population. It is a sample, and
not a uniform one. Schulman, Levin & Spring, *On the Fidelity of 802.11 Packet
Traces* (PAM 2008), showed that a passive monitor's **completeness** — the
fraction of transmitted frames it actually records — varies sharply with network
load, venue and channel, and argued that any analysis over a trace should first
establish how complete that trace is. Their **T-Fi plots** put completeness on
one axis against offered load on the other.

Project and GPL tooling: <http://www.cs.umd.edu/projects/wifidelity/>, also
archived as CRAWDAD `tools/analyze/pcap/wifidelity`. Their `tracestats` estimates
completeness from **802.11 sequence numbers**, which is the part that transfers
directly: the counter is a per-transmitter frame index, so the gap between two
consecutive captured frames from one address says how many of that device's
frames went unrecorded, with no reference trace required.

Three consequences for this pipeline:

- **The sequence graph's tolerances are a fidelity parameter.** `SEQGRAPH_ALPHA`
  and `SEQGRAPH_BETA` decide how large a sequence gap may be and still be
  treated as the same device. That is exactly the quantity `tracestats`
  measures. Note the gap has two causes that are indistinguishable and,
  for this purpose, equivalent: a frame the monitor missed, and a non-probe
  frame the device sent that ingest filters out. Either way the counter advanced
  unobserved, so the observed gap distribution is the right thing to fit the
  tolerances to — per venue, rather than as a global constant.
- **Absence is not evidence.** `device_ssid` is a lower bound on a preferred
  network list, so `pnl_size` and `pnl_rarity` understate identifiability, and
  "not in range" may mean "not captured". A completeness figure is what lets
  either be qualified rather than asserted.
- **Merged traces are the mitigation, and are also what they studied.** Multiple
  monitors improve completeness non-uniformly. The `client/` tree that wrote
  several capture nodes into one database was deleted in Aug 2026 and is
  recoverable from git history; reviving it is what would make this measurable
  here rather than assumed. Channel coverage is the same argument one level up:
  a single-radio
  capture on one band cannot see probes sent on another, and that is a gap no
  amount of enrichment recovers.

  Robyns et al. published simultaneous captures of one festival crowd from
  several monitoring stations (CC-BY-4.0; see `../wifi_research/DATASETS.md`).
  Counting distinct devices as stations are added:

  | monitors | coverage of the full union |
  |---|---|
  | 1 | **44%** |
  | 2 | 60% |
  | 3 | 73% |
  | 4 | 88% |
  | 5 | 100% |

  **One radio saw fewer than half the devices five radios saw**, and the curve
  had not flattened at five. Note this measures something the sequence-number
  estimator structurally cannot: a device never heard at all leaves no counter
  to find a gap in. Completeness has two independent components — frames missed
  from devices you did hear, and devices you never heard — and only the first is
  estimable from a single trace.

Implemented as `standalone_fidelity.sh` / `fidelity_functions.sh`. Read-only,
offline, safe to run during capture. The thresholds there (burst gap, maximum
attributable delta) are ours: the paper's own parameters could not be
recovered from the published PDF.

### On RSSI

Cheshire 2019 tried and abandoned RSSI → distance conversion: signal decay is
not constant with respect to distance once atmospherics, obstructions and
transmit power vary. What worked was clustering the RSSI *distribution* to find
the break between foreground and background, rather than using absolute values.
Their algorithm comparison, on 40,000 probe requests:

| Algorithm | Time (s) | MAPE |
|---|---|---|
| Hierarchical clustering | 172.5 | **−9%** |
| K-Means | 0.007 | −23% |
| Quantile | 0.002 | +27% |
| Bagged clustering | 0.135 | −30% |
| Fisher | 3.034 | −30% |
| Jenks Natural Break | 556.3 | −30% |

Hierarchical is roughly 3× more accurate but 25,000× slower than K-Means, which
is a real tradeoff for anything driving a live display.

`display.sh` currently thresholds RSSI at fixed values (−66, −82 dBm) to bucket
devices as near / medium / far. Per the above that is unreliable across sites;
a distribution break would travel better.

---

## Geography in a conference capture: dispersion, not coherence

An earlier draft of this document proposed treating a geographically tight PNL
as the signal and a distant SSID as a probable false match. **That is wrong for
this dataset and worth recording so it is not proposed again.**

Much of the collection is taken at conferences. Attendees fly thousands of
kilometres to be there, and their preferred network lists carry venues from past
conferences on other continents. A coherent cluster is not the expected shape,
and a distant SSID is frequently the most informative entry rather than noise.

What actually works on travel-heavy data:

- **Partition the PNL by category before doing any geometry.** The categories
  already exist. Residential and `NAME`-bearing SSIDs cluster around a home;
  `BIZ_HOTEL`, `TRAVEL` and `is_airport` entries are a trajectory;
  `BIZ_INSTITUTION` / `INDUSTRY_ORG` point at an employer. Averaging all three
  together yields a coordinate in the ocean.
- **Dispersion is itself a feature.** A list spanning three continents marks a
  frequent international traveller; one confined to a single metro marks a
  local. That is a useful segmentation at a conference, where both are present.
- **Shared *distant* venues are the strong link.** Two attendees who both probe
  for the same past conference SSID, or the same hotel in another country, have
  correlated travel history. Those SSIDs are globally rare, so Cunche's rarity
  weighting already scores them highly — the metric works here unchanged.
- **Home location still resolves**, but only from the residential partition.

### Local frequency, not just global rarity

One correction the conference setting forces on the rarity metric. `rarity` is
derived from `lists/ssid.csv`, a *global* sighting count. The conference's own
SSID is globally rare — few APs, short-lived — so it scores high, yet every
attendee in the room probes for it, which makes it worthless for telling them
apart.

The fix is a second term: document frequency within the capture itself. An SSID
probed by most devices present should be discounted regardless of its global
rarity, which is ordinary TF-IDF with the local capture as the corpus.
`make_ignore_list` gestures at this with a fixed threshold of 40 distinct MACs;
a continuous local-frequency weight alongside the global one would be correct.
Not implemented.
