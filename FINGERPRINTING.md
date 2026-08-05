# Device fingerprinting: what the research says, and what this repo implements

Working notes behind the fingerprinting passes. Sources are three papers kept in
`../wifi_research/`:

| Short name | Paper |
|---|---|
| **Pintor 2022** | Pintor & Atzori, *Analysis of Wi-Fi Probe Requests Towards Information Element Fingerprinting*, IEEE GLOBECOM 2022 |
| **Cunche 2012** | Cunche, Kaafar & Boreli, *I know who you will meet this evening! Linking wireless devices using Wi-Fi probe requests*, IEEE WoWMoM 2012 |
| **Cheshire 2019** | Soundararaj, Cheshire & Longley, *Estimating Real-Time Highstreet Footfall from Wi-Fi Probe Requests*, UCL 2019 |

---

## Which Information Elements actually discriminate

Pintor 2022 measured this directly: 22 devices, 18 of which randomise their MAC,
315 captures of 20 minutes each, across six behavioural modes (screen on/off ×
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

Cheshire 2019 exploits the fact that the 12-bit sequence counter in the MAC
header **is not reset when a device rotates its randomised MAC address**. Their
graph:

- nodes are probe requests
- edges go forward in time only, and low → high sequence number
- an edge spans at most α seconds and β sequence numbers
- each node keeps at most one incoming and one outgoing edge, the shortest in
  both dimensions

Connected components are devices. They measured wrap-around at 4096 causing a
split in only **0.5%** of a Google-randomised sample.

**Why this mattered here:** the old `ssid2bursts-seq` searched a fixed
one-second box for probes with `seq` within +60 and RSSI within ±2. It could
group frames *inside* one burst but never chain two bursts, so a device that
rotated its MAC between bursts appeared as two unrelated devices.
`seqgraph_functions.sh` implements the graph, with union-find in awk, and writes
component ids to `ssid.device_id`. Defaults: `SEQGRAPH_ALPHA=90` seconds (Cunche
measured 50–60s between bursts from one device), `SEQGRAPH_BETA=400`. Both
tunable from `.env`.

### Its real failure mode

The test fixtures surfaced this by accident and it is worth recording. Given 19
unrelated devices — different MACs, different SSIDs — that happened to be
stamped within 18 microseconds of each other with sequential sequence numbers,
the graph merged all 19 into a single device. That is correct behaviour on
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

1. **Psim-3 PNL linkage** (Cunche 2012) — links *people*, not devices. All
   inputs now exist. This is the highest-value remaining gap.
2. **Wi-Fi ↔ Bluetooth correlation** — the stated goal in `../idea.txt`, still
   entirely unimplemented. Correlate by co-presence window, RSSI correlation and
   joint appear/disappear. BLE frequently carries a real human name where Wi-Fi
   does not.
3. **Multi-node trilateration** — `client/` already deploys three capture nodes
   writing to one database. The capability is latent and unused.
4. **Timing and behavioural signal** — inter-burst interval, frames per burst,
   channel rotation order are all driver and chipset specific. Pintor's six
   modes show probe rate changes with screen state, which makes it an
   attention signal, not just a presence signal.
5. **Frame length and IE ordering as standalone features** — `ie_order` is now
   captured but nothing consumes it yet beyond the `ie_fp` hash.
6. **PHY-layer fingerprinting** — scrambler seed (Vo-Huu 2016, Bloessl 2015),
   clock skew / carrier frequency offset, IQ imbalance. Survives MAC
   randomisation *and* IE homogenisation. Requires an SDR, not commodity
   monitor mode. Out of scope for this hardware.

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
