#!/usr/bin/bash
# net_up.sh -- sync the clock to the phone (acting as NTP server) and open a
# reverse SSH tunnel back to this Pi, so ConnectBot on the phone can reach us at
# the phone's own localhost regardless of what hotspot subnet got rolled.
#
# Triggered from /etc/network/interfaces.d/wlan0 post-up, so it re-runs every
# time wlan0 comes up and always uses the current gateway (= the phone).
# Runs as root (ifupdown post-up does), which is what lets it set the clock;
# the SSH side is pinned to the pi user's key with -i so root can still auth.
#
# The two Pis must use different remote ports on the phone so both tunnels can
# live at once; that is keyed off the hostname below. ConnectBot then connects
# to 127.0.0.1:<port> and lands on the matching Pi.

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u

# --- config -----------------------------------------------------------------
PHONE_USER="u0_a123"        # Termux `whoami` on the phone
PHONE_PORT=8022             # Termux sshd default
SSH_KEY=/home/pi/.ssh/id_ed25519
KNOWN_HOSTS=/home/pi/.ssh/known_hosts

# Per-Pi remote port on the phone. Add a branch for each node so no two Pis
# share a port; match on hostname (set with `hostnamectl set-hostname`).
case "$(hostname)" in
    *probe*|*print*) REMOTE_PORT=2222 ;;   # probeprint Pi -> ConnectBot 127.0.0.1:2222
    *pi2*|*node2*)   REMOTE_PORT=2223 ;;   # second Pi     -> ConnectBot 127.0.0.1:2223
    *)               REMOTE_PORT=2222 ;;
esac

log() { echo "net_up $(date +'%F %H:%M:%S') $*"; }

# --- 1. wait for a lease + default gateway (the phone) -----------------------
GW=""
for _ in $(seq 1 30); do
    GW=$(ip route | awk '/^default/{print $3; exit}')
    [ -n "$GW" ] && break
    sleep 2
done
if [ -z "$GW" ]; then
    log "no default gateway on wlan0 after 60s, giving up"
    exit 1
fi
log "gateway (phone) = $GW  remote_port = $REMOTE_PORT"

# --- 2. sync the clock to the phone -----------------------------------------
# A one-shot step, because the phone's address changes every session so a
# standing NTP daemon config cannot hold it. Accurate common time across both
# Pis is what makes cross-radio timing/RSSI correlation line up. -u on ntpdate
# uses an unprivileged port so it never fights systemd-timesyncd for 123.
if command -v ntpdate >/dev/null 2>&1; then
    ntpdate -u "$GW" && log "clock stepped via ntpdate -> $(date +'%F %H:%M:%S')"
elif command -v sntp >/dev/null 2>&1; then
    sntp -sS "$GW"   && log "clock stepped via sntp -> $(date +'%F %H:%M:%S')"
elif command -v chronyd >/dev/null 2>&1; then
    chronyd -q "server $GW iburst" && log "clock stepped via chronyd -q -> $(date +'%F %H:%M:%S')"
else
    log "no ntpdate/sntp/chronyd found -- skipping time sync (apt install ntpdate)"
fi

# --- 3. reverse tunnel, kept alive by autossh -------------------------------
# -R <REMOTE_PORT>:localhost:22 opens a listener on the phone that forwards back
# to this Pi's sshd. We only ever dial the gateway, which always works even
# under hotspot AP-isolation. autossh replaces us in the process table.
log "opening reverse tunnel ${PHONE_USER}@${GW}:${PHONE_PORT} -> :${REMOTE_PORT}"
exec autossh -M 0 -N \
    -i "$SSH_KEY" \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o StrictHostKeyChecking=accept-new \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -R "${REMOTE_PORT}:localhost:22" \
    -p "$PHONE_PORT" \
    "${PHONE_USER}@${GW}"
