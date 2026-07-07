# diskio — Xymon **server** configuration

The client extension sends a `data` message with one `NAME : VALUE`
line per instance and metric (`pd_sda_rbps : 1048576`,
`md_md0_rlat : 4.20`, …). The Xymon server turns those into RRD files
and graphs via **split-NCV**. This is a one-time setup on the Xymon
server host (which may run any OS — these are plain Xymon config
changes).

## 1. xymonserver.cfg

Append the `diskio` test to `TEST2RRD` and define a split-NCV rule
(in `xymonserver.cfg`, usually `/etc/xymon/` on Debian/Ubuntu,
`$XYMONHOME/etc/` elsewhere):

```
TEST2RRD="...existing list...,diskio=ncv"
SPLITNCV_diskio="*:GAUGE"
```

`SPLITNCV_diskio` (as opposed to `NCV_diskio`) makes xymond_rrd create
**one RRD file per variable**, named `diskio,<instance>_<metric>.rrd`,
each containing a single dataset named `lambda`. That is what allows
an arbitrary, per-host varying number of disks and volumes. The client
sends ready-made interval averages, so plain `GAUGE` is correct — no
DERIVE/COUNTER needed. See `man xymond_rrd` (section NCV) if your
Xymon version behaves differently.

To make the graphs appear on the trends column and on the `diskio`
status page, also extend:

```
GRAPHS="...existing list...,diskiorbps,diskiowbps,diskioriops,diskiowiops,diskiorlat,diskiowlat,diskioutil,diskioqlen"
GRAPHS_diskio="diskiorbps,diskiowbps,diskiorlat,diskiowlat"
```

(`GRAPHS_diskio` is the selection shown on the status page itself —
pick the ones you care about.)

## 2. graphs.cfg

Include the graph definitions shipped in this directory:

```
include /etc/xymon/graphs.d/graphs-diskio.cfg
```

or append the contents of `graphs-diskio.cfg` to your `graphs.cfg`.

## 3. Restart / verify

Restart the Xymon server (or `xymon @ "rotate"` plus a xymond_rrd
restart). After the next client report, check that RRD files appear:

```
ls $XYMONVAR/rrd/<clienthost>/diskio,*
```

Then the graphs show up on the host's trends page. Note that on the
very first client run only a baseline is stored (Linux) — RRD files
appear from the second run onward.

## Alerting

If you enable `threshold` lines in the client's `diskio.cfg`, the
`diskio` column goes yellow/red on violations, so a normal
`alerts.cfg` rule matching `TEST=diskio` is enough, e.g.:

```
HOST=* TEST=diskio
    MAIL admin@example.com COLOR=red REPEAT=4h
```

Without thresholds the column never alerts (pure trending).
