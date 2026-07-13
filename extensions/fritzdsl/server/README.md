# fritzdsl — Xymon **server** configuration

The extension sends a `data` message with one `NAME : VALUE` line per
metric (`margin_down : 6.5`, `crc : 56`, …). The Xymon server turns
those into RRD files and graphs via **split-NCV**. This is a one-time
setup on the Xymon server host.

## 1. xymonserver.cfg

Append the `fritzdsl` test to `TEST2RRD` and define a split-NCV rule
(in `xymonserver.cfg`, usually `/etc/xymon/` on Debian/Ubuntu,
`$XYMONHOME/etc/` elsewhere). Xymon's config files support appending
with `NAME+="value"`, so just add these lines at the end of the file
(or in a local include):

```
TEST2RRD+=",fritzdsl=ncv"
SPLITNCV_fritzdsl="crc:DERIVE,fec:DERIVE,hec:DERIVE,es:DERIVE,ses:DERIVE,retrain:DERIVE,*:GAUGE"
```

Note the leading comma: `+=` concatenates verbatim and does not
insert a separator.

`SPLITNCV_fritzdsl` (as opposed to `NCV_fritzdsl`) makes xymond_rrd
create **one RRD file per variable**, named `fritzdsl,<name>.rrd`,
each containing a single dataset named `lambda`. This avoids NCV's
19-character/underscore dataset name limits. The cumulative error
counters are stored as DERIVE, so their graphs show error *rates*;
everything else (rates, margins, attenuation, uptime) is a GAUGE.

To make the graphs appear on the trends column and on the `fritzdsl`
status page, also extend:

```
GRAPHS+=",fritzdslrate,fritzdslmargin,fritzdslatten,fritzdslerrors,fritzdslsecs,fritzdsluptime"
GRAPHS_fritzdsl="fritzdslrate,fritzdslmargin,fritzdslerrors"
```

(`GRAPHS_fritzdsl` is the selection shown on the status page itself —
pick the ones you care about.)

## 2. graphs.cfg

Include the graph definitions shipped in this directory:

```
include /etc/xymon/graphs.d/fritzdsl.cfg
```

or append the contents of `fritzdsl.cfg` to your `graphs.cfg`.

## 3. Restart / verify

Restart the Xymon server (or `xymon @ "rotate"` plus a xymond_rrd
restart). After the next poll, check that RRD files appear:

```
ls $XYMONVAR/rrd/<fritzbox-host>/fritzdsl,*
```

Then the graphs show up on the host's trends page.

## Alerting

The column goes yellow/red on line-down, low noise margin and rising
CRC error rates, so a normal `alerts.cfg` rule is enough, e.g.:

```
HOST=fritz.box TEST=fritzdsl
    MAIL admin@example.com COLOR=red REPEAT=4h
```
