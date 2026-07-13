# fritzwan — Xymon **server** configuration

The extension sends a `data` message with one `NAME : VALUE` line per
metric (`bps_down : 20000000`, `util_up : 5.0`, …). The Xymon server
turns those into RRD files and graphs via **split-NCV**. This is a
one-time setup on the Xymon server host.

## 1. xymonserver.cfg

All fritzwan metrics are plain gauges (the extension computes the
throughput itself, so no COUNTER/DERIVE handling is needed). Append:

```
TEST2RRD+=",fritzwan=ncv"
SPLITNCV_fritzwan="*:GAUGE"
```

Note the leading comma: `+=` concatenates verbatim and does not
insert a separator.

To make the graphs appear on the trends column and on the `fritzwan`
status page, also extend:

```
GRAPHS+=",fritzwanbps,fritzwanutil"
GRAPHS_fritzwan="fritzwanbps,fritzwanutil"
```

## 2. graphs.cfg

Include the graph definitions shipped in this directory:

```
include /etc/xymon/graphs.d/fritzwan.cfg
```

or append the contents of `fritzwan.cfg` to your `graphs.cfg`.

## 3. Restart / verify

Restart the Xymon server (or `xymon @ "rotate"` plus a xymond_rrd
restart). After the second poll (the first one only primes the rate
calculation), check that RRD files appear:

```
ls $XYMONVAR/rrd/<fritzbox-host>/fritzwan,*
```

## Alerting

The column goes red when the physical WAN link is down; utilization
alerting is opt-in via `UTIL_WARN`/`UTIL_CRIT` in `fritzwan.cfg`. A
normal `alerts.cfg` rule is enough, e.g.:

```
HOST=fritz.box TEST=fritzwan
    MAIL admin@example.com COLOR=red REPEAT=4h
```
