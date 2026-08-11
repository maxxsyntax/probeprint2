# bettercap capture platform

`probeprint.cap` is a [bettercap](https://www.bettercap.org/) caplet -- a config
file, not a packet capture despite the `.cap` extension. It turns on Wi-Fi and
BLE recon and filters the event stream down to what probeprint2 cares about.

It is an **alternative capture front end**, separate from `capture.sh`. Nothing
in the pipeline reads it; bettercap does, and you scrape bettercap's event
stream into the database yourself.

Install it where bettercap looks for caplets:

- Debian: `/usr/local/share/bettercap/caplets/probeprint.cap`
- Kali:   `/usr/share/bettercap/caplets/probeprint.cap`

Then run `bettercap -caplet probeprint.cap`.
