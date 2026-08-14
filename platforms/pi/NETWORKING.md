# Pi field networking

How each field Pi gets on the network, gets its clock synced, and becomes
reachable from the phone so an operator can SSH in and run `display.sh`. The
engagement runs more than one Pi, so the scheme scales to several -- each node
lands on its own tunnel port.

Companion files in this directory:

- `hotspot.interfaces` -> `/etc/network/interfaces.d/wlan0` (join the hotspot)
- `net_up.sh` -> `/usr/local/sbin/net_up.sh` (sync clock + reverse tunnel)

## The setup, and why it looks like this

The field devices:

- **probeprint Pi** -- Wi-Fi probe capture. Capture is on the USB radio
  (`wlan1` -> `wlan1mon`); onboard `wlan0` is free for connectivity.
- **A second Pi** (another field sensor) -- joins exactly the same way. Its
  onboard `wlan0` carries connectivity while its capture radio stays dedicated.
- **Android phone** -- the operator's console. Runs the hotspot (its cellular
  is the only internet source) and ConnectBot to SSH the Pis.

```
              cellular ── internet
                 │
          [ Android phone ]  hotspot + gateway + NTP server
           SSID (stable)     192.168.x.1  <- x re-rolls every session
              ▲     ▲
        wlan0 │     │ wlan0
    ┌─────────┴─┐ ┌─┴──────────┐
    │ probeprint│ │  second    │
    │  Pi       │ │   Pi       │
    │ wlan1mon  │ │ (another   │
    │ (capture) │ │  sensor)   │
    └───────────┘ └────────────┘
   reverse tunnel  reverse tunnel
   -> phone :2222  -> phone :2223
```

Two facts drive every design choice:

1. **The phone must be the hotspot.** Only the phone has internet (cellular),
   and a phone's Wi-Fi radio can be a hotspot *or* a station, never both. So
   the phone hosts; the Pis join as stations.
2. **The phone re-rolls its hotspot subnet on every toggle** (`192.168.x.1`,
   `x` changes each time). So no static Pi IP is stable, and the phone's UI
   will not show you the Pis' addresses.

The way out is an **asymmetry**: whatever subnet the phone picks, the phone is
always the Pi's **default gateway**. The Pi can always find the phone even
though the phone cannot find the Pi. So the Pi dials *out* to the phone and
opens a **reverse SSH tunnel** back to its own `sshd`. ConnectBot then connects
to **`127.0.0.1`** on the phone -- an address that never changes -- and lands on
the Pi.

This path also survives **hotspot AP-isolation** (many phones block
client-to-client traffic): the tunnel only ever talks to the gateway, which is
always allowed. And it works with **no cellular signal**, since both ends are on
the phone's local hotspot LAN -- keeping the offline-first stance intact.

## Pi setup (do on BOTH Pis)

```bash
# packages
sudo apt install ifupdown wpasupplicant autossh ntpdate

# a key for the pi user, if there isn't one already
sudo -u pi ssh-keygen -t ed25519 -N '' -f /home/pi/.ssh/id_ed25519

# drop the two config files in place
sudo cp hotspot.interfaces /etc/network/interfaces.d/wlan0
sudo cp net_up.sh          /usr/local/sbin/net_up.sh
sudo chmod +x              /usr/local/sbin/net_up.sh

# make sure the main interfaces file pulls in interfaces.d/
grep -q interfaces.d /etc/network/interfaces || \
  echo 'source /etc/network/interfaces.d/*' | sudo tee -a /etc/network/interfaces
```

Then edit two things:

- In `/etc/network/interfaces.d/wlan0`: set `wpa-ssid` / `wpa-psk` to your
  hotspot. Pre-hash the PSK if you don't want it in the clear:
  `wpa_passphrase "YourHotspot" | grep -w psk` and use the hex value. Then
  `sudo chmod 600 /etc/network/interfaces.d/wlan0`.
- In `/usr/local/sbin/net_up.sh`: set `PHONE_USER` to the Termux `whoami`
  value (below), and confirm `PHONE_PORT` (8022) matches Termux.

**Per-Pi tunnel port.** `net_up.sh` picks the phone-side port from the
hostname so the two tunnels don't collide:

| Pi | hostname matches | ConnectBot target |
|---|---|---|
| probeprint | `*probe*` / `*print*` | `127.0.0.1:2222` |
| second Pi | its own hostname (add a `case`) | `127.0.0.1:2223` |

The `case` in `net_up.sh` maps hostname to port; add a branch for each node so
no two share a port. If your Pis are named otherwise they will all fall through
to 2222 -- fix the globs, or set a matching hostname with
`sudo hostnamectl set-hostname probeprint`.

**Raspberry Pi OS Bookworm caveat.** Bookworm's default `wlan0` is owned by
NetworkManager, which will fight ifupdown. Either
`sudo systemctl disable --now NetworkManager`, or mark `wlan0` unmanaged in
`/etc/NetworkManager/conf.d/`. Bullseye and earlier (dhcpcd/ifupdown) need no
such step.

Copy each Pi's `id_ed25519.pub` to the phone (next section) before expecting the
tunnel to authenticate.

## Phone setup (Termux)

Termux is the SSH *server* the Pis dial into, and the host ConnectBot tunnels
through.

1. **Install from F-Droid** (not the Play Store build -- it's deprecated and its
   add-ons are signed differently):
   - **Termux** -- the terminal.
   - **Termux:Boot** -- a separate add-on app that runs a script at phone boot,
     so `sshd` comes back after a reboot without you opening Termux.
   - **ConnectBot** -- the SSH client you actually type in (any store is fine).

2. In Termux, install and identify:
   ```bash
   pkg update && pkg install openssh
   whoami        # -> e.g. u0_a123   (this is PHONE_USER in net_up.sh)
   ```

3. Authorize each Pi's key so the Pis can open their reverse tunnels. Paste both
   Pis' `id_ed25519.pub` contents in:
   ```bash
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   cat >> ~/.ssh/authorized_keys   # paste each pub line, then Ctrl-D
   chmod 600 ~/.ssh/authorized_keys
   ```

4. Start the server (listens on **8022**):
   ```bash
   sshd
   ```

5. Autostart it on boot with Termux:Boot:
   ```bash
   mkdir -p ~/.termux/boot
   cat > ~/.termux/boot/start-sshd <<'EOF'
   #!/data/data/com.termux/files/usr/bin/sh
   termux-wake-lock
   sshd
   EOF
   chmod +x ~/.termux/boot/start-sshd
   ```
   Open the **Termux:Boot** app once so Android grants it run-at-boot
   permission, and exempt Termux from battery optimization or the OS will kill
   the background `sshd`. `termux-wake-lock` keeps the CPU awake so the tunnel
   stays reachable.

If you'd rather not install Termux:Boot, just open Termux and type `sshd` by
hand after each phone reboot.

## Phone as NTP server

The Pis step their clocks off the phone (`ntpdate -u $GW`) each time `wlan0`
comes up. Accurate, common time across the nodes is what lets sightings from
different Pis line up on one timeline, so this is not cosmetic.

For the phone to answer NTP it needs a time server listening on UDP 123. Options:

- **Simplest:** an NTP-server app from F-Droid (e.g. a "local NTP server" /
  "SNTP server" app), left running. The Pis query the phone at the gateway
  address automatically.
- **Termux:** run an NTP daemon there if you prefer to keep everything in
  Termux (`pkg install ntp` / `chrony` depending on availability) bound to the
  hotspot interface.

If no NTP server is reachable, `net_up.sh` logs that it skipped the sync and
carries on -- the tunnel still comes up, the clocks just drift. When back on real
internet the Pis resync normally.

### How this relates to `timesync.sh`

The node already has an authoritative clock corrector:
`analysis-scripts/timesync.sh --loop`, started by `start.sh`, is the mechanism
the README's *"Time is load-bearing"* section is about. `net_up.sh`'s step does
not replace it -- it covers the one case `timesync.sh` structurally cannot.

- **`timesync.sh` is the ongoing corrector, but it is gated on *internet*.** It
  only syncs when `test_online` succeeds, and it syncs against public
  `NTP_SERVERS` (`pool.ntp.org`, `time.cloudflare.com`, `time.google.com`).
  Reachable only when the phone has cellular. With **no signal**, `test_online`
  is false and `timesync.sh` deliberately leaves the clock alone -- it has no
  reference it trusts.
- **`net_up.sh` is the field bridge for exactly that offline case.** When the
  phone is the hotspot, the phone itself is a LAN-local NTP server at the
  gateway, reachable with no cellular at all. `timesync.sh`'s static
  `NTP_SERVERS` cannot name it because the gateway is re-rolled every session --
  but `net_up.sh` reads the current gateway, so it is the one place that *can*
  point NTP at the phone. It does a one-shot step the moment `wlan0` comes up.

They do not fight: one is a single step at network-up, the other a loop; both
use `ntpdate -u` (an unprivileged port, so no contention with each other or with
`systemd-timesyncd`). If the phone *does* have cellular, `timesync.sh` will
additionally re-correct against public NTP at a better stratum -- harmless.

If you would rather have one mechanism, set **`NTP_SERVERS` in `.env` to the
phone** and let `timesync.sh` do the work -- but only if your phone's gateway is
stable, which here it is not. Because the subnet re-rolls, keep `net_up.sh` as
the thing that resolves the phone's address per session.

**One caveat if you use the strict capture gate.** The README suggests blocking
capture until `timedatectl show -p NTPSynchronized` reads `yes`. A plain
`ntpdate`/`sntp` step -- what both `net_up.sh` and `timesync.sh` do -- sets the
clock but does **not** flip that flag, which only `systemd-timesyncd` owns. In
the offline phone-hotspot case `timesyncd` never reaches a server, so that gate
would block capture forever. There, gate on a *plausible clock* (e.g. year >=
2024) or on `timesync.sh` having logged a successful step, not on
`NTPSynchronized`.

## Daily use

1. Phone: turn the hotspot on. Confirm Termux `sshd` is running (Termux:Boot
   handles this after a reboot).
2. Power the Pis. On `wlan0` up they join the hotspot, step their clocks, and
   open their reverse tunnels -- no operator action.
3. Phone: ConnectBot to the fixed local address:
   - probeprint Pi: `pi@127.0.0.1` port **2222** -> run `./display.sh`
   - second Pi: `pi@127.0.0.1` port **2223**
   Save each as a ConnectBot host; the target never changes between sessions.

## Troubleshooting

- **Tunnel never appears.** On the Pi: `cat /home/pi/net_up.log`. It records the
  detected gateway, the clock step, and the autossh line. No default gateway =
  the hotspot join failed (SSID/PSK, or NetworkManager still owns `wlan0`).
- **ConnectBot: "connection refused" on 2222/2223.** Termux `sshd` isn't
  running, or the Pi's key isn't in Termux `authorized_keys`, so autossh can't
  establish the outer session and the reverse listener never opens.
- **Auth fails from the Pi.** The Pi dials as `PHONE_USER@gateway` with
  `-i /home/pi/.ssh/id_ed25519`. Confirm `PHONE_USER` matches Termux `whoami`
  and that pub key is in `~/.ssh/authorized_keys` on the phone.
- **Time didn't sync.** No NTP server on the phone, or UDP 123 blocked. See the
  log line from `net_up.sh`; install/enable a phone NTP server.
- **Both Pis land on the same port.** Hostnames don't match the `case` globs in
  `net_up.sh`. Rename the Pis or fix the globs.

## Known limits

- **Pi <-> Pi traffic.** Under hotspot AP-isolation the two Pis cannot talk to
  each other directly (only Pi <-> phone works). If a second Pi ever needs to
  reach probeprint's database on the first Pi over the network, this topology
  won't carry it -- you'd need a Pi-hosted AP (USB-tether the phone to one Pi
  for internet, that Pi runs hostapd+dnsmasq+NAT, both Pis and the phone join
  it). That trades a cable for full IP control and Pi <-> Pi reachability.
- **Reconnection.** `autossh` keeps a session alive, and `post-up` re-runs on
  every `wlan0` up. If you want harder reconnection guarantees, move the tunnel
  into a `systemd` service with `Restart=always` instead of the backgrounded
  `post-up`.
