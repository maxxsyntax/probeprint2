#!/bin/bash
# Device identity from 802.11 sequence numbers.
#
# Implements the graph linkage from Soundararaj, Cheshire & Longley, "Estimating
# Real-Time Highstreet Footfall from Wi-Fi Probe Requests" (UCL, 2019).
#
# The 12-bit sequence counter in the MAC header increments per frame and is not
# reset when a device rotates its randomised MAC address. So a chain of probe
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
# Connected components are devices. Each is assigned a device_id, written back
# to ssid.device_id.
#
# Why this supersedes the old ssid2bursts-seq heuristic: that function looked
# for other probes inside a fixed one-second box with seq within +60 and RSSI
# within +/-2, and emitted a burst row. It could group frames *within* a burst
# but never chain two bursts, so a device that rotated its MAC between bursts
# appeared as two unrelated devices. The graph chains across the rotation.
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

# seqgraph_assign [--recompute]
seqgraph_assign () {
	local guard="and device_id is null"
	[ "${1:-}" = "--recompute" ] && guard=""

	echo "seqgraph_assign start $(date +"%H:%M:%S.%3N") (alpha=${SEQGRAPH_ALPHA}s beta=${SEQGRAPH_BETA})"

	# Ordered by time: the linking pass is a forward sweep, which lets it stop
	# scanning candidates as soon as the time threshold is exceeded.
	#
	# concat_ws for the usual reason -- mysql -N is tab separated and bash
	# collapses runs of tab as IFS whitespace, so an empty column would shift
	# the rest. The timestamp is carried through as the original *string*: it is
	# a varchar primary key, so reformatting it as a float would produce an
	# UPDATE that matches nothing.
	local sql="select concat_ws('|', time, seq, wlan_sa)
	             from ssid
	            where seq is not null
	              and time is not null
	              and time != ''
	              $guard
	            order by cast(time as decimal(20,7));"

	mysql -N probeprint <<< "$sql" \
	| LC_ALL=C awk -v ALPHA="$SEQGRAPH_ALPHA" -v BETA="$SEQGRAPH_BETA" -v MOD="$SEQ_MODULUS" '
	BEGIN { FS = "|"; n = 0 }

	{
		ts[n]  = $1          # original string, used to address the row
		t[n]   = $1 + 0      # numeric, used for comparisons
		s[n]   = $2 + 0
		parent[n] = n        # union-find: every node starts in its own set
		n++
	}

	function find(x,   r, y) {
		r = x
		while (parent[r] != r) r = parent[r]
		while (parent[x] != r) { y = parent[x]; parent[x] = r; x = y }   # path compression
		return r
	}

	function union(a, b,   ra, rb) {
		ra = find(a); rb = find(b)
		if (ra != rb) parent[rb] = ra
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
		for (i = 0; i < n; i++) {
			best = -1; best_dt = -1; best_ds = -1

			for (j = i + 1; j < n; j++) {
				dt = t[j] - t[i]
				if (dt > ALPHA) break             # time-ordered: no later j qualifies
				if (dt <= 0) continue             # strictly forward in time
				if (taken_in[j]) continue         # one incoming edge per node

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

		# Component root becomes the device id, prefixed so it reads as
		# synthetic rather than as anything observed on the wire.
		batch = 0
		for (i = 0; i < n; i++) {
			root = find(i)
			id = sprintf("dev-%06d", root)
			if (batch % 500 == 0) print "start transaction;"
			printf "update ssid set device_id=\"%s\" where time=\"%s\";\n", id, ts[i]
			batch++
			if (batch % 500 == 0) print "commit;"
		}
		if (batch % 500 != 0) print "commit;"
	}
	' \
	| mysql probeprint

	echo "seqgraph_assign stop $(date +"%H:%M:%S.%3N")"
	echo "  devices identified: $(mysql -N probeprint <<< "select count(distinct device_id) from ssid where device_id is not null;")"
	echo "  frames assigned:    $(mysql -N probeprint <<< "select count(*) from ssid where device_id is not null;")"
	echo "  randomisation defeated on: $(mysql -N probeprint <<< "select count(*) from (select device_id from ssid where device_id is not null group by device_id having count(distinct wlan_sa) > 1) x;") device(s)"
}

# seqgraph_report
#
# Show what the graph found. A device_id spanning more than one MAC address is
# a MAC randomisation that has been undone.
seqgraph_report () {
	printf '%-14s %8s %6s %7s  %s\n' "device_id" "frames" "macs" "ssids" "first seen"
	mysql -N probeprint <<'SQL' | awk -F'\t' '{ printf "%-14s %8s %6s %7s  %s\n", $1, $2, $3, $4, $5 }'
select device_id,
       count(*),
       count(distinct wlan_sa),
       count(distinct ssid_hex),
       min(time)
  from ssid
 where device_id is not null
 group by device_id
 order by count(distinct wlan_sa) desc, count(*) desc
 limit 40;
SQL
}
