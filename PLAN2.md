# fritz-wifi server test - approved implementation plan

## Scope and environment

A server-side POSIX sh collector `fritz-wifi` (Xymon server task via
tasks.d, like powerline) that polls AVM FRITZ! devices over TR-064 and
reports into the existing `wifi` column, filling the same RRD files as the
OpenWrt access points. Reference device: FRITZ!Powerline 1260E, firmware
157.08.25, TR-064 on HTTP port 49000. Other models are not excluded, but
not tested. Branch `claude/fritz-wifi-test`, based on current main.
Server package only (my-xymon-extensions-server, Debian/Ubuntu).

## Findings the design rests on

- The powerline collector talks HomePlug over raw Ethernet; it has no
  passwords and its powerline.map is a PLC-MAC -> host mapping. There is
  no shared password map; fritz-wifi introduces one.
- wifi RRDs are split-NCV files `wifi,<name>.rrd` with the single DS
  `lambda` (`DS:lambda:GAUGE:600:U:U`, xymond/rrd/do_ncv.c with
  `SPLITNCV_wifi="*:GAUGE"`).
- NCV drops "U" silently; `data HOST.trends` passes it to rrdupdate
  unchanged (do_trends.c). fritz-wifi therefore writes the same files via
  native trends messages, like powerline.
- xymond_rrd feeds status messages of an `ncv` test into the NCV parser as
  well, which accepts ":" and "=". The wifi status text therefore created
  stray RRDs (confirmed on the production server: `wifi,phy0_channel.rrd`,
  `wifi,phy1_channel.rrd`, `wifi,rx.rrd`). Xymon 4.3.30 supports
  `<!-- ncv_skipstart -->` / `<!-- ncv_skipend -->` (strings of the
  installed xymond_rrd); both wifi.sh and fritz-wifi wrap their detail text
  in it. The RRD schema does not change.
- ap-garage still runs a wifi.sh from before 60f8552 (BusyBox tr bug), so
  its RRDs are named `why0_aw0` instead of `phy0_ap0`. The wifi server
  README documents a one-time rename that keeps the history.

## Decisions

- Hosts: hosts.cfg tag `fritzwifi`, read through xymoncfg (includes
  resolved). Connect to the hosts.cfg IP, or the name for 0.0.0.0.
  `--host` overrides the list for manual runs. Hosts are polled one after
  another.
- Password file `ETCDIR/my-xymon-extensions-server/fritz.passwd`, not
  installed by the package (example in the docs). Three columns:
  `host_or_ip user password...`; the password is the rest of the line,
  trimmed; `-` as user means the default `xymon`. Blank and `#` lines are
  ignored. Parsed, never sourced. Must be a regular file owned by the
  running user without any group/other permission, else it is rejected.
  Added in 0.24.1 (fritz-wifi.sh 1.1.0): a root-owned file that only
  the running user's primary group may read (root:xymon 640) is accepted
  as well.
- Password precedence: `--ask-password` (tty, echo off via stty) >
  `FRITZPASSWORT` > password file. User precedence: `FRITZ_WIFI_USER`
  (CLI/env/config) > file column > `xymon`.
- Credentials reach curl only on stdin (`--config -`, `"` and `\`
  escaped); never argv, logs, debug or dry-run output. `--digest` (the
  device answers with a Digest MD5 qop=auth challenge).
- Only GetInfo, GetTotalAssociations and GetGenericAssociatedDeviceInfo
  are ever sent; anything else (GetSecurityKeys in particular) is refused
  by the SOAP function. DeviceInfo, host list, mesh list and the WLAN
  device list (SID) are not used.
- Instances come from /tr64desc.xml; the band from
  NewX_AVM-DE_FrequencyBand at runtime. Disabled instances (Enable 0 or
  Status Disabled) are ignored completely.
- Names: radio `wl2g`/`wl5g`/`wl6g` by band, interface
  `<radio>-ap<instance>` (metric suffix `wl2g_ap1`).
- Metrics: `clients_<if>`, `clients_total`, `channel_<radio>`. Metrics
  TR-064 does not provide are not created at all; throughput is a stub
  (`traffic_kbps`) for later. 0 clients is a value; any failure writes U
  to the names of the last clean run (state file, names only).
- Channel width only from associated clients (widest), n/a otherwise, no
  state. Frequency from the channel number (Linux
  ieee80211_channel_to_freq_khz).
- Colors: red unreachable; yellow for 401/606, missing or rejected
  password, TR-064 protocol errors and an enabled network not Up; clear
  without curl, without WLAN service or with every network disabled.
- Configuration follows the repository convention (powerline): `--config`
  file in the server config directory, CLI > environment > config >
  defaults, silent/verbose, dry-run, debug (raw responses, SIDs masked),
  logger tag `fritz-wifi`, flock, status lifetime 15 minutes.
- Tests replay the recorded device responses through a fake curl.

## Implementation status (2026-09-23)

Implemented in 0.24.0 (fritz-wifi.sh 1.0.0), together with the ncv_skip
fix for wifi.sh and the migration notes in extensions/wifi/server/README.md.

Validated:
- make test (ShellCheck 0.9.0, dash): passed, including 140 fritz-wifi
  assertions (recorded device responses through a fake curl).
- tests/fritz-wifi/run.sh under bash, bash --posix and BusyBox sh with the
  BusyBox userland; the full suite under BusyBox: passed.
- --ask-password through a pseudo terminal (script(1)): no echo, a
  password with blanks, a double quote and a backslash accepted, echo
  restored afterwards.
- make deb, make deb-server, make opkg: passed; client and server package
  installed side by side without a shared file.

Not validated: no real FRITZ! device, Xymon server or RRD file was
involved. The per-client responses (GetGenericAssociatedDeviceInfo with a
connected client) are synthesized, and `curl --digest` (instead of the
measured `--anyauth`) is untested against the device - both are the first
checks of a real `--dry-run --debug`.

First real device run (0.24.1): `curl --digest` failed on every SOAP call
with HTTP 500 / UPnP error 502. With a single method curl sends its first,
unauthenticated POST with an empty body as a probe (curl lib/http.c), which
the device rejects as an XML error instead of answering with the 401
challenge. fritz-wifi.sh 1.2.0 calls curl with `--digest --ntlm`: curl then
sends the full body first and picks Digest from the challenge, while Basic
(what `--anyauth` could fall back to) is never allowed. Reproduced and
verified against a local test server with curl 8.5.0; the device run is
pending.
