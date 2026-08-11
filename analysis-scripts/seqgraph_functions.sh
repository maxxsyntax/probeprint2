#!/bin/bash
# Device identity from 802.11 sequence numbers.
#
# Implements the graph linkage from Soundararaj, Cheshire & Longley, "Estimating
# Real-Time Highstreet Footfall from Wi-Fi Probe Requests" (UCL, 2019).
#
# The 12-bit sequence counter in the MAC header increments per frame and is not
# reset when a device rotates its randomized MAC address. So a chain of probe
# requests with steadily increasing sequence numbers, close together in time, is
# one device -- even when every frame in the chain carries a different source
# address. That is the property this pass exploits.
#
# Graph construction, per the paper:
#
#   - nodes are probe requests
#   - an edge may only go forward in time
#   - an edge may only go from a lower to a higher sequence number
#   - an edge may span at most SEQGRAPH_ALPHA seconds
#   - an edge may span at most SEQGRAPH_BETA sequence numbers
#   - each node keeps at most one incoming and one outgoing edge: the shortest
#     available in both time and sequence number
#
# Connected components are devices, recorded in the `devices` table.
#
# --- Identity ---------------------------------------------------------------
#
# devices.id is an autoincrement surrogate key: never reused, never renumbered,
# and the only thing anything else should join on.
#
# devices.device_key is the natural key, derived from the component's *earliest*
# observation as substr(md5(anchor_time), 1, 16). This is merge-stable: when two
# components join, the merged component's earliest frame is whichever component
# started first, so that component's key survives and the other is absorbed. No
# renumbering, and two analysts recomputing independently agree.
#
# Nodes are processed in time order and union() always attaches the later root
# to the earlier one, so a component's union-find root is by construction its
# earliest member. That is what makes the anchor cheap to find.
#
# This replaces an earlier scheme that used the per-run array index
# (dev-%06d). That was not stable: incremental runs restarted the index at zero
# and reissued ids already in use, so two unrelated devices could share one.
#
# --- Relationship to the burst pipeline -------------------------------------
#
# ssid2bursts-seq is deliberately left in place. The burst pipeline's
# is_processed state machine feeds the VHT pass, and burst rows remain the right
# structure for assembling per-device preferred network lists. The two answer
# different questions: bursts group SSIDs, this groups frames into devices.

# Maximum gap, in seconds, one edge may bridge. Cunche et al. measured 50-60s
# between successive bursts from the same device, so the default spans a little
# more than one inter-burst gap. Raising it chains more aggressively, at the
# cost of merging distinct devices.
SEQGRAPH_ALPHA=${SEQGRAPH_ALPHA:-90}

# Maximum sequence advance one edge may bridge. An unassociated device burns
# sequence numbers only on probes; an associated one also burns them on data
# frames, so this has to be generous. Too large and two devices merge.
SEQGRAPH_BETA=${SEQGRAPH_BETA:-400}

# The counter is 12 bits.
SEQ_MODULUS=4096

# Refuse an edge between two frames whose IE fingerprints disagree. One physical
# device cannot change its IE signature mid-capture, so a disagreement is proof
# the two frames came from different devices -- which turns the confidence check
# from something that reports bad merges after the fact into something that
# prevents them. Frames with no IE data are never blocked, only ones that
# positively disagree. Set to 0 to reproduce the ungated behavior.
SEQGRAPH_GATE_IE=${SEQGRAPH_GATE_IE:-1}

# seqgraph_assign [--recompute]
seqgraph_assign () {
	local recompute=0
	[ "${1:-}" = "--recompute" ] && recompute=1

	echo "seqgraph_assign start $(date +"%H:%M:%S.%3N") (alpha=${SEQGRAPH_ALPHA}s beta=${SEQGRAPH_BETA}$([ "$recompute" = 1 ] && echo ' recompute'))"

	# --- INCREMENTAL vs RECOMPUTE ------------------------------------------
	# Recompute regroups every frame from scratch: correct, but on a large
	# collection it rebuilds the whole graph each run and (before READ COMMITTED)
	# froze concurrent capture. Incremental groups only the new (device_id null)
	# frames, and is the default a live node runs every sweep.
	#
	# Grouping new frames in isolation would be WRONG -- a returning device would
	# be minted as a brand-new one each sweep (fragmentation). A new frame links
	# to an existing device two ways, handled separately by their reach:
	#
	#   1. Unbounded -- a static (non-randomized) MAC or a WPS UUID-E identifies a
	#      device no matter how long ago it was last seen. Assigned directly in
	#      SQL below, before the graph.
	#   2. Bounded -- time/sequence continuity reaches back only ALPHA seconds, so
	#      the graph runs over the new frames plus a tail of already-grouped
	#      frames from the last ALPHA seconds, each carrying its device_key. A
	#      component anchored on a tail frame inherits that device's key, so the
	#      new frames merge into the existing device rather than starting a new one.
	#
	# Incremental is a good approximation, not identical to recompute: a new frame
	# that bridges two long-established devices merges only into the earlier one.
	# Run --recompute periodically for a fully consistent regroup.
	if [ "$recompute" != 1 ]; then
		# Snapshot the frames this run must assign (everything still ungrouped).
		# Nothing to do if there are none -- return before the expensive rebuild,
		# which is what makes an idle sweep on a live node near-instant.
		mysql probeprint <<'SQL'
truncate table seqgraph_newframes;
insert into seqgraph_newframes (time)
  select time from ssid where device_id is null and seq is not null and time <> '';
SQL
		if [ "$(mysql -N probeprint <<< 'select count(*) from seqgraph_newframes;')" = "0" ]; then
			echo "  no new frames to group"
			echo "seqgraph_assign stop $(date +"%H:%M:%S.%3N")"
			return
		fi

		# 1. Unbounded links, in SQL. is_random second-hex-digit set {2,6,a,e}
		#    (locally-administered, unicast) mirrors the awk is_random(); anything
		#    else is a burned-in MAC that identifies the device outright.
		# The MAC/uuid -> existing-device maps are built only over the identifiers
		# the NEW frames actually carry (the `... in (select ... from
		# seqgraph_newframes)` restriction), not the whole table. Without that
		# restriction each sweep GROUP BYs all 735k rows -- ~3 minutes on a merged
		# collection even to place one frame.
		mysql probeprint <<'SQL'
set session transaction isolation level read committed;
update ssid s
  join (select wlan_sa, min(device_id) did from ssid
         where device_id is not null
           and lower(substr(wlan_sa,2,1)) not in ('2','6','a','e')
           and wlan_sa in (select nf.wlan_sa from ssid nf
                             join seqgraph_newframes n on n.time = nf.time)
         group by wlan_sa) m on m.wlan_sa = s.wlan_sa
  join seqgraph_newframes n2 on n2.time = s.time
   set s.device_id = m.did
 where s.device_id is null
   and lower(substr(s.wlan_sa,2,1)) not in ('2','6','a','e');

update ssid s
  join (select wps_uuid, min(device_id) did from ssid
         where device_id is not null and wps_uuid is not null and wps_uuid <> ''
           and wps_uuid in (select nf.wps_uuid from ssid nf
                              join seqgraph_newframes n on n.time = nf.time
                             where nf.wps_uuid is not null and nf.wps_uuid <> '')
         group by wps_uuid) w on w.wps_uuid = s.wps_uuid
  join seqgraph_newframes n2 on n2.time = s.time
   set s.device_id = w.did
 where s.device_id is null and s.wps_uuid is not null and s.wps_uuid <> '';
SQL
	fi

	# Ordered by time: the linking pass is a forward sweep, which lets it stop
	# scanning candidates as soon as the time threshold is exceeded.
	#
	# concat_ws for the usual reason -- mysql -N is tab separated and bash
	# collapses runs of tab as IFS whitespace, so an empty column would shift
	# the rest. The timestamp is carried through as the original *string*: it is
	# a varchar primary key, so reformatting it as a float would produce an
	# UPDATE that matches nothing.
	#
	# The sixth column is the existing device_key for a grouped tail frame, empty
	# for a frame to be (re)assigned. Under recompute it is always empty (every
	# frame regroups from scratch); incremental carries it so new frames inherit
	# a recent device's key.
	local sql
	if [ "$recompute" = 1 ]; then
		sql="select concat_ws('|', time, seq, ifnull(case when ie_order is null then '' else ie_fp end,''), ifnull(wlan_sa,''), ifnull(wps_uuid,''), '')
		       from ssid
		      where seq is not null and time is not null and time != ''
		      order by cast(time as decimal(20,7));"
	else
		# New frames, plus grouped frames within ALPHA of the earliest new one
		# (the reach of a time/sequence edge). Tail frames carry their device_key.
		sql="select concat_ws('|', s.time, s.seq, ifnull(case when s.ie_order is null then '' else s.ie_fp end,''), ifnull(s.wlan_sa,''), ifnull(s.wps_uuid,''), ifnull(d.device_key,''))
		       from ssid s
		       left join devices d on d.id = s.device_id
		      where s.seq is not null and s.time is not null and s.time != ''
		        and ( s.device_id is null
		           or cast(s.time as decimal(20,7)) >=
		              (select min(cast(time as decimal(20,7))) from seqgraph_newframes) - $SEQGRAPH_ALPHA )
		      order by cast(s.time as decimal(20,7));"
	fi

	mysql probeprint <<< "truncate table device_stage;"

	mysql -N probeprint <<< "$sql" \
	| LC_ALL=C awk -v ALPHA="$SEQGRAPH_ALPHA" -v BETA="$SEQGRAPH_BETA" -v MOD="$SEQ_MODULUS" \
	           -v GATE_IE="$SEQGRAPH_GATE_IE" '
	BEGIN { FS = "|"; n = 0 }

	{
		ts[n]  = $1          # original string, used to address the row
		t[n]   = $1 + 0      # numeric, used for comparisons
		s[n]   = $2 + 0
		fp[n]  = $3          # ie_fp, or empty when the frame carried no IEs
		mac[n] = $4
		wps[n] = $5          # WPS UUID-E, or empty when the frame carried none
		dk[n]  = $6          # existing device_key for a grouped tail frame; empty
		                     # for a frame to be assigned. dk!="" ⟺ tail frame.
		parent[n] = n        # union-find: every node starts in its own set
		n++
	}

	# A globally-administered MAC is the manufacturer'"'"'s own, burned in and not
	# randomized, so it identifies the device outright -- no inference needed.
	# The locally-administered bit is 0x02 of the first octet, which makes the
	# second hex digit one of 2, 6, a or e.
	function is_random(m,   c) {
		if (m == "") return 1
		c = tolower(substr(m, 2, 1))
		return (c == "2" || c == "6" || c == "a" || c == "e")
	}

	function find(x,   r, y) {
		r = x
		while (parent[r] != r) r = parent[r]
		while (parent[x] != r) { y = parent[x]; parent[x] = r; x = y }   # path compression
		return r
	}

	# Always attaches the later root to the earlier one, so a component root is
	# its earliest member. The anchor derivation below depends on that.
	function union(a, b,   ra, rb) {
		ra = find(a); rb = find(b)
		if (ra == rb) return
		if (rb < ra) parent[ra] = rb; else parent[rb] = ra
	}

	# Forward sequence distance, accounting for the 12-bit counter wrapping.
	# The paper measured wrap-induced splits at only 0.5% of samples, but
	# handling it costs almost nothing.
	function seqfwd(from, to,   d) {
		d = to - from
		if (d < 0) d += MOD
		return d
	}

	END {
		# Frames sharing a non-randomized MAC are one device by definition, so
		# union them before any inference runs. Without this the graph could
		# only hold such a device together through sequence continuity, and it
		# fragmented whenever that broke: measured against labelled ground truth,
		# one device that never rotated its address -- a single MAC, a single IE
		# fingerprint -- came out as 137 separate devices.
		#
		# This is not a heuristic competing with the graph. It is the one case
		# where the answer is known, and FINGERPRINTING.md already relies on it
		# as ground truth for validation; it belongs on the input side too.
		for (i = 0; i < n; i++) {
			if (is_random(mac[i])) continue
			if (mac[i] in firstseen) union(firstseen[mac[i]], i)
			else firstseen[mac[i]] = i
		}

		# Frames sharing a WPS UUID-E are one device, for the same reason and
		# with more force than a static MAC: the UUID-E is a persistent per-device
		# identifier carried in the WPS element, in several implementations
		# derived from the hardware MAC, so it holds THROUGH randomization -- two
		# frames with different randomized MACs but the same UUID-E are provably
		# the same device. Union them before inference too. Empty (no WPS element)
		# is not an identifier and never unions.
		for (i = 0; i < n; i++) {
			if (wps[i] == "") continue
			if (wps[i] in wpsseen) union(wpsseen[wps[i]], i)
			else wpsseen[wps[i]] = i
		}

		for (i = 0; i < n; i++) {
			best = -1; best_dt = -1; best_ds = -1

			for (j = i + 1; j < n; j++) {
				dt = t[j] - t[i]
				if (dt > ALPHA) break             # time-ordered: no later j qualifies
				if (dt <= 0) continue             # strictly forward in time
				if (taken_in[j]) continue         # one incoming edge per node

				# Two frames whose IE fingerprints positively disagree cannot be
				# the same device. Frames with no IE data are never blocked.
				if (GATE_IE == 1 && fp[i] != "" && fp[j] != "" && fp[i] != fp[j]) continue

				ds = seqfwd(s[i], s[j])
				if (ds <= 0 || ds > BETA) continue    # strictly forward in sequence

				# "the shortest of all such possible links in terms of both
				# time and sequence number"
				if (best < 0 || (dt < best_dt && ds <= best_ds) || (dt <= best_dt && ds < best_ds)) {
					best = j; best_dt = dt; best_ds = ds
				}
			}

			if (best >= 0) {
				taken_in[best] = 1                # and one outgoing, by construction
				union(i, best)
			}
		}

		# Stage only the frames that need assigning (tail frames already have a
		# device_id and are here purely as anchors). A component device_key is the
		# key of its EARLIEST member: a grouped tail frame contributes its
		# existing key, so the new frames join that device; a new frame root
		# contributes md5 of its time, minting a new device. find() returns the
		# earliest-indexed root, and rows are time-ordered, so the root is the
		# earliest member. (No apostrophes in this awk block -- they would close
		# the single-quoted program.)
		batch = 0
		for (i = 0; i < n; i++) {
			if (dk[i] != "") continue          # tail frame: keep its device_id
			r = find(i)
			key = (dk[r] != "") ? "\"" dk[r] "\"" : "substr(md5(\"" ts[r] "\"),1,16)"
			if (batch % 500 == 0) {
				if (batch > 0) print ";"
				printf "insert into device_stage (time, device_key) values "
			} else printf ","
			printf "(\"%s\", %s)", ts[i], key
			batch++
		}
		if (batch > 0) print ";"
	}
	' \
	| mysql probeprint

	# Mint any device we have not seen before, then point its frames at it.
	# `insert ignore` leans on the unique key over device_key: a component that
	# already exists keeps the autoincrement id it was first given.
	#
	# READ COMMITTED, not the server default REPEATABLE READ. This big UPDATE
	# joins device_stage to every ssid row it groups; under REPEATABLE READ its
	# scan takes next-key/gap locks, including the trailing gap above the largest
	# time -- exactly where a live capture inserts its next frame. A concurrent
	# capture.sh INSERT then blocks until this UPDATE commits and times out
	# ("Lock wait timeout exceeded"), freezing capture on a field node that runs
	# analysis.sh and capture.sh at once. READ COMMITTED sets no gap locks, so it
	# locks only the existing rows it actually updates; a new-timestamp INSERT
	# never collides with those, and capture keeps flowing.
	mysql probeprint <<'SQL'
set session transaction isolation level read committed;
insert ignore into devices (device_key) select distinct device_key from device_stage;

update ssid s
  join device_stage t on s.time = t.time
  join devices d      on d.device_key = t.device_key
   set s.device_id = d.id;
SQL

	# Rebuild the PNL and stats. Incremental scopes both to the devices this run
	# actually touched -- those holding a frame that was new at the start -- so a
	# live sweep does not re-aggregate the whole ssid table. Recompute rebuilds
	# everything (no scope). assign_aliases only names aliasless devices, so it
	# is already incremental.
	if [ "$recompute" = 1 ]; then
		seqgraph_refresh_pnl
		seqgraph_refresh_stats
	else
		mysql probeprint <<'SQL'
truncate table seqgraph_touched;
insert into seqgraph_touched (device_id)
  select distinct device_id from ssid
   where device_id is not null
     and time in (select time from seqgraph_newframes);
SQL
		seqgraph_refresh_pnl scoped
		seqgraph_refresh_stats scoped
	fi
	assign_aliases

	echo "seqgraph_assign stop $(date +"%H:%M:%S.%3N")"
	echo "  devices identified: $(mysql -N probeprint <<< "select count(*) from devices;")"
	echo "  frames assigned:    $(mysql -N probeprint <<< "select count(*) from ssid where device_id is not null;")"
	echo "  randomization defeated on: $(mysql -N probeprint <<< "select count(*) from devices where mac_count > 1;") device(s)"
	echo "  low confidence (suspect merge): $(mysql -N probeprint <<< "select count(*) from devices where confidence='low';")"
}

# seqgraph_refresh_pnl
#
# Rebuild device_ssid: the list of networks each device asks for.
#
# This is the output that matters. The device id says "one device"; this list
# says whose. It is also what a linkage pass compares -- Cunche's result is that
# two devices sharing even one *rare* SSID are almost certainly carried by
# socially connected people, while a shared common SSID means nothing.
#
# The wildcard sentinel is excluded: "probed for no particular network" is not a
# preference and would otherwise appear in every device's list.
# seqgraph_refresh_pnl [scoped]
#
# Rebuild device_ssid. With no argument it rebuilds every device (recompute,
# standalone --pnl, tests). Called with "scoped", it limits every clause to the
# devices in seqgraph_touched -- the ones an incremental run actually changed --
# so a live sweep does not re-aggregate the whole ssid table.
seqgraph_refresh_pnl () {
	local f1="" f2="" f3=""     # device filters for the three statements
	if [ "${1:-}" = "scoped" ]; then
		f1="and device_id in (select device_id from seqgraph_touched)"
		f2="and ds.device_id in (select device_id from seqgraph_touched)"
		f3="where ds.device_id in (select device_id from seqgraph_touched)"
	fi
	mysql probeprint <<SQL
replace into device_ssid (device_id, ssid_hex, frame_count, first_seen, last_seen)
select device_id, ssid_hex, count(*), min(time), max(time)
  from ssid
 where device_id is not null
   and ssid_hex <> '<MISSING>'
   and ssid_hex <> ''
   $f1
 group by device_id, ssid_hex;

-- Drop rows for (device, ssid) pairs that no longer exist, which happens after
-- a --recompute reshuffles cluster membership.
delete ds from device_ssid ds
 left join ssid s
        on s.device_id = ds.device_id and s.ssid_hex = ds.ssid_hex
 where s.time is null $f2;

-- pnl_rarity is the summed rarity of the list: how identifying it is taken as a
-- whole. Requires standalone_rarity.sh to have run; stays NULL otherwise rather
-- than silently reporting zero, which would read as "anonymous".
update devices d
  join (
    select ds.device_id,
           count(*)          as n,
           sum(i.rarity)     as r
      from device_ssid ds
      left join ssid_intel i on i.ssid_hex = ds.ssid_hex
     $f3
     group by ds.device_id
  ) x on x.device_id = d.id
   set d.pnl_size   = x.n,
       d.pnl_rarity = x.r;
SQL
}

# seqgraph_validate
#
# Measure the clustering against ground truth that is already in the data.
#
# Most devices randomize their MAC, but a minority -- IoT, older hardware, some
# laptops -- do not. For those the MAC *is* the identity, with no inference
# involved, which makes them free labeled data on every real capture:
#
#   two different globally-unique MACs in one cluster  -> provable FALSE MERGE
#   one globally-unique MAC split across two clusters  -> provable FALSE SPLIT
#
# That gives a measured error rate at the current alpha/beta, in the actual
# environment, rather than a number from a synthetic fixture. Use it to tune
# alpha and beta per site instead of guessing.
#
# Randomized addresses are the locally-administered ones: bit 1 of the first
# octet set, and bit 0 clear for a unicast source, so the second hex digit is
# one of 2, 6, a, e.
seqgraph_validate () {
	local static_pred="substr(wlan_sa,2,1) not in ('2','6','a','e')"

	echo "== sequence graph validation against non-randomized MACs =="
	echo "   (alpha=${SEQGRAPH_ALPHA}s beta=${SEQGRAPH_BETA} gate_ie=${SEQGRAPH_GATE_IE})"
	echo

	local static_macs clusters merges splits
	static_macs=$(mysql -N probeprint <<< "select count(distinct wlan_sa) from ssid where device_id is not null and $static_pred;")

	if [ "${static_macs:-0}" -eq 0 ]; then
		echo "   no non-randomized MACs in this capture -- nothing to validate against"
		return 0
	fi

	clusters=$(mysql -N probeprint <<< "select count(distinct device_id) from ssid where device_id is not null and $static_pred;")
	merges=$(mysql -N probeprint <<< "select count(*) from (select device_id from ssid where device_id is not null and $static_pred group by device_id having count(distinct wlan_sa) > 1) x;")
	splits=$(mysql -N probeprint <<< "select count(*) from (select wlan_sa from ssid where device_id is not null and $static_pred group by wlan_sa having count(distinct device_id) > 1) x;")

	printf '   ground-truth devices (unique static MACs) : %s\n' "$static_macs"
	printf '   clusters containing them                  : %s\n' "$clusters"
	printf '   FALSE MERGES (>1 static MAC per cluster)   : %s\n' "$merges"
	printf '   FALSE SPLITS (1 static MAC over >1 cluster): %s\n' "$splits"
	echo

	if [ "$merges" -gt 0 ]; then
		echo "   merged clusters:"
		mysql -N probeprint <<SQL | sed 's/^/     /'
select concat('device ', device_id, ' absorbs ', count(distinct wlan_sa), ' distinct static MACs: ',
              group_concat(distinct wlan_sa order by wlan_sa separator ' '))
  from ssid
 where device_id is not null and $static_pred
 group by device_id having count(distinct wlan_sa) > 1
 limit 10;
SQL
		echo
		echo "   Lower SEQGRAPH_ALPHA, or leave SEQGRAPH_GATE_IE=1 so disagreeing"
		echo "   IE fingerprints block an edge before the merge can happen."
	fi

	[ "$merges" -eq 0 ] && [ "$splits" -eq 0 ] && echo "   clean: no measurable error against ground truth"
	return 0
}

# seqgraph_refresh_stats
#
# Recompute the per-device rollups, including the confidence verdict.
#
# Confidence keys off IE fingerprint consistency. One physical device cannot
# change its IE signature mid-capture, so a component spanning more than one
# ie_fp is almost certainly a false merge -- which is this algorithm's known
# failure mode in dense environments, where unrelated devices' sequence counters
# interleave inside alpha. Frames that carried no fingerprint IEs at all are
# excluded from the count; otherwise a capture with no IE data would look
# perfectly consistent rather than simply unknown.
seqgraph_refresh_stats () {
	local f1=""
	[ "${1:-}" = "scoped" ] && f1="and device_id in (select device_id from seqgraph_touched)"
	mysql probeprint <<SQL
update devices d
  join (
    select device_id,
           min(time)                as fs,
           max(time)                as ls,
           count(*)                 as fc,
           count(distinct wlan_sa)  as mc,
           count(distinct ssid_hex) as sc,
           count(distinct case when ie_order is not null then ie_fp end) as fpd
      from ssid
     where device_id is not null
       $f1
     group by device_id
  ) x on x.device_id = d.id
   set d.first_seen     = x.fs,
       d.last_seen      = x.ls,
       d.frame_count    = x.fc,
       d.mac_count      = x.mc,
       d.ssid_count     = x.sc,
       d.ie_fp_distinct = x.fpd,
       d.confidence     = case when x.fpd > 1 then 'low'
                               when x.fpd = 1 then 'high'
                               else                'unknown' end;

-- Vendor is only ever partially knowable. An IE fingerprint identifies a device
-- class, but nothing maps that class to a model -- there is no public corpus of
-- 802.11 probe IE signatures. What *is* resolvable is the manufacturer OUI,
-- either from a non-randomized MAC (mac2vendor fills ssid.vendor) or from the
-- vendor-specific IE. '.' is mac2vendor's "looked up, found nothing" marker.
update devices d
   set d.vendor = (select s.vendor
                     from ssid s
                    where s.device_id = d.id
                      and s.vendor is not null
                      and s.vendor <> '.'
                    limit 1)
 where d.vendor is null;
SQL
}

# assign_aliases
#
# Give every device a human-readable handle for the operator display.
#
# The alias is a NON-KEY attribute. Nothing should ever join on it, and it must
# never appear in a foreign key -- devices.id is the only identity. A name is
# for a person reading a screen in a room; it is not data.
#
# Derived deterministically from device_key so the same device gets the same
# name on any machine, then *stored* rather than recomputed on read, because a
# pure hash would eventually show two devices the same name. Collisions get a
# numeric discriminator, and the unique index on alias enforces it.
assign_aliases () {
	local -a ADJ NOUN
	mapfile -t ADJ  < lists/adjectives.txt
	mapfile -t NOUN < lists/nouns.txt

	if [ "${#ADJ[@]}" -eq 0 ] || [ "${#NOUN[@]}" -eq 0 ]; then
		echo "assign_aliases: word lists missing or empty, skipping" >&2
		return 1
	fi

	local id key ai ni base candidate n a

	# Nothing to name if every device already has an alias -- the usual state on
	# an incremental sweep. Return before touching the whole devices table, which
	# is what makes a no-new-device sweep instant.
	local pending
	pending=$(mysql -N probeprint <<< "select count(*) from devices where alias is null;")
	[ "${pending:-0}" -eq 0 ] && return 0

	# Collision detection is done in memory against a set of names already in
	# use, and the updates are emitted as one batch.
	#
	# The obvious shape -- query "is this name taken" and UPDATE, per device --
	# costs two mysql process spawns per device. On a real capture that produced
	# 11,448 devices that is ~23,000 spawns and dominates the runtime of the
	# whole pass; at a tighter alpha, which yields 65,000 devices, it is far
	# worse. Two queries and one piped batch instead.
	#
	# mapfile, not `while read`, to load the in-use set: on 38k devices the
	# per-line read loop alone ran ~3 minutes and dominated every seqgraph sweep.
	# mapfile reads them in one pass; the assoc-array fill is then just memory.
	local -A used=()
	local -a existing
	mapfile -t existing < <(mysql -N probeprint <<< "select alias from devices where alias is not null;")
	for a in "${existing[@]}"; do [ -n "$a" ] && used["$a"]=1; done

	{
		echo "start transaction;"
		while IFS='|' read -r id key; do
			[ -z "$id" ] && continue

			# Two independent slices of the key, so the slots vary independently.
			ai=$(( 16#${key:0:6} % ${#ADJ[@]} ))
			ni=$(( 16#${key:6:6} % ${#NOUN[@]} ))
			base="${ADJ[$ai]} ${NOUN[$ni]}"

			candidate="$base"
			n=1
			while [ -n "${used[$candidate]:-}" ]; do
				n=$((n + 1))
				candidate="$base $n"
			done
			used["$candidate"]=1

			printf 'update devices set alias="%s" where id=%s;\n' "$candidate" "$id"
		done < <(mysql -N probeprint <<< "select concat_ws('|', id, device_key) from devices where alias is null order by id;")
		echo "commit;"
	} | mysql probeprint
}

# seqgraph_report
#
# A device spanning several MAC addresses is a randomization undone. A device
# flagged low confidence is one to distrust before acting on it, so those sort
# to the top.
seqgraph_report () {
	printf '%-5s %-24s %-11s %6s %5s %4s %9s %-14s %s\n' \
		"id" "alias" "confidence" "frames" "macs" "pnl" "pnl_rarity" "vendor" "networks"
	mysql -N probeprint <<'SQL' | awk -F'\t' '{ printf "%-5s %-24s %-11s %6s %5s %4s %9s %-14s %s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9 }'
select d.id,
       ifnull(d.alias,'-'),
       ifnull(d.confidence,'-'),
       d.frame_count,
       d.mac_count,
       d.pnl_size,
       ifnull(round(d.pnl_rarity,1),'-'),
       ifnull(substr(d.vendor,1,14),'-'),
       ifnull((select group_concat(substr(unhex(ds.ssid_hex),1,18) order by ds.ssid_hex separator ', ')
                 from device_ssid ds where ds.device_id = d.id), '-')
  from devices d
 order by (d.confidence = 'low') desc, d.pnl_rarity desc, d.mac_count desc
 limit 40;
SQL
}
