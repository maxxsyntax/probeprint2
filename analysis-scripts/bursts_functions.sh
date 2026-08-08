#!/bin/bash
#0 = unprocessed
#1 = no burst found by mac address
#2 = no burst found by sequence number
#3 = no burst found by vht
# Burst grouping, batched.
#
# All three passes used to walk one frame at a time: a SELECT to find the next
# unprocessed row, a SELECT for its window, then an UPDATE per member and an
# INSERT per burst. Roughly five `mysql` invocations per frame.
#
# Measured on this host, a separate `mysql` invocation costs 35ms while the same
# query inside an already-open session costs 0.82ms -- so 43x of the cost was
# process spawn, connection handshake and teardown, not database work. At 8
# rows/sec a full recompute of a real collection ran to about ten hours, on a
# machine sitting at 1.6 load with seven idle cores. Faster hardware would not
# have helped: none of that 35ms is computation.
#
# So each pass is now one SELECT, the grouping done in awk, and one batched
# write -- the shape seqgraph_functions.sh already uses.
#
# The grouping logic is unchanged: an anchor frame claims every later frame
# within BURST_WINDOW seconds that matches on the pass's key, members are
# consumed so they cannot anchor another burst, and a lone frame advances to the
# next stage instead of forming one.

# How a burst's boundary is decided.
#
#   gap     (default) a burst continues while frames keep arriving within
#           BURST_GAP of the previous one. No ceiling on duration.
#   window  the original: an anchor frame claims everything within
#           BURST_WINDOW seconds of ITSELF, then the next unclaimed frame
#           anchors the next burst.
#
# The window form cuts every burst at a fixed distance from whichever frame
# happened to anchor it, so a genuine burst straddling that boundary is reported
# as two and burst_duration can never exceed BURST_WINDOW. FINGERPRINTING.md
# names that as the reason burst_size and burst_duration are partly artifacts of
# the window rather than properties of the traffic. Kept switchable so the two
# can be compared on real data.
BURST_SHAPE=${BURST_SHAPE:-gap}

# Maximum silence inside one burst, for BURST_SHAPE=gap.
BURST_GAP=${BURST_GAP:-1.0}

# Seconds an anchor reaches forward, for BURST_SHAPE=window.
BURST_WINDOW=${BURST_WINDOW:-1.0}

# Sequence numbers a burst reaches forward, for the seq pass.
BURST_SEQ_SPAN=${BURST_SEQ_SPAN:-60}

# _bursts_group <method> <no_match_state> <key_mode>
#
# Reads '|'-separated rows on stdin as: time|key|ssid_hex|seq
# Emits SQL on stdout. key_mode 'exact' matches the key column; 'seq' matches
# the sequence window instead and ignores the key.
_bursts_group () {
	LC_ALL=C awk -v METHOD="$1" -v NOMATCH="$2" -v MODE="$3" \
	             -v WINDOW="$BURST_WINDOW" -v SEQSPAN="$BURST_SEQ_SPAN" \
	             -v SHAPE="$BURST_SHAPE" -v GAP="$BURST_GAP" '
	BEGIN { FS = "|"; n = 0; nb = 0; nm = 0; nl = 0 }
	{
		ts[n]   = $1        # original string: `time` is a varchar primary key,
		t[n]    = $1 + 0    # so the update must use it verbatim
		key[n]  = $2
		ssid[n] = $3
		sq[n]   = $4 + 0
		n++
	}
	# Close an accumulated run and record it as a burst, or as a lone frame.
	function flush(id,   m, s, cnt) {
		cnt = runlen[id]
		if (cnt < 1) return
		if (cnt > 1) {
			s = ssid[run[id, 0]]
			for (m = 1; m < cnt; m++) s = s ":" ssid[run[id, m]]
			burst_ssids[nb] = s
			burst_time[nb]  = ts[run[id, 0]]
			burst_size[nb]  = cnt
			burst_dur[nb]   = t[run[id, cnt - 1]] - t[run[id, 0]]
			nb++
			for (m = 0; m < cnt; m++) matched[nm++] = ts[run[id, m]]
		} else {
			lone[nl++] = ts[run[id, 0]]
		}
		runlen[id] = 0
	}

	END {
		if (SHAPE == "gap") {
			# GAP-BASED. A burst runs for as long as frames keep arriving within
			# GAP of the previous one, with no fixed ceiling. The windowed form
			# below cuts every burst at WINDOW seconds after whichever frame
			# happened to anchor it, so a real burst straddling that boundary is
			# reported as two and burst_duration is capped by construction.
			# FINGERPRINTING.md flags that as the reason burst_size and
			# burst_duration are partly artifacts of the window.
			for (i = 0; i < n; i++) {
				if (MODE == "seq") {
					# No key to group on: chain forward on sequence continuity.
					# Only chains touched within GAP can still be extended, so
					# the open set stays small and this stays near-linear.
					hit = -1
					for (c in openlast) {
						if (t[i] - openlast[c] > GAP) { flush(c); delete openlast[c]; continue }
						if (sq[i] >= openseq[c] && sq[i] <= openseq[c] + SEQSPAN) {
							if (hit < 0 || openlast[c] > openlast[hit]) hit = c
						}
					}
					if (hit < 0) { hit = "c" i; runlen[hit] = 0 }
					run[hit, runlen[hit]++] = i
					openlast[hit] = t[i]
					openseq[hit]  = sq[i]
				} else {
					k = key[i]
					if (k in openlast && t[i] - openlast[k] > GAP) flush(k)
					run[k, runlen[k]++] = i
					openlast[k] = t[i]
				}
			}
			for (c in openlast) flush(c)
		} else {

		for (i = 0; i < n; i++) {
			if (used[i]) continue
			cnt = 0
			members[cnt++] = i
			last = i
			for (j = i + 1; j < n; j++) {
				if (t[j] - t[i] > WINDOW) break     # time-ordered: no later j qualifies
				if (used[j]) continue
				if (MODE == "seq") {
					if (sq[j] < sq[i] || sq[j] > sq[i] + SEQSPAN) continue
				} else {
					if (key[j] != key[i]) continue
				}
				members[cnt++] = j
				used[j] = 1
				last = j
			}
			used[i] = 1

			if (cnt > 1) {
				s = ssid[members[0]]
				for (m = 1; m < cnt; m++) s = s ":" ssid[members[m]]
				burst_ssids[nb] = s
				burst_time[nb]  = ts[i]
				burst_size[nb]  = cnt
				burst_dur[nb]   = t[last] - t[i]
				nb++
				for (m = 0; m < cnt; m++) matched[nm++] = ts[members[m]]
			} else {
				lone[nl++] = ts[i]
			}
		}
		}   # end windowed branch

		# Batched output. Chunked so no single statement grows unbounded on a
		# large collection.
		for (b = 0; b < nb; b += 500) {
			printf "insert ignore into bursts (ssids,time,burst_size,burst_duration,bmethod) values "
			for (k = b; k < b + 500 && k < nb; k++) {
				if (k > b) printf ","
				printf "(\"%s\",\"%s\",%d,%.7f,\"%s\")",
				       burst_ssids[k], burst_time[k], burst_size[k], burst_dur[k], METHOD
			}
			printf ";\n"
		}
		for (b = 0; b < nm; b += 1000) {
			printf "update ssid set is_processed=100 where time in ("
			for (k = b; k < b + 1000 && k < nm; k++) {
				if (k > b) printf ","
				printf "\"%s\"", matched[k]
			}
			printf ");\n"
		}
		for (b = 0; b < nl; b += 1000) {
			printf "update ssid set is_processed=%s where time in (", NOMATCH
			for (k = b; k < b + 1000 && k < nl; k++) {
				if (k > b) printf ","
				printf "\"%s\"", lone[k]
			}
			printf ");\n"
		}
		printf "-- bursts:%d grouped:%d lone:%d\n", nb, nm, nl
	}'
}

# _bursts_run <label> <select-sql> <method> <nomatch_state> <key_mode>
_bursts_run () {
	local label=$1 sql=$2 method=$3 nomatch=$4 mode=$5
	echo "$label start $(date +"%H:%M:%S.%3N")"

	local sqlfile
	sqlfile=$(mktemp)
	# One SELECT out, one batched script in. The counters come back as a SQL
	# comment so they survive the pipe without a subshell swallowing them --
	# the same trap that made the geolocate counters report zero.
	mysql -N probeprint <<< "$sql" | _bursts_group "$method" "$nomatch" "$mode" > "$sqlfile"
	grep '^-- bursts:' "$sqlfile" | sed 's/^-- /  /'
	mysql probeprint < "$sqlfile"
	rm -f "$sqlfile"

	echo "$label stop $(date +"%H:%M:%S.%3N")"
}

# Group frames sharing a MAC address. Only useful for devices that do not
# randomize, which is why the two passes below exist.
ssid_2bursts-wlan_sa () {
	mkdir -p "${PP_LOG_DIR:-logs}" 2>/dev/null
	_bursts_run "ssid_2bursts-wlan_sa" \
	  "select concat_ws('|', time, wlan_sa, ssid_hex, ifnull(seq,0))
	     from ssid
	    where is_processed=0 and wlan_sa is not null and time != ''
	    order by cast(time as decimal(20,7));" \
	  "wlan_sa" 1 exact
}

# Group frames whose sequence numbers run forward together, regardless of MAC.
# This is the pass that can see through randomization.
#
# RSSI used to gate membership at +/-2 dBm. Measured against a labelled corpus
# of 22 stationary devices in a semi-anechoic chamber, consecutive frames from
# ONE device moved a mean of 9.6 dBm and exceeded 2 dBm 40% of the time, so the
# gate rejected about 40% of genuine same-device pairs. Within one device the
# readings scatter with a standard deviation of 13.4 dBm while the devices' own
# means differ by 3.0 dBm -- the noise is 4.5x the signal. RSSI is proximity,
# not identity; see FINGERPRINTING.md.
ssid2bursts-seq () {
	_bursts_run "ssid_2bursts-seq" \
	  "select concat_ws('|', time, wlan_sa, ssid_hex, seq)
	     from ssid
	    where is_processed=1 and seq is not null and time != ''
	    order by cast(time as decimal(20,7));" \
	  "seq" 2 seq
}

# Group frames advertising identical VHT capabilities. A missing VHT tag leaves
# nothing to correlate on, so those rows skip straight to the next state.
ssid2bursts-vht () {
	_bursts_run "ssid_2bursts-vht" \
	  "select concat_ws('|', time, vht, ssid_hex, ifnull(seq,0))
	     from ssid
	    where is_processed=2 and vht is not null and vht != '' and time != ''
	    order by cast(time as decimal(20,7));" \
	  "vht" 3 exact

	# Rows with no VHT tag never enter the pass above; advance them so they do
	# not sit at state 2 forever.
	mysql probeprint <<< "update ssid set is_processed=3
	                       where is_processed=2 and (vht is null or vht='');"
}



























































is_uniq () {
	echo is_uniq start $(date +"%H:%M:%S.%3N")
#set -x
ssids=.
until [ -z $ssids ]; do
ssids=$(mysql -N probeprint <<< "select ssids from bursts where is_uniq is null limit 1")
uniq=0
uniq=$(echo ${ssids[*]} | tr \:  \\n |  sort | uniq  | wc -l)
	if [[ $uniq -lt 2 ]]; then
		mysql probeprint <<< "update bursts set is_uniq=0 where ssids=\"$ssids\";"
	else   
		mysql probeprint <<< "update bursts set is_uniq=1 where ssids=\"$ssids\";"
	fi
done
	echo is_uniq stop $(date +"%H:%M:%S.%3N")
}
























#NOT CURRENTLY WIRED UP: the call in build_bursts.sh is still commented out, so
#this runs nowhere and has no test data. The known bugs are now repaired, so it
#is ready to wire up and exercise on a real capture:
#  - the retrieval selected `time,ssids` (tab-separated), then split on ':'
#    only, gluing the timestamp onto the first SSID in ssids[0]. It now selects
#    concat_ws(':', time, ssids), so ssids[0] is the timestamp and ssids[1..]
#    are the SSIDs, which is the indexing the rest of the function assumes.
#  - the `[ -n/-z $ignore_check ]` tests are now quoted, and the `${ssids[$ssdi]}`
#    typo is fixed to `${ssids[$ssidi]}`.
#  - the "too common to correlate on" gate now reads ssid_intel.rarity
#    (rarity < 15, matching display.sh's rare-network threshold) instead of the
#    superseded is_common flag; airports are still excluded.
#Because it has never run against real data, verify the burst-relation output
#before trusting it.
find_relatedbursts () {
echo starting find_relatedbursts $(date +"%H:%M:%S.%3N")
while true; do
#`local IFS` so this cannot leak out into the other functions in this file --
#they are all sourced into one shell, and a global IFS=: broke the tab-separated
#mysql output the burst passes read.
local IFS=:
###
###set related_burst to ignore for bursts of non-unique common ssids
###
#select unprocessed rowid and break into array
ssids=($(mysql -N probeprint <<< "select concat_ws(':', time, ssids) from bursts where burst_duration != 0 and burst_size > 1 and related_burst = 0 and is_uniq=1 and time != \"\" limit 1;"));
echo ${ssids[*]}
#check for value
if [[ -z ${ssids} ]]
	then echo nothing to do, no ssids
	echo find_relatedbursts stop $(date +"%H:%M:%S.%3N")
sleep 10
break
fi
#set a count of all the ssids
ssidn="${#ssids[@]}"
# number of ssid to examine, ssid[0] = time
ssidi=1
echo working on ${ssids[$ssidi]}

#find bursts of uniq ssids only ; could be taken care of by is_uniq
uniq=0
uniq=$(echo ${ssids[*]} | tr \  \\n |  sort | uniq  | wc -l)
((uniq--))
#echo $uniq


if [[ $uniq -lt 2 ]]
	then 
	echo only 1 unique ssid in burst
	echo doing ignore check
	ignore_check=$(mysql -N probeprint <<< "select ssid_hex from ssid_intel where ((rarity is not null and rarity < 15) or is_airport IS NOT NULL) and ssid_hex=\"${ssids[1]}\";")
	if [ -n "$ignore_check" ];
		then
		echo ssid ${ssids[1]} is on ignore list, setting related burst to self
		mysql probeprint <<< "update bursts set related_burst=\"${ssids[0]}\" where time=\"${ssids[0]}\";"
		echo exit was here
		#exit 1
	fi
#continue process for ssids not on ignore list
	echo finding similar bursts for time = ${ssids[0]}
	mysql probeprint <<< "update bursts set related_burst=\"${ssids[0]}\" where (ssids like \"%:${ssids[1]}:%\" or ssids like \"%:${ssids[1]}\" or ssids like \"${ssids[1]}:%\") AND related_burst != \"IGNORE\";"
	#mark parent burst as complete
	mysql probeprint <<< "update bursts set related_burst=\"${ssids[0]}\" where time=\"${ssids[0]}\";"
fi
#done processing bursts with only 1 ssid


#for non uniq ssids
#check for ignored ssids.  super common ssid, like name of current location wifi
#ignored is wrong answer, need to iterate to next in array

until [[ "$ssidi" == "$ssidn" ]]
	do
	#echo $ssidi
	#echo ${ssids[$ssidi]}
	echo doing ignore check
	ignore_check=$(mysql -N probeprint <<< "select ssid_hex from ssid_intel where ((rarity is not null and rarity < 15) or is_airport IS NOT NULL) and ssid_hex=\"${ssids[$ssidi]}\";")
	if [ -z "$ignore_check" ];
		then
		#No value so not on the ignore list
		mysql probeprint <<< "update bursts set related_burst=\"${ssids[0]}\" where (ssids like \"%:${ssids[$ssidi]}:%\" or ssids like \"${ssids[$ssidi]}:%\" or ssids like \"%${ssids[$ssidi]}\" or ssids=\"{ssids[$ssidi]}\") AND related_burst != \"IGNORE\";"
		echo updated ssids like ${ssids[$ssidi]} with time  ${ssids[0]}
		#end extra action
		else echo ${ssids[$ssidi]} is on ignore list
	fi
	#move to next ssid for both ignore and not ignore
	((ssidi++))
	echo will be working on ${ssids[$ssidi]}
done
#done for until

#set parenent burst related burst
mysql probeprint <<< "update bursts set related_burst=\"${ssids[0]}\" where time=\"${ssids[0]}\";"
echo exit 0 was here
#exit 0
done
echo find_relatedbursts stop  $(date +"%H:%M:%S.%3N")
}
