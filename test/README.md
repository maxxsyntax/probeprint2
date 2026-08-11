# probeprint2 test suite

A Docker-based regression suite. The container runs its own MariaDB and has
`tshark` installed, so the SQL and the packet-parsing paths are exercised for
real rather than mocked.

## Running

```sh
cd probeprint2
docker build -f test/Dockerfile -t probeprint2-test .
docker run --rm probeprint2-test              # full suite, non-zero exit on failure
docker run --rm probeprint2-test test/run_tests.sh ingest   # only matching cases
docker run --rm -it probeprint2-test bash     # interactive, DB already up
```

If the daemon is not running: `sudo systemctl start docker`.

## What each case covers

| Case | Covers |
|---|---|
| `01_ingest` | Field alignment through `ingest_functions.sh`, including empty mid-row fields, the `<MISSING>` sentinel, awkward SSID bytes, and duplicate timestamps |
| `02_bursts` | All three burst-grouping methods (`wlan_sa`, `seq`, `vht`), `is_uniq`, numeric RSSI comparison |
| `03_schema` | `build_dbs.sh` runs clean and idempotently, creates all tables, the `score` column and the `pi` user |
| `04_enrichment` | `categorize`, `check_language`, `check_fqdn`, `check_airport`, `check_name`, `check_common`, `mac2vendor`, `make_ignore_list`, and that no pass treats the SQL header as data |
| `05_location` | WiGLE summarization against canned API bodies: single city, multi-city, multi-country, zero results, quota exhaustion, uncached, jq quoting |
| `06_ifs_order` | Enrichment results are independent of pass order, proving `IFS` no longer leaks between functions |
| `07_legacy_diagnostic` | `diagnose_legacy_rows.sh` detects shifted rows and writes nothing |
| `08_rarity` | Continuous SSID rarity: corpus load, comma-bearing SSIDs, unseen = max rarity, and that rarity separates SSIDs `is_common` cannot |
| `09_seqgraph` | Device identity across MAC rotation, 12-bit counter wrap, stable ids across incremental runs, alias determinism, confidence from IE consistency |
| `10_display` | Display layer queries MariaDB not sqlite, and surfaces alias + confidence + rarity |
| `11_pnl_validate` | The preferred network list attached to each device, `pnl_rarity`, and the static-MAC accuracy harness detecting a real false merge and split |
| `12_geolocate` | Coordinates extracted from the WiGLE cache offline, multi-location SSIDs correctly refused, BSSID harvesting from directed probes, and both network providers refusing to guess |
| `13_recategorize` | Second-pass categorization of OTHER_UNKNOWN: operator brands, router name shapes, workplace and residence markers, and vendors never implying a location |
| `14_language` | Language from vocabulary for Latin-script SSIDs: single-language vs family scope, whole-token matching, conflicting markers refused |
| `15_inrange` | The in-range operator display: one profile per device assembled from its PNL, low-confidence merges flagged before the profile, char(31) separator safe against pipes in SSIDs |
| `16_oneloc` | `is_oneloc` derived from `geo_match_count` rather than WiGLE's case-insensitive `totalResults`, wrong in both directions; refusal when geolocation has not run; unscored rows undetermined rather than false |
| `17_places` | Google Places name lookup: exact match after normalizing router decoration, near-miss names refused, chain names left unplaced, SSIDs WiGLE already placed never queried, refusal without a key, `--dry-run` sends nothing |
| `18_fidelity` | Capture completeness from sequence numbers: known-hole fixtures, 12-bit counter wrap, retransmissions excluded, idle gaps and delta-too-large reported separately, channel-coverage warning, and that the pass writes nothing |
| `19_capture` | The capture entry point: pcap backfill through the same ingest as live capture, `--pcap-dir`, status telling quiet apart from not-running, preflight refusing an unset or missing interface, and that neither `--check` nor `--status` writes |
| `20_cracked` | SSIDs whose WPA key is publicly known (`lists/cracked.txt`): flagged, case-sensitively, separators in the name handled, incremental leaves decided rows alone, `--recompute` corrects, and rare cracked networks surface as soft targets while common ones do not |
| `21_wigle_csv` | Offline location lookup from local WiGLE exports (`WigleWifi_*.csv[.gz]`): definitive/clustered/dispersed outcomes, exact-byte (case-sensitive) SSID join, a comma inside an SSID parsed right-anchored, gzipped CRLF files read, directed-probe BSSIDs located, and an API `wigle` fix never overwritten |

## Rules

**No network calls.** `test/fixtures/locs/` pre-populates the WiGLE cache so
`wigle_fetch`'s existence check short-circuits before `curl`. The container's
`.env` sets `online=0` and a dummy `APIKEY`. The WiGLE daily quota is not a test
resource — keep it that way when adding cases.

**The repo is copied, not mounted.** A test run cannot write back into the
working tree.

**Each case reseeds.** Call `reset_db` from `lib.sh` at the top of a case; cases
run in separate bash processes so a leaked `IFS` or `cd` cannot bleed across.

## Adding a case

Create `test/cases/NN_name.sh`:

```sh
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"
reset_db

assert_eq "what it should do" "expected" "$(sq1 "select ...;")"

finish
```

Helpers in `lib.sh`: `assert_eq`, `assert_contains`, `assert_not_contains`,
`sq` (headerless query), `sq1` (scalar), `hexof` (string to `ssid_hex`),
`reset_db`, `finish`.

## Fixtures

- `fixtures/make_pcap.py` — scapy generator for the synthetic 802.11 pcap. Every
  frame must carry a radiotap header: a pcap has one link-layer type, so a bare
  `Dot11` frame mixed into a RadioTap file is misparsed and vanishes from
  `-T fields` output.
- `fixtures/seed.sql` — deterministic `ssid` rows, written as `lower(hex('...'))`
  so intent stays readable.
- `fixtures/locs/*.location` — canned WiGLE responses, named `<ssid_hex>.location`.
