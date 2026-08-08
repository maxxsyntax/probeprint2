#!/bin/bash
# Trace fidelity: estimate how much of what was transmitted actually got
# captured, from the data already in the ssid table.
#
# Every other pass here treats `ssid` as the population. It is a sample, and not
# a uniform one -- Schulman, Levin & Spring, "On the Fidelity of 802.11 Packet
# Traces" (PAM 2008), showed monitor completeness varies sharply with load,
# venue and channel, and that a trace carries enough information to measure its
# own completeness. See FINGERPRINTING.md.
#
# THE ESTIMATOR. An 802.11 sequence number is a per-transmitter frame counter,
# 12 bits, incremented once per new frame. Two consecutive captured frames from
# one address whose numbers differ by d mean d-1 frames from that device are
# absent from the trace. No reference capture is needed: the device tells us how
# many it sent.
#
# WHAT "ABSENT" MEANS -- the caveat that governs every number below. Ingest
# filters to probe requests (wlan.fc.type_subtype == 4), so a gap has two
# indistinguishable causes:
#
#   1. the monitor missed the frame          -- true capture loss
#   2. the device sent a non-probe frame     -- filtered out on purpose
#
# So this is a LOWER BOUND on completeness, and an associated device browsing
# the web will look much worse than an idle one. That does not weaken the main
# use: the sequence graph reasons about sequence deltas, and for its purposes
# the two causes are the same event -- the counter advanced unobserved. Fitting
# SEQGRAPH_ALPHA/BETA to this distribution is exactly right. Reading it as
# "the radio missed half the frames" is not.
#
# The published tool (CRAWDAD tools/analyze/pcap/wifidelity, GPL) works from a
# full trace rather than a probe-only one and does not have this ambiguity.
# The thresholds below are ours, not theirs; the paper's exact parameters could
# not be recovered.
#
# Read-only. No network, no writes, safe to run during capture.
#
# Configuration:
#   FIDELITY_BURST_GAP   seconds; pairs further apart are ignored  (default 2.0)
#   FIDELITY_MAX_DELTA   sequence deltas above this are ignored    (default 20)

FIDELITY_BURST_GAP=${FIDELITY_BURST_GAP:-2.0}
FIDELITY_MAX_DELTA=${FIDELITY_MAX_DELTA:-20}

# _fidelity_pairs_cte <since_clause>
#
# Shared CTE: consecutive frame pairs from one transmitter, with the sequence
# delta corrected for the 12-bit counter wrap.
#
# Two exclusions, both deliberate:
#
#   d = 0   a retransmission. 802.11 reuses the sequence number when it retries,
#           so a repeat is not a new frame and counting it as one would report
#           better-than-perfect completeness.
#   d > FIDELITY_MAX_DELTA
#           the device was idle, or sent a burst of other traffic, or rotated
#           its MAC. Attributing a delta of 900 to capture loss would swamp the
#           estimate with frames that were never probe requests at all.
_fidelity_pairs_cte () {
	local since=${1:-}
	cat <<SQL
with pairs as (
  select wlan_sa,
         cast(time as decimal(20,7)) t,
         freq,
         seq,
         lag(seq) over w prev_seq,
         lag(cast(time as decimal(20,7))) over w prev_t
    from ssid
   where seq is not null
     and wlan_sa is not null
     $since
   window w as (partition by wlan_sa order by cast(time as decimal(20,7)))
),
gaps as (
  select wlan_sa, t, freq,
         floor(t) sec,
         mod(seq - prev_seq + 4096, 4096) d,
         -- Kept as a flag rather than a filter so the pairs dropped for being
         -- outside a burst can be counted too. Silently discarding them would
         -- make a sparse capture look like a complete one.
         (t - prev_t <= $FIDELITY_BURST_GAP) same_burst
    from pairs
   where prev_seq is not null
)
SQL
}

# fidelity_completeness [--since SECONDS]
fidelity_completeness () {
	local since=""
	if [ "${1:-}" = "--since" ] && [ -n "${2:-}" ]; then
		since="and cast(time as decimal(20,7)) > unix_timestamp() - $2"
		echo "=== completeness, last $2s ==="
	else
		echo "=== completeness, whole collection ==="
	fi

	# -N: these rows are already labelled by their concat(), so the column
	# header is noise that reads as a data row.
	mysql -N probeprint <<SQL | sed 's/^/  /'
$(_fidelity_pairs_cte "$since")
select concat('frame pairs examined      : ', format(count(*), 0)) from gaps
 where same_burst and d between 1 and $FIDELITY_MAX_DELTA
union all
select concat('  consecutive (no gap)    : ', format(sum(d = 1), 0)) from gaps
 where same_burst and d between 1 and $FIDELITY_MAX_DELTA
union all
select concat('  frames unaccounted for  : ', format(sum(d - 1), 0)) from gaps
 where same_burst and d between 1 and $FIDELITY_MAX_DELTA
union all
select concat('retransmissions (d = 0)   : ', format(ifnull(sum(same_burst and d = 0), 0), 0)) from gaps
union all
-- The two exclusions are different things and are reported separately. A pair
-- can be dropped for spanning an idle period (time) or for a delta too large to
-- attribute to loss (sequence); conflating them hides which assumption is doing
-- the work.
select concat('excluded, outside a burst : ', format(ifnull(sum(not same_burst), 0), 0)) from gaps
union all
select concat('excluded, delta too large : ', format(ifnull(sum(same_burst and d > $FIDELITY_MAX_DELTA), 0), 0)) from gaps
union all
-- Frames after the first in each observed run: of the transmissions the
-- counter accounts for between our first and last capture in a burst, the
-- fraction we hold. The first frame of a run has no predecessor to be measured
-- against, so it is outside the ratio by construction.
select concat('COMPLETENESS (lower bound): ',
       ifnull(concat(round(100.0 * count(*) / nullif(count(*) + sum(d - 1), 0), 1), '%'),
              'n/a -- no usable pairs'))
  from gaps where same_burst and d between 1 and $FIDELITY_MAX_DELTA;
SQL
}

# fidelity_by_load [--since SECONDS]
#
# The T-Fi plot's question, as a table: does completeness fall as the channel
# gets busier? Load is observed frames per second, which is itself subject to
# the losses being measured -- a true offered-load axis is not available to a
# passive monitor.
fidelity_by_load () {
	local since=""
	[ "${1:-}" = "--since" ] && [ -n "${2:-}" ] && \
		since="and cast(time as decimal(20,7)) > unix_timestamp() - $2"

	echo "=== completeness by channel load ==="
	mysql probeprint <<SQL | sed 's/^/  /'
$(_fidelity_pairs_cte "$since")
, ld as (
  select floor(cast(time as decimal(20,7))) sec, count(*) fps
    from ssid
   where time is not null $since
   group by 1
)
select case when ld.fps <  5 then 'A   <5 frames/s'
            when ld.fps < 15 then 'B   5-14 frames/s'
            when ld.fps < 40 then 'C  15-39 frames/s'
            else                  'D  40+ frames/s' end as observed_load,
       format(count(*), 0) as pairs,
       concat(round(100.0 * count(*) / (count(*) + sum(g.d - 1)), 1), '%') as completeness
  from gaps g join ld on ld.sec = g.sec
 where g.same_burst and g.d between 1 and $FIDELITY_MAX_DELTA
 group by 1
 order by 1;
SQL
}

# fidelity_channels
#
# Which channels were listened to at all. A band with no frames is not a
# completeness problem to be estimated -- it is a hole no enrichment recovers,
# and the most likely reason a device present in the room never appears.
fidelity_channels () {
	echo "=== channel coverage ==="
	mysql probeprint <<'SQL' | sed 's/^/  /'
select ifnull(cast(freq as char), '(not recorded)') as mhz,
       case when freq is null then '?'
            when freq between 2400 and 2500 then '2.4 GHz'
            when freq between 4900 and 5900 then '5 GHz'
            when freq between 5925 and 7125 then '6 GHz'
            else 'other' end as band,
       format(count(*), 0) as frames,
       concat(round(100.0 * count(*) / (select count(*) from ssid), 1), '%') as share
  from ssid
 group by freq
 order by count(*) desc
 limit 16;
SQL

	# Threshold, not presence. A handful of stray 5 GHz frames is not coverage,
	# and testing `> 0` would report a band as covered on the strength of two
	# dozen frames out of a quarter million.
	local pct
	pct=$(mysql -N probeprint <<'SQL'
select round(100.0 * sum(freq between 4900 and 7125) / nullif(count(*), 0), 2) from ssid;
SQL
)
	echo
	echo "  5/6 GHz share of all frames : ${pct:-0}%"
	if awk -v p="${pct:-0}" 'BEGIN{exit !(p < 5)}'; then
		echo "  !! Effectively no 5/6 GHz coverage."
		echo "     Modern clients probe heavily on 5 GHz. A device that probes only"
		echo "     there is absent from this collection entirely, and no pass"
		echo "     downstream recovers it -- a capture gap, not an enrichment gap."
		echo "     A second radio on 5 GHz adds devices no software change can."
	fi
}

fidelity_report () {
	echo "fidelity_report start $(date +"%H:%M:%S.%3N")"
	echo
	fidelity_completeness "$@"
	echo
	fidelity_by_load "$@"
	echo
	fidelity_channels
	echo
	echo "  Completeness is a LOWER BOUND: ingest keeps probe requests only, so a"
	echo "  sequence gap counts both frames the monitor missed and other frames"
	echo "  the device sent. Use it to calibrate, not to indict the radio."
	echo "fidelity_report stop $(date +"%H:%M:%S.%3N")"
}
