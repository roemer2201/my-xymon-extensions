# fritzdsl — Xymon **server** configuration

The extension sends a `data` message with one `NAME : VALUE` line per
metric (`margin_down : 6.5`, `crc : 56`, …). The Xymon server turns
those into RRD files and graphs via **split-NCV**. This is a one-time
setup on the Xymon server host.

Both steps are **drop-in files**: nothing in a stock Xymon config file
has to be edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform (Debian/Ubuntu ship them ready to use).

## 1. xymonserver.d/fritzdsl.cfg

Copy the snippet shipped next to this README into the server's
drop-in directory:

```sh
cp xymonserver.d/fritzdsl.cfg /etc/xymon/xymonserver.d/
```

It appends the `fritzdsl` test to `TEST2RRD`, defines the split-NCV
rule and registers the graphs:

```
TEST2RRD+=",fritzdsl=ncv"
SPLITNCV_fritzdsl="crc:DERIVE,fec:DERIVE,…,*:GAUGE"
GRAPHS+=",fritzdslrate,fritzdslmargin,…"
GRAPHS_fritzdsl="fritzdslrate,fritzdslmargin,…,fritzdsluptime"
```

`SPLITNCV_fritzdsl` (as opposed to `NCV_fritzdsl`) makes xymond_rrd
create **one RRD file per variable**, named `fritzdsl,<name>.rrd`,
each containing a single dataset named `lambda`. This avoids NCV's
19-character/underscore dataset name limits. The cumulative error
counters are stored as DERIVE, so their graphs show error *rates*;
everything else (rates, margins, attenuation, uptime) is a GAUGE.

`GRAPHS_fritzdsl` lists the graphs drawn on the status page, and that
page is the **only** place they appear — so the shipped file lists all
of them. A graph removed there is gone from the web interface entirely:
the trends page looks graphs up by comparing the *graph* name with the
beginning of the *RRD file* name (`lib/xymonrrd.c`,
`find_xymon_graph()`), without consulting `FNPATTERN`, so
`fritzdslrate` never matches `fritzdsl,rateup.rrd`.

## 2. graphs.d/fritzdsl.cfg

Copy the graph definitions shipped next to this README:

```sh
cp graphs.d/fritzdsl.cfg /etc/xymon/graphs.d/
```

## 3. Restart / verify

Restart the Xymon server (a restart, not a reload — on Debian/Ubuntu
the list of included drop-in files is regenerated at start). After the
next poll, check that RRD files appear:

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
