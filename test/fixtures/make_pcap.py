#!/usr/bin/env python3
"""Generate a synthetic 802.11 probe-request pcap for ingest tests.

Frame set is chosen to cover the cases that broke the original positional
parser in build_ssid.sh:

  both_present  all fields populated -- the happy path
  no_signal     radiotap without dBm_AntSignal, so `radiotap.dbm_antsignal`
                comes back empty *in the middle* of the row
  no_channel    radiotap without Channel, so `wlan_radio.frequency` is empty
                mid-row
  no_vht        no VHT Capabilities IE, so the *last* field is empty
  broadcast     zero-length SSID; tshark reports the literal <MISSING>
  quote_ssid    SSID containing a double quote
  space_ssid    SSID containing a space
  burst_*       four frames from one MAC inside one second -> one burst
  dup_time_*    two frames sharing a timestamp -> `time` primary key collision

The mid-row empty fields are the important ones. A trailing empty field is
harmless under word-splitting, so `no_vht` alone would not have caught the bug.

Note that every frame must carry a radiotap header: a pcap has a single
link-layer type, so mixing bare Dot11 frames into a RadioTap file makes tshark
misparse them and the frame silently vanishes from `-T fields` output.
"""
import sys

from scapy.all import (
    Dot11,
    Dot11Elt,
    Dot11ProbeReq,
    RadioTap,
    wrpcap,
)

# VHT Capabilities information element (ID 191), 12 bytes of payload.
VHT_CAP_ID = 191
VHT_CAP_BODY = bytes.fromhex("32001780" "03fbfa00" "00fbfa00")


def probe(ssid: bytes, mac: str, seq: int, *, vht: bool = True,
          signal: bool = True, channel: bool = True):
    """Build one probe-request frame wrapped in a radiotap header."""
    dot11 = Dot11(
        type=0,           # management
        subtype=4,        # probe request
        addr1="ff:ff:ff:ff:ff:ff",
        addr2=mac,        # wlan.sa -- what burst grouping keys on
        addr3="ff:ff:ff:ff:ff:ff",
        SC=seq << 4,      # sequence number occupies the top 12 bits
    )

    frame = dot11 / Dot11ProbeReq() / Dot11Elt(ID=0, info=ssid)
    # Supported rates, so the frame resembles a real probe rather than a stub.
    frame = frame / Dot11Elt(ID=1, info=b"\x02\x04\x0b\x16")
    if vht:
        frame = frame / Dot11Elt(ID=VHT_CAP_ID, info=VHT_CAP_BODY)

    present = []
    kwargs = {}
    if signal:
        present.append("dBm_AntSignal")
        kwargs["dBm_AntSignal"] = -42
    if channel:
        present.append("Channel")
        kwargs["ChannelFrequency"] = 2437

    # An empty `present` list still yields a valid radiotap header, which keeps
    # the pcap link-layer type consistent across every frame.
    return RadioTap(present="+".join(present) or None, **kwargs) / frame


def main(out_path: str) -> None:
    base = 1700000000.0

    frames = [
        ("both_present", probe(b"HomeNetwork",  "aa:bb:cc:dd:ee:01", 100), base + 0.0),
        ("no_signal",    probe(b"NoSignalNet",  "aa:bb:cc:dd:ee:02", 101, signal=False), base + 1.0),
        ("no_channel",   probe(b"NoChannelNet", "aa:bb:cc:dd:ee:03", 102, channel=False), base + 2.0),
        ("no_vht",       probe(b"NoVhtNet",     "aa:bb:cc:dd:ee:04", 103, vht=False), base + 3.0),
        ("broadcast",    probe(b"",             "aa:bb:cc:dd:ee:05", 104), base + 4.0),
        ("quote_ssid",   probe(b'He said "hi"', "aa:bb:cc:dd:ee:06", 105), base + 5.0),
        ("space_ssid",   probe(b"My Home WiFi", "aa:bb:cc:dd:ee:07", 106), base + 6.0),
        # Same MAC, four frames inside one second -> one burst of 4 by wlan_sa.
        ("burst_1",      probe(b"BurstAlpha",   "aa:bb:cc:dd:ee:08", 200), base + 10.00),
        ("burst_2",      probe(b"BurstBravo",   "aa:bb:cc:dd:ee:08", 201), base + 10.10),
        ("burst_3",      probe(b"BurstCharlie", "aa:bb:cc:dd:ee:08", 202), base + 10.20),
        ("burst_4",      probe(b"BurstDelta",   "aa:bb:cc:dd:ee:08", 203), base + 10.30),
        # Identical timestamps -> primary-key collision on `time`.
        ("dup_time_a",   probe(b"DupTimeOne",   "aa:bb:cc:dd:ee:09", 300), base + 20.0),
        ("dup_time_b",   probe(b"DupTimeTwo",   "aa:bb:cc:dd:ee:0a", 301), base + 20.0),
    ]

    packets = []
    for name, pkt, ts in frames:
        pkt.time = ts
        packets.append(pkt)
        print(f"  {name:13s} t={ts:.2f}", file=sys.stderr)

    wrpcap(out_path, packets)
    print(f"wrote {len(packets)} frames to {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "probes.pcap")
