# smart — Xymon **server** configuration

The client extension sends a `data` message with one `NAME : VALUE`
line per disk and metric (`sda_temp : 38`, `nvme0_wear : 3`, …).
The Xymon server turns those into RRD files and graphs via
**split-NCV**. This is a one-time setup on the Xymon server host
(which may run any OS — these are plain Xymon config changes).

## 1. xymonserver.cfg

Append the `smart` test to `TEST2RRD` and define a split-NCV rule
(in `xymonserver.cfg`, usually `/etc/xymon/` on Debian/Ubuntu,
`$XYMONHOME/etc/` elsewhere). Xymon's config files support appending
to an already-defined variable with `NAME+="value"`, so there is no
need to edit the existing `TEST2RRD` line — just add these lines at
the end of the file (or in a local include):

```
TEST2RRD+=",smart=ncv"
SPLITNCV_smart="*:GAUGE"
```

Note the leading comma: `+=` concatenates verbatim and does not
insert a separator.

`SPLITNCV_smart` (as opposed to `NCV_smart`) makes xymond_rrd create
**one RRD file per variable**, named `smart,<disk>_<metric>.rrd`, each
containing a single dataset named `lambda`. That is what allows an
arbitrary, per-host varying number of disks. See `man xymond_rrd`
(section NCV) if your Xymon version behaves differently.

To make the graphs appear on the trends column and on the `smart`
status page, also extend:

```
GRAPHS+=",smarttemp,smartwear,smartspare,smartrealloc,smartpending,smartuncorr,smartcrc,smartmediaerr,smarthours,smartwritten,smartread"
GRAPHS_smart="smarttemp,smartwear,smartrealloc,smartpending,smartcrc"
```

(`GRAPHS_smart` is the selection shown on the status page itself —
pick the ones you care about.)

## 2. graphs.cfg

Include the graph definitions shipped in this directory:

```
include /etc/xymon/graphs.d/smart.cfg
```

or append the contents of `graphs.d/smart.cfg` to your `graphs.cfg`.

## 3. Restart / verify

Restart the Xymon server (or `xymon @ "rotate"` plus a xymond_rrd
restart). After the next client report, check that RRD files appear:

```
ls $XYMONVAR/rrd/<clienthost>/smart,*
```

Then the graphs show up on the host's trends page.

## Alerting

Alerting needs no extra setup: the `smart` column goes yellow/red on
threshold violations and SMART health failures, so a normal
`alerts.cfg` rule matching `TEST=smart` is enough, e.g.:

```
HOST=* TEST=smart
    MAIL admin@example.com COLOR=red REPEAT=4h
```
