# wifi — Xymon **server** configuration

The extension sends a `data` message with one `NAME : VALUE` line per
metric (`clients_phy0_ap0 : 5`, `busy_phy0 : 20.0`, …). The Xymon
server turns those into RRD files and graphs via **split-NCV**. This
is a one-time setup on the Xymon server host.

## 1. xymonserver.cfg

All wifi metrics are plain gauges (the extension computes the rates
itself, so no COUNTER/DERIVE handling is needed). Append:

```
TEST2RRD+=",wifi=ncv"
SPLITNCV_wifi="*:GAUGE"
```

Note the leading comma: `+=` concatenates verbatim and does not
insert a separator.

To make the graphs appear on the trends column and on the `wifi`
status page, also extend:

```
GRAPHS+=",wificlients,wifiutil,wifikbps,wifiair,wifierr,wifinoise,wifichan"
GRAPHS_wifi="wificlients,wifiutil,wifikbps,wifiair,wifierr,wifinoise,wifichan"
```

## 2. graphs.cfg

Include the graph definitions shipped in this directory:

```
include /etc/xymon/graphs.d/wifi.cfg
```

or append the contents of `wifi.cfg` to your `graphs.cfg`.

## 3. Restart / verify

Restart the Xymon server (or `xymon @ "rotate"` plus a xymond_rrd
restart). After the second poll (the first one only primes the rate
calculation), check that RRD files appear:

```
ls $XYMONVAR/rrd/<ap-host>/wifi,*
```

The number of RRD files varies with the host's radios and SSIDs —
that is expected; the FNPATTERNs in `wifi.cfg` pick up
whatever exists.

## Alerting

The column is purely informational and never turns yellow/red, so no
`alerts.cfg` entry is needed. Watch the graphs instead (channel busy
percent and airtime are the interesting ones for capacity planning).
