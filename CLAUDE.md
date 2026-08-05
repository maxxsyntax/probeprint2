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

- **Never commit captured data.** `.env`, `locs/`, `lists/ignore.txt`,
  `lists/industry.txt` and `*.db` are gitignored for this reason. Do not add
  captured SSIDs to test fixtures, commit messages, or issue text.
- **Never send collected data to a third-party service** without explicit
  authorisation. WiGLE lookups send SSIDs to wigle.net; that is inherent to the
  tool, but it is still egress.

## Run everything from the repo root

Every script resolves `.env`, `lists/` and `locs/` relatively, so `cd` into
`probeprint2/` first.

```bash
# one-time; idempotent, and migrates an existing collection in place
./build_dbs.sh
mkdir -p locs                # WiGLE response cache, gitignored

# capture (interface must already be in monitor mode)
./build_ssid.sh

# backfill from saved captures instead
./pcap2db.sh capture1.pcap capture2.pcap

# enrichment: edit build_ssid_intel.sh to pick passes, or run them individually
./standalone_categorize.sh
./standalone_name.sh
./standalone_airport.sh
./standalone_rarity.sh
./standalone_summarize_loc.sh

# grouping
./build_bursts.sh            # SSID sets per burst
./standalone_seqgraph.sh     # devices, chained across MAC rotation

# live display
./display.sh
```

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
`./diagnose_legacy_rows.sh` reports whether a collection is affected;
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

Sourced libraries have no exec bit; anything runnable does. `start_cap.sh`
invokes `build_ssid.sh` by absolute path, so that distinction is load-bearing.

| File | Role |
|---|---|
| `ingest_functions.sh` | `PROBE_TSHARK_ARGS`, `ingest_stream` — the parse + insert loop |
| `location_functions.sh` | `wigle_fetch`, `summarize_one` — WiGLE fetch and jq summarisation |
| `vendor_functions.sh` | `mac2vendor` — OUI → vendor |
| `rarity_functions.sh` | `load_ssid_frequencies`, `score_rarity` — continuous SSID rarity |
| `seqgraph_functions.sh` | `seqgraph_assign` — device identity across MAC rotation |
| `bursts_functions.sh` | Burst grouping by MAC / sequence / VHT |
| `ssid_intel_functions.sh` | The remaining enrichment passes; sourced by `build_ssid_intel.sh` |
| `standalone_*.sh` | One concern each, runnable directly |
| `client/` | Distributed Pi capture nodes writing to a central database |

**Two generations still coexist** for the enrichment passes:
`ssid_intel_functions.sh` and the `standalone_*.sh` set. A fix to a pass usually
needs applying to **both**. The `categories` keyword tables in
`ssid_intel_functions.sh` and `standalone_categorize.sh` are duplicated verbatim
— edit both, or they drift. They have drifted before: one wrote
`category='LOCATION'` while the other wrote `'LOCATION_VAGUE'`.

`display_functions.sh` is still entirely sqlite3 and cannot work against the
MySQL schema. It is unreferenced; `display.sh` has its own inline version.

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
- `check_oneloc` greps `'lts": 1,'` — the tail of `"totalResults": 1,`. Works,
  but fragile.
- IE 3 empty-frame exclusion (see FINGERPRINTING.md) is not implemented.

Comments in these files that read like bug reports (`#bug here …`, `#borken`)
are often still accurate — but check against the test suite first, since several
are now stale.
