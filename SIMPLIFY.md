# Simplification plan

A plan, not a change. Nothing here has been applied.

The goal is to remove **duplication**, not capability. Every pass that adds
context stays, including the ones currently commented out of
`build_ssid_intel.sh` and the ones known to be broken — a disabled pass is a
pass waiting to be re-enabled, so the fix is to repair and single-source it, not
to delete it.

Line counts below describe this repository, never a collection.

---

## The target: the modular design in `idea.txt`

Simplification here means **converging on the architecture the engagement thesis
already specifies**, not inventing a new one. `idea.txt` fixes three modules and
two enrichment modes, and every decision below is in service of that shape:

```
  ┌── 1. CAPTURE ──────┐   ┌── 2. CORRELATE + ENRICH ──────┐   ┌── 3. HUD ──────┐
  │ ingest_functions   │   │  offline tier   │  online tier │   │ display.sh     │
  │ build_ssid.sh      │──▶│  (no network)   │  (needs net) │──▶│ display_       │
  │ client/build_ssid  │   │                 │              │   │  functions.sh  │
  │ pcap2db.sh         │   │  categorize     │  WiGLE geo   │   │                │
  └────────────────────┘   │  rarity         │  Nominatim   │   └────────────────┘
                           │  mac2vendor     │  (address)   │
                           │  language       │              │
                           │  recategorize   │              │
                           │  seqgraph/bursts│              │
                           └─────────────────┴──────────────┘
```

Two properties of that design constrain every phase:

- **Enrichment is offline-first, with a bolt-on online tier.** The offline passes
  make no network call; the online passes (WiGLE, Nominatim) run only when there
  is connectivity. `process.sh` is already exactly the offline batch — it states
  "no network call" — and `summarize_location.sh --new` is already the separate
  online path. The plan preserves that seam; it does not merge the two.
- **Every enrichment pass must run *both* standalone and in a batch.** This is a
  stated requirement, so the `standalone_*.sh` scripts are **not** the duplication
  to remove. The duplication is that each pass is *defined* twice; the fix is one
  definition with the standalone script kept as a thin wrapper around it. One
  definition, both invocation modes, module boundaries intact.

So throughout this document, "single-source" means **collapse duplicate
definitions, preserve both entry points**. Nothing here erases a module boundary,
the offline/online split, or a pass's ability to run on its own.

### Explicitly out of scope

- **Bluetooth → Wi-Fi correlation is roadmap, TBD.** `idea.txt` wants
  Blue2thprinting data folded into module 2, correlated on signal-strength
  co-presence and small MAC↔BDADDR deltas. No code for it exists in this tree,
  so it is a *build*, not a *simplification* — tracked in the workspace
  `../CLAUDE.md` and `FINGERPRINTING.md`, and left untouched here.
- **New capabilities generally.** The WPS-UUID reversal and other items in
  `FINGERPRINTING.md`'s "not implemented" list are additions, not cleanups.

---

## The one structural problem

Each enrichment pass exists **twice**: once in `ssid_intel_functions.sh` (490
lines, 15 passes) and once in a `standalone_*.sh` script. `process.sh` runs only
the standalone copies. `ssid_intel_functions.sh` is sourced only by
`build_ssid_intel.sh`, where every call but `mac2vendor` is commented out.

That is the source of the "edit both or they drift" rule, and the drift is not
hypothetical — `check_common` now exists in four copies with **three different
`where` clauses**, so the copy the tests exercise is not the copy `process.sh`
runs.

The newer passes already solved this, and they are the model the modular design
wants: `standalone_rarity.sh`, `_geolocate`, `_seqgraph`, `_language`,
`_recategorize`, `_mac2vendor`, `_oneloc` and `_summarize_loc` all *source* a
library rather than redefining it — one definition, invokable standalone or from
`process.sh`'s batch. The plan is to finish that conversion for the older passes.

**Nothing is lost by this.** A single definition still runs from the capture
loop, from `process.sh`'s batch, from its standalone script, or by hand — which
is exactly the "standalone or batch" requirement `idea.txt` sets for module 2.

---

## Phase 0 — verify before touching anything

Three claims come from reading the code, not from the data. Run these first;
they decide whether the corresponding column is empty or in use.

```sql
-- Do these two columns hold the same value for every device?
select count(*) from devices where ssid_count <> pnl_size;

-- Has anything ever populated score?
select count(*) from ssid_intel where score is not null;

-- Has find_relatedbursts ever run to completion?
select count(*) from bursts where related_burst <> 0;
```

A non-zero answer for `score` or `related_burst` means a pass that is disabled
today used to run, and its output is still in the collection. That changes the
decision from "remove" to "keep and re-enable".

---

## Phase 1 — fix the WiGLE quota path (highest value, and currently broken)

This is module 2's **online tier**. The offline batch (`process.sh`) is healthy;
the online path that feeds it coordinates is the part that is broken, so it is
where the modular design is least realized today.

`ssid2loc_every24.sh` is the daily-quota workaround. **As written it cannot
work**, for two independent reasons:

1. It does `source ./summarize_location.sh`, and that file opens with
   `if [ $# -eq 0 ]; then echo usage; exit 1; fi`. A sourced file sees the
   *caller's* positional parameters, so when `ssid2loc_every24.sh` is run with
   no arguments the guard fires and `exit 1` terminates the whole script —
   before the loop over SSIDs is ever reached. Verified with a minimal repro:
   the caller prints the usage line and exits 1.
2. It calls `ssid2loc`, which `summarize_location.sh` does not define.
   `ssid2loc` lives in `ssid_intel_online_functions.sh` and in
   `ssid2loc_wigle.sh`, neither of which is sourced. So even past the guard it
   would fail per iteration with "command not found".

### Three quota policies exist, and all three are wanted

This is the part not to collapse carelessly. The three WiGLE fetch
implementations differ precisely in **what they do when the quota is gone**:

| Implementation | On quota exhaustion |
|---|---|
| `location_functions.sh` → `wigle_fetch` | Deletes the one poisoned cache file so that SSID can be retried, then stops the run |
| `ssid_intel_online_functions.sh` → `ssid2loc` | Deletes *every* poisoned cache file, sleeps 600s, continues — this is the "wait out the limit" behavior the every24 script wants |
| `ssid2loc_wigle.sh` → `ssid2loc` | Exits immediately |

Proposal: **one** fetch function with an explicit policy argument —
`--on-quota=stop` (today's default, and what the tests assert),
`--on-quota=wait` (the every24 behavior), `--on-quota=exit`. All three
behaviors survive; three copies of the curl and the `"too many"` detection
become one.

Then `ssid2loc_every24.sh` becomes a few lines that call the shared fetch with
`--on-quota=wait`, and the sourcing bug disappears with the source line.

Also fix while here: `ssid2loc_wigle.sh`'s cleanup runs
`grep pattern <single-file> | cut -d: -f1`, but grep omits the filename prefix
when given one file, so `cut` yields the matched *line* and `rm` is handed
garbage. `ssid_intel_online_functions.sh` greps `locs/*` and gets this right.

`remove_empty_locs` in `ssid_intel_functions.sh` is the bulk retroactive version
of the same cleanup and is unique — keep it, and point it at the shared helper.

---

## Phase 2 — single-source the duplicated passes

This is module 2's **offline tier**. Behavior-preserving. Roughly 1,000
duplicated lines collapse to one definition each plus ~10-line wrappers. The
standalone scripts stay — they are the "run standalone" half of the requirement;
only the second *definition* of each pass goes.

| Pass | Copies | Canonical | Note |
|---|---|---|---|
| `check_common` | 4 | one definition, invoked via `standalone_categorize.sh` | Decided (#1 + 5a). See filter below |
| `check_language` | 2 | either — byte-identical | `standalone_check_language.sh` is referenced by nothing |
| `categorize` + its 23-line `categories` table | 2 | either — byte-identical | Single-source before they drift again |
| `check_anomalies` | 2 | either | |
| `check_airport` | 2 | either | |
| `check_name` | 2 | either | Substring false-positive bug is separate, and stays on the list |
| `check_fqdn` | 2 | either | |
| `check_address` | 2 | either | |
| `make_ignore_list` | 2 | either | |
| `ssid2ssid_intel` | 2 | either | |
| `summarize_location` (gen 1) vs `summarize_one` | 2 | `summarize_one` | It is the tested one (case 05). **Check first** that the `location=0` sentinel gen 1 writes for a null result is preserved |
| `check_oneloc` | 1 + delegate | `derive_is_oneloc` | Already a one-line delegate; fold it away |
| `gps2city` | 2 | `gps2city.sh` | Second copy is inside `ssid2loc_wigle.sh` |
| `listen` / `tshark2db` | 2 | leave as-is | `client/` already shares `ingest_stream`; the rest is genuinely multi-interface |

### The `check_common` filter (decided)

The four copies filter differently:

| Copy | Excludes |
|---|---|
| `standalone_common.sh` | `00%` |
| `standalone_check_common.sh` | `1%`, `2%`, `8%`, `%00%`, `%00` |
| `standalone_categorize.sh` | `1%`, `2%`, `8%` |
| `ssid_intel_functions.sh` | `1%`, `2%`, `8%` |

Two decisions pin this down. **#1**: `check_common` is invoked via
`standalone_categorize.sh`, which is the single entry point. **5a**: SSIDs whose
hex contains an embedded `00` must **not** be processed by `check_common` — an
embedded null byte marks a frame that is not a real network name.

So the single definition keeps the invocation path of `standalone_categorize.sh`
but the **`where` clause of `standalone_check_common.sh`** — the only one of the
four that excludes both `%00%` and a trailing `%00`. The `standalone_categorize.sh`
and `ssid_intel_functions.sh` filters are too loose (they let embedded `00`
through) and `standalone_common.sh` is both too loose and too narrow.

Consequence for the tests: **none**. The suite already invokes
`standalone_check_common.sh`, i.e. the strict filter, so cases 04 and 08 keep
their current expectations. Only the redundant definitions go away.

`build_ssid_intel.sh` keeps its role as the capture-time entry point. Its
commented-out call list is a menu, not dead weight; leave the menu and let it
source the single definitions.

---

## Phase 3 — repair, don't remove

### `find_relatedbursts`

Correlating bursts to each other by shared SSIDs is unique context that nothing
else provides, so this is a repair job. Known faults:

- `ssids=($(…))` splits a `time<TAB>ssids` result on `:` only, so `ssids[0]`
  holds the timestamp glued to the first SSID while the loop indexes from 1.
  Fix with the `concat_ws('|', …)` + `IFS='|' read` pattern used everywhere else.
- Unquoted `[ -n $ignore_check ]` tests.
- `${ssids[$ssdi]}` typo.

Its "skip uninteresting SSIDs" gate currently reads
`is_common=1 or is_airport is not null`. Per the decision to prefer rarity, that
becomes a `rarity` threshold — which is also the natural place to prove rarity
subsumes the flag.

### `is_common` → `rarity`

`rarity_functions.sh` says "is_common is left in place; nothing that reads it
needs to change." Once `find_relatedbursts` reads rarity instead, the only
remaining readers are tests. Sequence:

1. Convert `find_relatedbursts`' gate to a rarity threshold.
2. Retire the `check_common` pass (one definition to remove, not four).
3. Keep the `is_common` column per phase 5, and keep case 08's assertion that
   rarity separates SSIDs `is_common` cannot — that assertion is the
   justification for the whole pass and should outlive the flag.

### `score()` / `bump_score()`

Delete, as decided, along with the `score` column's writers. ~140 lines.
Whether the column itself goes is phase 5.

### `check_name` substring false positives (decided: fold in)

`check_name`'s names-list loop matches each name as a **substring anywhere** in
the SSID:

```sql
where ssid_hex like "$name_hex%" or ssid_hex like "%$name_hex%" or ssid_hex like "%$name_hex"
```

So a short name like `Al` (hex `416c`) tags `Portal`, `Alarm`, `Balcony` — and
worse, the decoded fragment is written into `is_name` and the row is set
`category='NAME'`, inventing a person. This is the `FINGERPRINTING.md`
known-broken entry.

Fix: **whole-token matching**, the same rule `language_functions.sh` already
uses for its markers. A name matches only when it is bounded by a string edge or
a separator byte (space `20`, `-` `2d`, `_` `5f`, `.` `2e`). Cleanest done on the
decoded token stream rather than with `like` on hex, so `check_name` decodes the
SSID once, splits on separators, and compares whole tokens against the name set.

Two robustness bugs to fix in the same pass, since they share a root cause:

- **`is_name` is `varchar(20)`** and the decoded name is written by
  string-interpolated SQL. A name over 20 chars silently truncates; a name
  containing a quote breaks the statement. Pass it as a parameter (the
  `jq --arg` / prepared-statement discipline used elsewhere), and match the
  column width to the longest real name or widen it.
- **The `is_name != ''` comparison** raises `ERROR 1292 Truncated incorrect
  DECIMAL value` (noted against `check_name` in `build_ssid_intel.sh`): MariaDB
  coerces both sides to a number. Compare as text, or gate on
  `is_name is not null and is_name <> ''` with the column's collation.

A minimum-token-length guard (skip 1–2 character names) is worth adding while
here — those are the substring matches that produced the most noise.

---

## Phase 4 — wire up the display subcommands

This is module 3, the HUD. `idea.txt` wants it to show qualitative proximity, a
fingerprint-derived friendly name, and that fingerprint's traits — which
`display_inrange` already does. But three finished, tested views onto the same
data are unreachable: `display_recent`, `display_devices` and `display_device`
are called only from the test suite. Expose them:

```
./display.sh                    # live in-range view (unchanged default)
./display.sh recent [seconds]
./display.sh devices            # roster
./display.sh device <alias|id>  # one device's profile
```

No new logic — an argument parser over functions that already exist.

---

## Phase 5 — schema

`build_dbs.sh` only ever *adds* columns (`add column if not exists`), which is
what lets a fresh install and a live collection converge. There is deliberately
no mechanism for removing one. So for every column below there are two distinct
choices:

- **(a) Code only.** Stop writing the column; leave it in the database. Zero
  risk, costs nothing but an unused column.
- **(b) Also drop it.** Add `alter table … drop column if exists …` to
  `build_dbs.sh`. This permanently deletes that data from **every** collection
  the next time anyone runs the script, including the live one. Irreversible
  without a restore from `db_backup.sh`.

**Decided: option (a) everywhere — code changes only, no column drops.** Stop
writing the retired columns; leave every column in place. `build_dbs.sh` gains no
`drop column`. An unused column costs nothing, and nothing in a live collection
is ever at risk from this work. Phase 0's queries are still worth running for
understanding, but no longer gate a deletion — there are none.

| Column | Verdict |
|---|---|
| `devices.ssid_count` vs `pnl_size` | Same quantity by construction — one counts `device_ssid` rows, the other `count(distinct ssid_hex)` over the frames `device_ssid` is built from. If phase 0 confirms, keep `pnl_size` (the documented deliverable metric) and update the two reads in `display_functions.sh` |
| `ssid_intel.score` | Stop writing it (delete `score()`/`bump_score()`). Column stays, unused, per (a) |
| `bursts.related_burst` | **Keep** — `find_relatedbursts` is being repaired, not removed |
| `bursts.burst_duration` | **Keep** — burst duration is wanted signal, and inter-burst timing is on the roadmap in FINGERPRINTING.md |
| `ssid_intel.is_common` | Retire the writer; keep the column under (a) so case 08's rarity-beats-the-flag comparison still has something to compare against |
| `ssid.tag` | Write-only capture provenance, and worth having. Add the missing *reader* — a `display.sh` filter or `diagnose_legacy_rows.sh` output — rather than dropping it |
| `ssid_intel.geo_accuracy` | Written by the `bssid_geo` join, never read. Surface it next to `lat`/`lon` in the device profile rather than dropping it |
| `ssid_intel.ssid_total` | Denormalized copy of `ssid_freq.total`, an intentional cache. Leave alone |
| `ssid_intel.is_oneloc` | A pure function of `geo_match_count`. Could become a generated column like `ie_fp`, removing a pass. Low value, listed for completeness |
| `devices.vendor` vs `ssid.vendor` | Not redundant — a legitimate rollup |
| `location` vs `lat`/`lon`/`street_address` | Not redundant — three precisions, and `display.sh` deliberately falls back through them |

---

## Phase 6 — directory and file hygiene

The tree is flat: ~50 scripts in the repo root. Two ways to "fix up" that, and
they are very different in risk. **Decided: the light-touch approach below; no
subdirectory reorg.**

### Decided: lean on the naming convention, not on subdirectories

The module a file belongs to is **already encoded in its name** —
`build_*` and `ingest_*` (capture), `standalone_*` and `*_functions.sh`
(enrich), `display_*` (HUD) — which is the idiomatic structure for a flat bash
project where everything is sourced by `source ./name.sh` from a single working
directory. Keep that. There is little genuinely misplaced:

- **`probeprint.cap`** is **not** a packet capture despite the extension — it is
  a **bettercap caplet** (its header says so, and to install it under
  `/usr/share/bettercap/caplets/`). It enables `wifi.recon` + `ble.recon` and is
  live capture tooling, so it belongs to module 1 and **stays put**. Do not move
  it to `test/fixtures/` (it is not a fixture) and do not delete it as a stray
  capture. Worth noting it drives *both* Wi-Fi and BLE recon, so it is also
  relevant to the future BT↔Wi-Fi work.
- **`test/out/`** is developer scratch (`dbg_geo.sh`, `pii_inventory.sh`,
  `sweep.sh`, …) and is **already gitignored**, so it is not in the committed
  tree. No action needed, and nothing there should be promoted without review —
  `pii_inventory.sh` in particular touches real data.
- So the light touch is really: **do nothing to the layout**; the file deletions
  in phases 1–3 are the whole of the cleanup, and the naming convention already
  carries the module structure.

### Not recommended: a deep `capture/ enrich/ display/` subdirectory reorg

Tempting given the three-module design, but it fights the codebase:

- Every `source ./x.sh` is relative to the working directory, and the project
  contract (both `CLAUDE.md`s) is **run everything from the repo root**. Nesting
  breaks every source line, every `./standalone_*.sh` call in `process.sh`, and
  every invocation in the test cases.
- `start_cap.sh` invokes `build_ssid.sh` by absolute path; the test harness
  copies the repo and `cd`s to its root; `client/` resolves `../ingest_functions.sh`.
- It is the user's own signed-commit repo with a live upstream, so a
  move-everything diff is high-churn and hard to review — for zero reduction in
  duplication, which is the actual goal. Directory nesting is cosmetic here.

If a reorg is still wanted, it is a separate, deliberate commit of its own, done
after 1–5 land, and it must rewrite the sourcing to resolve paths from
`$BASH_SOURCE` rather than the CWD first — otherwise it breaks the "run from
root" contract.

---

## Net effect: what gets removed

**Scripts deleted: 4** (all their unique behavior preserved elsewhere first):

| Script | Why | Phase |
|---|---|---|
| `ssid2loc_wigle.sh` | `ssid2loc` + `gps2city` folded into the unified WiGLE fetch | 1 |
| `ssid_intel_online_functions.sh` | its "wait out the quota" `ssid2loc` becomes `--on-quota=wait` | 1 |
| `standalone_common.sh` | redundant 4th copy of `check_common` | 2 |
| `standalone_check_language.sh` | redundant; byte-range `check_language` still runs via `standalone_categorize.sh` | 2 |

**One more, safe to delete:** `build_ssid_intel.sh` — no script invokes it, and
its only live call (`mac2vendor`) plus the `ssid → ssid_intel` population both
run under `process.sh`. Population is **not** automatic at capture time: ingest
writes only the `ssid` table, and `ssid2ssid_intel` (`insert ignore … select
distinct ssid_hex from ssid`, run first by `process.sh`) is what fills
`ssid_intel`. So nothing is lost by removing it → **5 scripts**. Keep it only if
you want the commented call-menu as documentation.

Plus, *without removing files*: ~1,000 duplicated lines collapse to single
definitions (phase 2); `score()`/`bump_score()` go, `find_relatedbursts` and
`check_name` are repaired (phase 3). No `lists/` data, no database columns, and
no capture tooling (`probeprint.cap` is a bettercap caplet) are removed. The
directory layout is left as-is (phase 6).

---

## Not deletion candidates after all

Checked and cleared — recorded so nobody re-proposes them:

- **`lists/male.txt`, `female.txt`, `names_toobig.txt`, `names.txt`.** Not
  derived from each other: 134 of `names.txt`'s entries appear in neither
  `male.txt` nor `female.txt`. Four distinct corpora at four size/precision
  tradeoffs.
- **`lists/airports.txt`, `airports2.txt`, `all_airports.txt`.** `airports.txt`
  shares *no* entries with either of the others — different formats and scopes,
  not versions of one list.
- **`lists/oui.txt` vs `oui.csv`.** Different upstream formats (fixed-width IEEE
  text vs CSV), not duplicates.

All of these fall under the workspace rule that third-party reference data under
`lists/` is verbatim external corpora. If any are archival rather than live,
record that in `lists/sources.txt` instead of removing them.

- **`db_backup.sh`.** One line, unreferenced, and the only recovery path if
  phase 5 option (b) is ever chosen. Keep.
- **`ssid2loc_every24.sh`.** Unreferenced and currently broken, but it is the
  quota workaround the engagement wants. Repaired in phase 1, not deleted.

Note the sequencing trap for `ssid_intel_online_functions.sh`: it *looks*
unused, but it holds the only correct "wait out the quota" logic. It is safe to
delete **only after** phase 1 has extracted that into the unified fetch — do not
remove it as "unreferenced" beforehand.

---

## Sequencing

| | Phase | Behavior change? |
|---|---|---|
| 1 | WiGLE quota path repair | Yes — makes a broken script work |
| 2 | Single-source duplicated passes | Yes, for `check_common` only |
| 3 | Repair `find_relatedbursts`; `is_common` → rarity; delete `score`; fix `check_name` | Yes |
| 4 | Display subcommands | No — additive |
| 5 | Schema | Depends on (a) vs (b) |
| 6 | Directory/file hygiene | No — relocations only |

Land these as separate commits, and keep phase 5 apart from the rest since it is
the only one that can touch stored data.

Run before and after each phase:

```sh
docker build -f test/Dockerfile -t probeprint2-test .
docker run --rm probeprint2-test
./standalone_seqgraph.sh --validate    # on a real capture, for phases 3 and 5
```

Two cautions. Rebuilding the test image also replaces the image
`../wifi_research/import_caps.sh` runs, so do not rebuild during an import. And
`--validate` gives a measured false merge/split rate from static-MAC ground
truth — take a reading before phase 5 so any change in the clustering path is
attributable.
