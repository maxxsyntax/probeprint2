# probeprint2 field node (Raspberry Pi)

A headless Raspberry Pi **capture node**: it captures 802.11 probe requests and
keeps its clock synced, started at boot by `platforms/pi/start.sh`, each job in
its own detached `screen`. It also runs **hostapd**, standing up its own Wi-Fi
access point so an operator can join it and SSH in. **Enrichment (`analysis.sh`)
and the display (`display.sh`) run off-node**, not on the Pi: the continuous
analysis loop overheats the board (~85C, then it throttles and drops off the
network), so on a Pi you pull the captures to a workstation and enrich/view them
there. A non-Pi node with better cooling can run the full pipeline on one board
via the repo-root `start.sh`.

The capture, analysis and display logic all live in the main pipeline
(`../../capture-scripts/`, `../../analysis-scripts/`, `../../display-scripts/`);
this directory holds only the **Pi-specific boot and radio glue** — hard-coded
`/home/pi` paths, driven by cron and `screen`. **`platforms/pi/start.sh` is the
Pi boot entry point** (timesync + capture only); the repo-root `start.sh` is the
full-pipeline entry point for non-Pi nodes; `script.sh`/`start_cap.sh` are the
older per-step versions both supersede (see *Run on boot* below).

| File | Role |
|---|---|
| `start.sh` | **Pi `@reboot` entry point.** Sets monitor mode, then starts `timesync` + `capture` screens only (no analysis/display — thermal). |
| `script.sh` | Older `@reboot` entry point. Starts `start_cap.sh` in a detached `screen`. |
| `start_cap.sh` | Brings `wlan1` into monitor mode (`airmon-ng`) and runs `build_ssid.sh`. |
| `start_ad.sh` | Optional channel-hopping `airodump-ng`, off by default. |
| `hostapd.conf`, `ap.interfaces` | **The node's own Wi-Fi AP** (static addressing, no DHCP): the phone (and any second Pi) set a static `192.168.1.x` and SSH the Pi at `192.168.1.1` to run `display.sh`. See **[NETWORKING.md](./NETWORKING.md)**. |
| `usb0.interfaces`, `ap_nat.sh` | Optional internet: a laptop uplink over USB (`10.0.0.0/24`) NATed out for the AP's clients. |

---

## Time is load-bearing, and the Pi has no clock

**A Raspberry Pi has no battery-backed real-time clock.** When it powers on with
no network it does not know the date — it resumes from the last time it wrote to
disk (systemd's `fake-hwclock`), which can be hours or weeks stale, or falls back
toward the epoch. It only learns the true time once NTP reaches a server.

That is not a cosmetic problem here. In this schema:

- **`ssid.time` is the primary key**, a float epoch. Two frames that collide on a
  timestamp overwrite each other via `insert ignore`.
- The **sequence graph** links a device across MAC rotations by how close frames
  are in *time* (`SEQGRAPH_ALPHA`); the **fidelity** estimate reads inter-frame
  timing; the **"seen before"** display flag compares a device's sightings across
  an hour boundary.

If capture starts before the clock is set, every frame in that window is stamped
with the wrong epoch. Those rows then: collide with each other and with a later
correct run, break the seqgraph's time gates, and make a device look like it was
"seen before" (or not) on the strength of a fictional timestamp. **A capture node
with a wrong clock produces data that is worse than no data**, because it
silently corrupts the real captures it is merged with.

**`start.sh` runs `analysis-scripts/timesync.sh --loop` for exactly this.** It
checks connectivity on an interval and, the moment the node is online, pulls the
real time from NTP -- so a node that gets a network hours into a capture is
corrected as soon as it does, and it logs how far the clock had drifted (a large
jump flags frames captured under a bad clock). Run it standalone with
`sudo ./analysis-scripts/timesync.sh` or `--check` to just report state.

Two further defenses, use both:

1. **Force a time sync before capture starts.** Install an NTP client
   (`systemd-timesyncd` or `ntpdate`) and make `start_cap.sh` block on it. The
   `sleep 20` already at the top of `start_cap.sh` is a crude version of this;
   replace it with a real wait:

   ```bash
   # in start_cap.sh, before airmon-ng:
   # Do not capture until the clock is real. A Pi with no RTC boots to a stale
   # date; a frame stamped with it corrupts the primary key and every
   # time-based pass. timesyncd sets this once NTP lands.
   until timedatectl show -p NTPSynchronized --value | grep -q '^yes$'; do
       echo "waiting for NTP before capture" >> /home/pi/cap
       sleep 5
   done
   ```

   If the node has no internet at all (capture-only, data pulled later over
   USB — see below), fit a hardware RTC module (DS3231) instead, or set the
   clock from the collection host at the start of every pull.

2. **Reconcile on import, not on the sensor.** If a node did capture with a bad
   clock, its rows are identifiable by an implausible date. Prefer the node that
   had NTP; do not merge a pre-sync window into the main collection.

---

## USB gadget networking (`g_ether`)

A Pi Zero / Zero 2 W has a single micro-USB data port and can present itself to a
host computer as a USB Ethernet adapter, so one cable both powers the node and
carries its network. That is ideal for a capture node: the Wi-Fi radio stays in
monitor mode (no IP, no association) while the collection host reaches the node's
database over USB.

Enable the gadget on the Pi:

1. **`/boot/config.txt`** — load the USB OTG driver:

   ```
   dtoverlay=dwc2
   ```

2. **`/boot/cmdline.txt`** — add the gadget module right after `rootwait`, space
   separated, on the same single line:

   ```
   modules-load=dwc2,g_ether
   ```

3. Reboot with the host connected to the Pi's **USB data port** (not the
   power-only port on models that have two). The Pi appears as `usb0` on the Pi
   and as a USB Ethernet interface on the host.

4. Give `usb0` a static address on the Pi (e.g. `/etc/network/interfaces.d/usb0`):

   ```
   auto usb0
   allow-hotplug usb0
   iface usb0 inet static
       address 10.55.0.1
       netmask 255.255.255.0
   ```

   Address the host on the same `/24` (e.g. `10.55.0.2`). The collection host
   then reaches the node's MariaDB at `10.55.0.1`, and the node can point its own
   writes at a central server by setting `DB_HOST` in `.env` (see the main
   README's configuration table).

`g_ether` gives a point-to-point link only; it is not internet for the Pi. If the
node also needs NTP and WiGLE, either share the host's connection over the USB
link (IP forwarding / NAT on the host) or give the node its own uplink and keep
`usb0` for data pulls.

---

## Run on boot (crontab)

The Pi boot entry point is **`platforms/pi/start.sh`** (not the repo-root
`start.sh`). It sets monitor mode up (`airmon-ng`) and launches **timesync +
capture**, each in its own detached `screen` -- but it deliberately does **not**
start the `analysis.sh` loop or the live `display.sh`, because on a Pi the
continuous analysis loop drives the board to its ~85C thermal limit and it
throttles and drops off the network. **On a Pi, enrich and view off-node:** pull
the captures to a workstation and run `./analysis.sh` and `./display.sh` there.

The repo-root `start.sh` is unchanged and still launches the **full** pipeline
(capture + analysis + display); it is the right entry point for a mains-powered,
better-cooled, or non-Pi node. The Pi exception lives only here in `platforms/pi`.

This is safe under the Pi-as-AP model: `hostapd` is its own enabled service and
comes up before cron fires `@reboot`, and the `airmon-ng check kill` inside the Pi
start script stops NetworkManager/wpa_supplicant but not `hostapd`, so the AP is
up and stays up. (If it ever flaps as capture starts, `sudo systemctl restart hostapd`.)

Install as a **root** `@reboot` entry:

```bash
sudo crontab -e
```

Add (adjust the path to wherever the repo is checked out):

```
@reboot /home/pi/probeprint2/platforms/pi/start.sh >> /home/pi/probeprint2/logs/start.log 2>&1
```

Notes:

- `@reboot` fires once when cron starts, early in boot -- which is exactly why
  the NTP wait above matters, since the clock may not be set yet at that point.
  `platforms/pi/start.sh` starts the `timesync` loop first for this reason.
- It runs `airmon-ng check kill` first, stopping NetworkManager and wpa_supplicant
  so they cannot pull the card back out of monitor mode -- one reason a bare
  capture is flaky until airodump-ng has "held" the interface. (The rt2800usb
  driver needs more than this; see *Priming the radio* below.)
- It starts **two** named screens: `timesync`, `capture`. Re-running the script
  will not stack duplicates. (`analysis` and `display` are intentionally absent on
  the Pi -- run them off-node.)
- Confirm the crontab with `sudo crontab -l`; watch boot with
  `tail -f logs/start.log`; list the screens with `screen -ls`.

### Watching the display over the node's own AP

The node also runs **hostapd**, so it broadcasts its own Wi-Fi access point (the
one you configure in `hostapd.conf` per the main README's Pi build). An operator
joins that AP, SSHes to the node, and attaches to the live heads-up display:

```bash
ssh pi@192.168.1.1
screen -r display          # detach again with Ctrl-A then D, capture keeps running
```

No wired connection and no separate laptop running the analysis -- the board
captures, enriches, and shows the dossier by itself, and the operator just views
it. Note the capture radio (monitor mode) and the hostapd AP must be **different
interfaces**: one card cannot serve an AP and sniff in monitor mode at once.

The full configuration for that AP — `hostapd.conf`, the static `wlan0` address
(`192.168.1.1/24`; clients are statically addressed, there is no DHCP), and the
optional laptop uplink (`usb0`, `10.0.0.0/24`) NATed out for the clients — is in
**[NETWORKING.md](./NETWORKING.md)**.

The older `script.sh` / `start_cap.sh` pair in this directory did a subset of
this by hand (a detached `screen` running `start_cap.sh`, which ran
`airmon-ng start` then the capture -- no analysis or display). `start.sh`
supersedes them: it reads `INF` / `CAPTURE_PHYS` from `.env`, works for a
multi-radio node, and runs all three jobs. The old scripts are kept for
reference.

## Priming the radio (rt2800usb and similar)

On some USB Wi-Fi chipsets -- **rt2800usb** (many Ralink/MediaTek adapters) is
the one seen here -- putting the interface in monitor mode and bringing it up is
**not enough to actually receive frames**. `tshark` sits there capturing nothing
until something *tunes* the radio: sets a channel and kicks it into RX. Running
`airodump-ng` does exactly that as a side effect, which is why capture appeared
to "only work after airodump-ng was run" even with the interface in monitor mode
and up.

The fix is to tune the channel explicitly rather than rely on airodump-ng:

```bash
iw dev wlan1mon set channel 6
```

`build_ssid.sh` already does this per interface when `INF` names a channel
(`INF="wlan1mon:6"`), which primes an rt2800usb adapter without needing
airodump-ng at all. **So on these chipsets, always give `INF` a channel.** If a
particular adapter still refuses to deliver frames, keep an `airodump-ng`
holding the radio in the background -- that is what `start_ad.sh` is for:

```bash
airodump-ng wlan1mon        # leave running; it holds the radio in RX
```

Prefer the explicit `iw ... set channel` path; the airodump-ng hold is the
fallback for stubborn drivers.

## Configuration

`start.sh` reads from `.env` (see `../../.env.example`):

- `INF` -- the monitor interface(s) to capture on. **On rt2800usb, always
  include a channel** (`wlan1mon:6`) so the radio is primed; a bare `wlan1mon`
  may capture nothing. A list like `wlan1mon:1 wlan2mon:6` works for a
  multi-radio node.
- `CAPTURE_PHYS` -- the physical interface(s) to switch into monitor mode first.
  Optional; defaults to each `INF` name with a trailing `mon` removed
  (`wlan1mon` -> `wlan1`).
- `ANALYSIS_INTERVAL` -- seconds `start.sh` sleeps between `analysis.sh` sweeps
  in the analysis screen. Optional; default 60.
