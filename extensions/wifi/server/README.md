# wifi — Xymon **server** configuration

The extension sends a `data` message with one `NAME : VALUE` line per
metric (`clients_phy0_ap0 : 5`, `busy_phy0 : 20.0`, …). The Xymon
server turns those into RRD files and graphs via **split-NCV**. This
is a one-time setup on the Xymon server host.

Both steps are **drop-in files**: nothing in a stock Xymon config file
has to be edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform (Debian/Ubuntu ship them ready to use).

## 1. xymonserver.d/my-xymon-extensions-wifi.cfg

Copy the snippet shipped next to this README into the server's
drop-in directory:

```sh
cp xymonserver.d/my-xymon-extensions-wifi.cfg /etc/xymon/xymonserver.d/
```

All wifi metrics are plain gauges (the extension computes the rates
itself, so no COUNTER/DERIVE handling is needed):

```
TEST2RRD+=",wifi=ncv"
SPLITNCV_wifi="*:GAUGE"
GRAPHS+=",wificlients,wifiutil,…"
GRAPHS_wifi="wificlients,wifiutil,wifikbps,wifiair,wifierr,wifinoise,wifichan"
```

## 2. graphs.d/my-xymon-extensions-wifi.cfg

Copy the graph definitions shipped next to this README:

```sh
cp graphs.d/my-xymon-extensions-wifi.cfg /etc/xymon/graphs.d/
```

## 3. Restart / verify

Restart the Xymon server (a restart, not a reload — on Debian/Ubuntu
the list of included drop-in files is regenerated at start). After the
second poll (the first one only primes the rate calculation), check
that RRD files appear:

```
ls $XYMONVAR/rrd/<ap-host>/wifi,*
```

The number of RRD files varies with the host's radios and SSIDs —
that is expected; the FNPATTERNs in `graphs.d/my-xymon-extensions-wifi.cfg` pick up
whatever exists.

## Alerting

The column is purely informational and never turns yellow/red, so no
`alerts.cfg` entry is needed. Watch the graphs instead (channel busy
percent and airtime are the interesting ones for capacity planning).
