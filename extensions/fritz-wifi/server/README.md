# fritz-wifi - Wi-Fi metadata of AVM FRITZ! devices via TR-064

A POSIX sh collector that runs on the Xymon **server**, polls AVM FRITZ!
devices over TR-064 and reports their Wi-Fi metadata into the existing
`wifi` column of each device's host - laid out like the OpenWrt
[wifi extension](../../wifi/README.md) and writing the **same RRD files**
(`wifi,<name>.rrd`, data source `lambda`), so the `wifi` graphs work
unchanged.

Reference device: FRITZ!Powerline 1260E, firmware 157.08.25, TR-064 on
HTTP port 49000. Other FRITZ! models are not excluded, but untested.

It only reads: three TR-064 actions (`GetInfo`, `GetTotalAssociations`,
`GetGenericAssociatedDeviceInfo`), nothing else. The action returning the
Wi-Fi keys is refused by the collector itself. No device setting, no
hosts.cfg edit.

Server-only: shipped exclusively in my-xymon-extensions-server
(Debian/Ubuntu), disabled on installation. Requires curl, flock and the
Xymon server environment.

## What is reported

```
wifi: 2 client(s) on 2 AP interface(s)

wl2g  channel=11 (2462 MHz)  width=20 MHz (client)  busy=n/a rx=n/a tx=n/a  noise=n/a
  &green wl2g-ap1  ssid="Steingasse"  clients=1 [tr064]  txpower=n/a
         rx=n/a tx=n/a kbit/s  airtime rx=n/a tx=n/a  retries=n/a failed=n/a
         standard=n  signal min/avg=92/92 (0-100)  speed min/avg=144/144 Mbit/s
wl5g  channel=116 (5580 MHz)  width=80 MHz (client)  busy=n/a rx=n/a tx=n/a  noise=n/a
  &green wl5g-ap2  ssid="Steingasse-5G"  clients=1 [tr064]  txpower=n/a
         ...
```

- **Names**: one "radio" per band - `wl2g`, `wl5g`, `wl6g` from
  `X_AVM-DE_FrequencyBand`, read at runtime (never a fixed instance ->
  band mapping) - and one interface per TR-064 WLANConfiguration instance,
  `<radio>-ap<instance>`, in the style of OpenWrt's `phyN-apM`. An enabled
  instance on an unknown band becomes `wlan<N>` / `wlan<N>-ap<N>`.
- **Disabled networks** (`NewEnable` 0 or `NewStatus` Disabled, e.g. the
  guest access) are ignored completely: no line, no RRD, not counted.
- **Frequency** is computed from the channel number the way Linux'
  `ieee80211_channel_to_freq_khz()` does (2.4 GHz: 2407 + 5 * channel,
  channel 14 = 2484; 5 GHz: 5000 + 5 * channel; 6 GHz: 5950 + 5 *
  channel).
- **Channel width**: TR-064 has none for the access point, only per
  client. Shown is the widest link of the associated clients, marked
  `(client)`; without a client it is `n/a`. It may differ from the
  configured width.
- **signal** is `X_AVM-DE_SignalStrength`, a 0-100 scale - not dBm, and
  not a noise floor. **speed** is `X_AVM-DE_Speed`, presumably the PHY
  rate in Mbit/s. Both are shown as minimum/average over the clients of
  an interface; they are not graphed (yet).
- `[tr064]` marks the source, like `[hostapd]` on OpenWrt.
- Everything TR-064 does not provide is `n/a`: channel utilization,
  noise, TX power, throughput, airtime, retries. `GetStatistics` and
  `GetPacketStatistics` returned 0 on the reference device even under
  load, so there is no throughput source; the code keeps a hook for one
  (`traffic_kbps`).

The details are wrapped in `<!-- ncv_skipstart -->`/`<!-- ncv_skipend -->`
(invisible on the web page). The `wifi` column is an NCV test, and
xymond_rrd feeds its status text to the NCV parser as well - without the
markers, `channel=11` would create a stray `wifi,wl2g_channel.rrd`.

## RRD files and graphs

| Graph | RRD file | Value |
|---|---|---|
| wificlients | `wifi,clients_<if>.rrd`, `wifi,clients_total.rrd` | `GetTotalAssociations` per interface and their sum |
| wifichan | `wifi,channel_<radio>.rrd` | channel number from `GetInfo` |

Metrics TR-064 does not provide are **not created**; the graphs
`wifiutil`, `wifikbps`, `wifiair`, `wifierr` and `wifinoise` stay without
data for these hosts.

The values go out as native `data HOST.trends` messages
(`xymond/rrd/do_trends.c`) with the same data source definition split-NCV
uses for the `wifi` column (`DS:lambda:GAUGE:600:U:U`). Unlike NCV,
trends messages keep an explicit `U`: **0 clients is a value**, while an
unreachable device, a refused login or an unexpected response writes `U`
into every RRD of the host's last clean run. rrdtool would otherwise
bridge a single missing update (heartbeat 600 s) with the next value and
hide the outage. The names of the last clean run are kept in
`$XYMONVAR/fritz-wifi/<host>.names` (names only, no secrets).

Nothing has to be configured for the graphs: the `wifi` drop-ins of this
package (`xymonserver.d/wifi.cfg`, `graphs.d/wifi.cfg`) already register
`TEST2RRD wifi=ncv`, `GRAPHS_wifi` and the graph definitions, and the
FNPATTERNs match any interface name. One difference in the RRD files: a
file created by a trends message gets the RRA layout of
`rrddefinitions.cfg`'s `trends` (or default) section, not a `wifi`
section - which matters only if you defined one.

## Colors

| Situation | Color | RRD |
|---|---|---|
| All enabled networks `Up` | green | values |
| An enabled network not `Up` | yellow | U for its client count |
| Login refused (HTTP 401, UPnP 606) | yellow | U for everything |
| No password, or the password file rejected | yellow | U for everything |
| Unexpected TR-064 answer (HTTP 502/500, empty, missing NewEnable) | yellow | U for the affected value |
| Run time budget exhausted before a required request | yellow | U for values not measured |
| Device unreachable or timed out | red | U for everything |
| No WLAN service, every network disabled, curl missing | clear | - |

A wrong and an empty password look the same to the device: HTTP 401 with
an HTML body. That is recognized by the status code; the body is never
parsed. A UPnP error 713 while reading a client (it left between the
count and the query) is no error.

## Install and enable

The package installs the collector in `/usr/lib/xymon/server/ext`, the
config in `/etc/xymon/my-xymon-extensions-server/fritz-wifi.cfg` and the
task in `/etc/xymon/tasks.d/fritz-wifi.cfg`. It creates no password file
and restarts nothing.

1. **hosts.cfg**: tag every device with `fritzwifi` (the device usually
   has an entry already, e.g. for the powerline column):

   ```
   192.168.5.7   powerline3.lan   # fritzwifi
   ```

   The collector connects to that IP address, or to the host name when
   the address is `0.0.0.0`. Includes are resolved with `xymoncfg`.
   xymonnet ignores tags it does not know, so the tag starts no network
   test.

2. **Password file** `/etc/xymon/my-xymon-extensions-server/fritz.passwd`,
   owned by xymon, mode 600 (an example ships in the documentation
   directory as `fritz.passwd.example`):

   ```
   install -o xymon -g xymon -m 600 /dev/null /etc/xymon/my-xymon-extensions-server/fritz.passwd
   ```

   One line per device - host name or IP, user, password:

   ```
   # host_or_ip     user    password (rest of the line)
   powerline3.lan   -       my password here
   192.168.5.7      xymon   another_password
   ```

   - The host name is looked up first, then the IP from hosts.cfg; the
     first matching line wins (duplicates are logged).
   - `-` as user means `xymon`. `FRITZ_WIFI_USER` overrides the column
     for every device. The FRITZ!Powerline 1260E ignored the user name
     in all tests; other devices may not.
   - The password is the rest of the line: blanks, `"` and `\` are
     fine; blanks at its start and end are removed.
   - The file is read as data, never sourced. It is rejected unless it
     is a regular file owned by the running user without any group or
     other permission - the collector then turns every device yellow.

3. **Preview** as xymon, read-only (sends nothing, keeps the state):

   ```
   sudo -u xymon xymoncmd --env=/etc/xymon/xymonserver.cfg /usr/lib/xymon/server/ext/fritz-wifi.sh --config /etc/xymon/my-xymon-extensions-server/fritz-wifi.cfg --set FRITZ_WIFI_ENABLED=1 --verbose --dry-run
   ```

   Add `--debug` for the raw TR-064 responses (session IDs masked,
   credentials never printed), `--host NAME` to poll one device.

4. Set `FRITZ_WIFI_ENABLED=1` in the config. The task runs every 5
   minutes (MAXTIME 4m, status lifetime 15 minutes). Each request
   defaults to a 3-second timeout; `FRITZ_WIFI_RUN_BUDGET=180` stops
   further network requests after three minutes and reserves time to
   send status messages for the remaining hosts. Keep the budget below
   the task's MAXTIME when changing either setting. Flock prevents
   overlapping runs. Errors go to `$XYMONSERVERLOGS/fritz-wifi.log` and
   syslog (tag `fritz-wifi`). Make sure the server's tasks.cfg reads
   `tasks.d` (the package's post-install output says so if not).

Precedence: CLI > exported environment > config file > defaults. The
config is passed with `--config` and never included into
xymonserver.cfg, so changes take effect at the next run. `--help` lists
every setting.

### Manual tests with a password from the terminal

`--ask-password` reads the password with the terminal echo switched off;
`FRITZPASSWORT` in the environment does the same without a prompt. Both
win over the password file (prompt > FRITZPASSWORT > file), apply to
every polled host and skip the password file; combine them with `--host`.

```
sudo -u xymon xymoncmd --env=/etc/xymon/xymonserver.cfg /usr/lib/xymon/server/ext/fritz-wifi.sh --host powerline3.lan --ask-password --dry-run
```

## Security notes

- Passwords reach curl only on its standard input (`curl --config -`,
  with `"` and `\` escaped as curl's config syntax requires), never on
  a command line (`ps`), in a log, in the debug or dry-run output.
  `FRITZPASSWORT` is removed from the environment before curl runs.
- TR-064 runs over plain HTTP with Digest authentication (the device
  answers with a `Digest ... algorithm=MD5, qop="auth"` challenge): the
  password does not travel in clear text, the responses (SSIDs, client
  counts) do.

## Test scope

`tests/fritz-wifi/run.sh` replays responses recorded from the reference
device (masked) through a fake curl, under dash, bash and BusyBox. The
per-client responses are synthesized from the device's SCPD and values
measured by hand. No real device, Xymon server or RRD file is involved.

## References

- [TR-064 at AVM](https://avm.de/service/schnittstellen/) - WLANConfiguration SCPD
- [Native trends parser](https://github.com/xymon-monitoring/xymon/blob/master/xymond/rrd/do_trends.c),
  [NCV parser](https://github.com/xymon-monitoring/xymon/blob/master/xymond/rrd/do_ncv.c)
- [curl config file syntax](https://github.com/curl/curl/blob/master/docs/cmdline-opts/config.md)
- [Channel to frequency (Linux)](https://github.com/torvalds/linux/blob/master/net/wireless/util.c)
