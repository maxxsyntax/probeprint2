# probeprint2

Passive collection and analysis of 802.11 probe requests. Bash + tshark +
MariaDB. Captured frames land in one database, `probeprint`; a series of
enrichment passes turn raw SSIDs into intel (category, name, location, device
fingerprint, rarity), and grouping passes turn frames into devices.

The research this is built on, and which fingerprinting methods are worth the
effort, is written up in [FINGERPRINTING.md](./FINGERPRINTING.md). Read it
before changing anything in the fingerprinting or grouping passes — several
obvious-looking "improvements" are things the literature measured as worse.

---

## This handles real PII

SSIDs, MAC addresses, device names and inferred home/work locations of
identifiable people. Two consequences for anyone working in this repo:

- **Never commit captured data.** `.env`, `locs/`, `logs/`, `lists/ignore.txt`,
  `lists/industry.txt` and `*.db` are gitignored for this reason. Do not add
  captured SSIDs to test fixtures, commit messages, or issue text.
- **Per-pass logs are captured data too.** `analysis.sh` writes them to `logs/`
  (mode 700, override with `PP_LOG_DIR`) rather than `/tmp`, because they carry
  SSIDs, device MACs and derived locations, and a predictable world-readable
  path publishes those to every account on the host.
- **Never send collected data to a third-party service** without explicit
  authorization. WiGLE lookups send SSIDs to wigle.net; that is inherent to the
  tool, but it is still egress.

## Run everything from the repo root

Every script resolves `.env`, `lists/` and `locs/` relatively, so `cd` into
`probeprint2/` first.

```bash
# one-time; idempotent, and migrates an existing collection in place
./build_dbs.sh
mkdir -p locs                # WiGLE response cache, gitignored

# capture (interface must already be in monitor mode)
./capture-scripts/build_ssid.sh

# backfill from saved captures instead
./capture-scripts/pcap2db.sh capture1.pcap capture2.pcap

# enrichment: every pass, in dependency order -- the normal way to run them
./analysis.sh                 # incremental; skips rows already enriched
./analysis.sh --recompute     # re-derive everything
./analysis.sh --list          # show the passes and stop

# or pick them off individually
./analysis-scripts/categorize.sh
./analysis-scripts/name.sh
./analysis-scripts/airport.sh
./analysis-scripts/rarity.sh
./analysis-scripts/slow_summarize_loc.sh

# grouping
./analysis-scripts/bursts.sh            # SSID sets per burst
./analysis-scripts/seqgraph.sh     # devices, chained across MAC rotation
./analysis-scripts/seqgraph.sh --report   # roster: alias, confidence, MACs absorbed

# geolocation (post-capture; the default path is offline)
./analysis-scripts/geolocate.sh           # coords from the locs/ WiGLE cache
./analysis-scripts/geolocate.sh --bssids  # harvest BSSIDs from directed probes
./analysis-scripts/geolocate.sh --addresses # reverse geocode via Nominatim (network)

# named venues -> street address, for SSIDs WiGLE could not place
# (network, billed per request, deliberately not in analysis.sh)
./analysis-scripts/online_places.sh --dry-run    # show what would be sent, send nothing
./analysis-scripts/online_places.sh 25           # query at most 25 candidates
./analysis-scripts/online_places.sh --report     # coverage, no network

# how much of what was transmitted did we actually capture (read-only, offline)
./analysis-scripts/fidelity.sh            # completeness, load banding, channel coverage
./analysis-scripts/fidelity.sh --since 300

# live display
./display.sh
```

Only three orderings actually matter, and `analysis.sh` encodes them:
`analysis-scripts/ssid2ssid_intel.sh` first, because nothing else has rows to work on;
rarity before seqgraph, because `pnl_rarity` sums `ssid_intel.rarity`; geolocate
before oneloc, because `is_oneloc` derives from `geo_match_count` and refuses
rather than guessing without it. `analysis.sh` makes **no network call** —
`analysis-scripts/online_wigle_fetch.sh --new` is the WiGLE fetch and is deliberately separate.

`diagnose_legacy_rows.sh` is read-only and reports rows that look like they were
written by the pre-2025 ingest parser (see *Ingest* below).

## Required config

`.env` is required and gitignored. It must define:

| Variable | Meaning |
|---|---|
| `APIKEY` | WiGLE credentials as `user:pass`, for `curl -u` |
| `INF` | Monitor-mode interface name |
| `online` | `1` enables live WiGLE lookups in `build_ssid.sh`; anything else skips them |

Optional: engagement-specific `categories["INDUSTRY_ORG"]`, `["INDUSTRY_VIP"]`,
`["INDUSTRY_PERSON"]`, `["INDUSTRY_EVENT"]` keyword lists, deliberately kept out
of git. `SEQGRAPH_ALPHA` / `SEQGRAPH_BETA` tune the sequence graph.

---

## Tests

Docker-based, with its own MariaDB and tshark inside the container so the SQL
and packet-parsing paths are exercised for real rather than mocked.

```bash
docker build -f test/Dockerfile -t probeprint2-test .
docker run --rm probeprint2-test                       # all cases
docker run --rm probeprint2-test test/run_tests.sh 09  # matching cases only
```

**Tests must never make a network call.** `test/fixtures/locs/` pre-populates the
WiGLE cache so the fetch path short-circuits, and the container's `.env` sets
`online=0`. The WiGLE daily quota is not a test resource. See
[test/README.md](./test/README.md) for what each case covers.

---

## Schema

`build_dbs.sh` is the schema of record. It creates tables with their original
columns and then applies `add column if not exists`, so a fresh install and an
existing collection converge on the same schema — **add new columns as `ALTER`
statements, not by editing the `CREATE`**, or live collections will silently
miss them.

| Table | Holds |
|---|---|
| `ssid` | One row per observed probe request |
| `ssid_intel` | One row per distinct SSID: the enrichment output |
| `bursts` | Groups of probes emitted together |
| `ssid_freq` | SSID → global sighting count, loaded from `lists/ssid.csv` |
| `devices` | One row per inferred physical device |
| `device_ssid` | **The preferred network list**: which SSIDs each device probes for |
| `device_stage` | Scratch table the sequence graph joins through |
| `bssid_geo` | BSSIDs harvested from directed probes, and where they resolve |

### Conventions that will bite you

- **SSIDs are stored and compared as lowercase hex** (`ssid_hex`), decoded with
  `xxd -r -p` only for display or keyword matching. This is what lets
  string-interpolated SQL survive SSIDs containing quotes, spaces and null
  bytes. Where a decoded SSID must reach an external tool, pass it as a
  parameter — `location_functions.sh` uses `jq --arg` for exactly this reason.
- **`time` is a varchar holding a float epoch, and it is the primary key.** Two
  frames sharing a timestamp collide; ingest uses `insert ignore`, so one wins.
  Anything addressing a row by time must use the original string, never a
  reformatted float.
- **`rssi` is a varchar** and may hold comma-separated per-antenna values. Shell
  code does `cut -d, -f1`; **SQL must `cast(rssi as signed)`**. As strings,
  `'-42' <= '-40'` is false, which silently prevents any RSSI-banded grouping
  from ever matching.
- **`freq` and `seq` are integers**, so an empty capture field must be inserted
  as `NULL` via `nullif(…,'')` — MariaDB strict mode rejects `''`.
- **`is_processed`** is the burst pipeline's state machine: `0` unprocessed,
  `1` no burst by MAC, `2` none by sequence, `3` none by VHT, `100` in a burst.
- Wildcard probes arrive from tshark as the literal string `<MISSING>` and are
  stored verbatim; downstream queries filter on it.
- `ie_fp` is a **generated** column. Do not write to it.
- **`ssid_intel.score` is retained but never written.** `score()`/`bump_score()`
  were deleted; identifiability is expressed by `rarity` and `pnl_rarity`
  instead. It is also the one column that demonstrates the `ALTER` rule above in
  the breach — it exists only in the `CREATE`, so a collection predating it does
  not have it at all. Harmless now that nothing reads it, but do not add a
  column that way.
- **`devices.id` is the only device identity.** It is an autoincrement surrogate
  key: never reused, never renumbered. `devices.alias` ("Brave Falcon") is a
  **non-key display attribute** — never join on it, never put it in a foreign
  key. `devices.device_key` is the content-derived natural key, computed from
  the component's earliest observation so it survives cluster merges.
- **`devices.confidence`** is derived from IE consistency. One physical device
  cannot change its IE signature mid-capture, so `low` means the component spans
  several `ie_fp` values and is probably two devices merged in error — the known
  failure mode of the sequence graph in dense environments. Treat `low` as
  "do not act on this" and `unknown` as "no IE data captured".
- **`device_ssid` is the deliverable.** A device id says "one device"; its SSID
  list says whose. `devices.pnl_size` counts it and `devices.pnl_rarity` sums
  the rarity — how identifying the list is as a whole. A device probing only
  `xfinitywifi` scores near zero and is effectively anonymous; one probing three
  household SSIDs scores ~59 and is close to uniquely identifiable. Keyed on the
  device rather than the MAC, so a rotation yields one complete list instead of
  three partial ones.
- **Run `./analysis-scripts/seqgraph.sh --validate` on any real capture before
  trusting the clustering.** Devices that do not randomize their MAC are ground
  truth needing no inference, so two of them in one cluster is a provable false
  merge and one split across clusters a provable false split. That gives a
  measured error rate at your current α/β, in your actual environment — use it
  to tune per site rather than guessing.

---

## Ingest: why the separator is `|`

`ingest_functions.sh` asks tshark for `-E separator='|'` and reads with
`IFS='|' read -r`. This is easy to "simplify" back into a serious bug:

- The original asked for a **space** separator and split with `arr=($line)`.
  Bash collapses runs of IFS **whitespace**, so any empty middle field — a probe
  with no RSSI, or no channel — shifted every later column one place left. The
  timestamp landed in `rssi`, the sequence number in `vht`.
- Switching to tshark's default **tab does not fix it**, because tab is also IFS
  whitespace. Verified: tshark emits the empty field correctly as two adjacent
  delimiters, and bash then discards it.
- `|` is not IFS whitespace, so adjacent delimiters yield genuine empty fields.
  `,` is unusable — tshark joins multiple occurrences of one field with it
  (multi-antenna RSSI arrives as `-42,-45`).

The same reasoning applies to reading multi-column `mysql -N` output, which is
tab separated. The burst passes, `mac2vendor` and `seqgraph_functions.sh` all use
`select concat_ws('|', …)` plus `IFS='|' read`. **Do not replace those with plain
array splitting.**

Rows written before this fix cannot be repaired — the discarded field is gone.
`./analysis-scripts/diagnose_legacy_rows.sh` reports whether a collection is affected;
re-importing the original captures is the only recovery.

## Query hygiene

- **Every query feeding a `while read` loop needs `mysql -N`.** Without it the
  column header comes back as the first row and gets processed as data.
- **Never set `IFS` globally.** These files are sourced into one shell, so a bare
  `IFS='|'` leaks into every function that runs afterwards. Scope it to the loop:
  `while IFS='|' read -r a b; do`.
- Enrichment passes are **incremental and idempotent**, driven by null columns
  (`where category is null`, `where rarity is null`). Keep new passes in that
  shape so they are cheap to re-run.

---

## Layout

Three modules, matching the three in `idea.txt`: **capture**, **analysis**,
**display**. Each has one entry point at the top level and its functions in a
directory beside it.

```
capture.sh            not yet written -- see "Still to do" below
analysis.sh           every enrichment pass in dependency order
display.sh            the operator view
build_dbs.sh          schema of record; used by all three

capture-scripts/      the parse-and-insert path, plus the Pi deployment glue
analysis-scripts/     enrichment passes and the libraries they share
display-scripts/      the operator view's queries
```

**Run everything from the repo root.** `lists/`, `locs/`, `logs/` and `.env`
resolve relative to the working directory, not to the script, so
`./analysis-scripts/categorize.sh` works and `cd analysis-scripts && ./categorize.sh`
does not.

Sourced libraries have no exec bit; anything runnable does.
`capture-scripts/pi/start_cap.sh` invokes `build_ssid.sh` by absolute path, so
that distinction is load-bearing.

### Pass naming

Every pass is runnable on its own *and* from `analysis.sh` — that dual use is
why `standalone_` was a redundant prefix and is gone. What the name carries now
is the two things worth knowing before running one:

| Prefix | Meaning |
|---|---|
| `online_` | **makes network calls.** Sends data to a third party, and in the Places case is billed per request. Never runs from `analysis.sh`. |
| `slow_` | takes long enough on a real collection to matter when you are standing in a room |
| neither | offline and quick |

`geolocate.sh` has no prefix deliberately: it reads the cached WiGLE responses
in `locs/` and makes no network call. `online_wigle_fetch.sh` is what fills that
cache.

### capture-scripts/

| File | Role |
|---|---|
| `ingest_functions.sh` | `PROBE_TSHARK_ARGS`, `ingest_stream` — the parse + insert loop |
| `build_ssid.sh` | Live capture off a monitor-mode interface |
| `pcap2db.sh` | Backfill the same rows from saved captures |
| `pi/` | Sensor deployment glue: `script.sh`, `start_cap.sh`, `start_ad.sh`. Hardcoded `/home/pi` paths, driven by cron and screen on the Pi, not called by anything here. |

### analysis-scripts/

Shared libraries:

| File | Role |
|---|---|
| `ssid_intel_functions.sh` | **The monolith.** `categorize`, `check_name`, `check_airport`, `check_common`, `check_fqdn`, `check_address`, `check_language`, `check_anomalies`, `make_ignore_list`. Still to be split — see below. |
| `location_functions.sh` | `wigle_fetch`, `summarize_one` — WiGLE fetch and jq summarization |
| `geolocate_functions.sh` | `geo_cache_index`, `geo_from_wigle_cache`, `derive_is_oneloc`, `geo_harvest_bssids`, `geo_reverse_addresses`, `geo_google_observer`, `geo_apple_bssid` |
| `places_functions.sh` | `places_resolve` — SSIDs naming a business, via Google Places |
| `fidelity_functions.sh` | `fidelity_completeness`, `fidelity_by_load`, `fidelity_channels` — how much of what was transmitted got captured. Read-only |
| `seqgraph_functions.sh` | `seqgraph_assign`, `assign_aliases` — device identity across MAC rotation |
| `bursts_functions.sh` | Burst grouping by MAC / sequence / VHT |
| `rarity_functions.sh` | `load_ssid_frequencies`, `score_rarity` |
| `vendor_functions.sh` | `mac2vendor` — OUI → vendor |
| `language_functions.sh` | `check_language_words` — language from vocabulary |
| `recategorize_functions.sh` | `recategorize_unknown`, `enumerate_cpe_region` |
| `industry_functions.sh` | `check_industry` — engagement-specific `INDUSTRY_*` lists |

Passes, in the order `analysis.sh` runs them: `ssid2ssid_intel`, `categorize`,
`recategorize`, `slow_language`, `name`, `airport`, `address`, `fqdn`,
`industry`, `mac2vendor`, `rarity`, `slow_summarize_loc`, `geolocate`, `oneloc`,
`seqgraph`.

Outside that batch: `common`, `make_ignore`, `bursts`, `ssid_intel`,
`fidelity`, `diagnose_legacy_rows`, and the four `online_*` passes
(`online_wigle_fetch`, `online_places`, `online_gps2city`,
`online_slow_wigle_grind`).

### display-scripts/

| File | Role |
|---|---|
| `display_functions.sh` | `rssi_range`, `device_profile_rows`, `display_inrange`, `display_ungrouped` |

### Still to do

- **`capture.sh` does not exist.** Capture is still started by calling
  `capture-scripts/build_ssid.sh` or `pcap2db.sh` directly. The other two
  modules have their entry point; this one does not yet.
- **`ssid_intel_functions.sh` is still monolithic.** Roughly a dozen unrelated
  enrichment passes in one file, which `idea.txt` asks to be split per concern.
  Its `categories` keyword table is also duplicated verbatim in
  `analysis-scripts/categorize.sh` — edit both or they drift. They have drifted
  before: one wrote `category='LOCATION'` while the other wrote
  `'LOCATION_VAGUE'`. Splitting the file is the natural moment to collapse that
  duplication.

## External services

- **WiGLE** — hard daily rate limits. Responses cache per SSID in
  `locs/<ssid_hex>.location`. A quota-exhausted body contains `"too many"`; the
  code detects that, deletes the poisoned cache file so the SSID can be retried,
  and stops. **Preserve that** — a lookup loop without it burns the daily quota
  in one run. A quota response is deliberately not written as a location, which
  is why a row can legitimately keep `location IS NULL`.
- Live enrichment runs **once per capture window**, not once per probe. Do not
  move a rate-limited HTTP call back into the ingest hot loop.
- **Nominatim** (`gps2city.sh`) — OSM policy is 1 request/second with an
  identifying User-Agent. The current loop does not rate limit; add a sleep
  before running it at scale.

## Known broken, unfixed

- `find_relatedbursts` in `bursts_functions.sh` — not wired up (its call in
  `build_bursts.sh` is commented out). `ssids=($(…))` splits a `time<TAB>ssids`
  result on `:` only, so `ssids[0]` holds the timestamp glued to the first SSID
  while the loop indexes from 1 as though that were correct. Also has unquoted
  `[ -n $ignore_check ]` tests and a `${ssids[$ssdi]}` typo.
- `check_name` matches names as substrings anywhere in an SSID, producing heavy
  false positives on short names.
- IE 3 empty-frame exclusion (see FINGERPRINTING.md) is not implemented.

Comments in these files that read like bug reports (`#bug here …`, `#borken`)
are often still accurate — but check against the test suite first, since several
are now stale.

## Geolocation providers are not interchangeable

`geolocate_functions.sh` opens with the full reasoning; the short version:

| Provider | Input | Answers | Status |
|---|---|---|---|
| **WiGLE** | SSID **or** BSSID | where that AP is | in use; `locs/` cache is read offline |
| **Google Geolocation** | a *set* of BSSIDs | where the **observer** is | needs `GOOGLE_GEOLOCATION_KEY`, ≥2 BSSIDs |
| **Google Places** | a venue **name** | where that venue is | needs `GOOGLE_PLACES_KEY`; billed per request |
| **Apple** | one BSSID | that AP's position | **no public API** — ships disabled |
| **Nominatim** | lat/lon | street address | free, 1 req/sec, needs a real User-Agent |

Two consequences that catch people out:

- **An undirected probe request contains no BSSID.** Only the SSID. So every
  BSSID-keyed service is unreachable from ordinary probe data — which is why
  ingest now captures `wlan.da`: a *directed* probe addresses the AP, and that
  is the sole route by which a BSSID enters this pipeline.
- **Google locates the observer, not the network.** Given the APs you can hear
  it answers "where am I". It cannot tell you where one SSID is. For per-AP
  position the options are WiGLE, or Apple's undocumented endpoint.

- **Google Places is an inference, not a sighting.** WiGLE reports that a radio
  with this SSID was heard at a coordinate. Places reports where a *venue* of
  that name is, which only becomes the device's location if the SSID really is
  that venue's network. `online_places.sh` therefore queries only SSIDs
  WiGLE could not place, requires the name to match exactly once router
  decoration is stripped, and writes `geo_source='google_places'` so the two can
  always be told apart. Filter on `geo_source` wherever only observations will
  do. It is billed per request and sends SSIDs to Google, so it is capped per
  run, cached in `places/`, and excluded from `analysis.sh`.

Apple is stubbed rather than implemented on purpose: there is no public API, the
endpoint returns position data on hundreds of unrelated third-party APs per
query (Rye & Levin, 2024), and enabling it is an engagement-owner decision.

**Enrichment is post-capture.** `geolocate.sh` with no arguments is
strictly offline — it reads the `locs/` cache and makes no network call, which
is what makes it safe to run anywhere. Network providers are opt-in flags. To
run the offline pass during capture, set `geo_online=1` in `.env`; it is off by
default because a rate-limited round trip in the ingest loop costs frames.
