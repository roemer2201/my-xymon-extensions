# temp — Xymon **server** configuration

The extension puts one machine-readable `NAME : VALUE` line per sensor
into its status message (hidden in an HTML comment — the NCV parser
still sees it). The Xymon server turns those into RRD files and graphs
via **split-NCV**, one RRD file per sensor, because the number of
sensors varies per host. This is a one-time setup on the Xymon server
host.

Both steps are **drop-in files**: nothing in a stock Xymon config file
has to be edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform (Debian/Ubuntu ship them ready to use).

## 1. xymonserver.d/temp.cfg

Copy the snippet shipped next to this README into the server's
drop-in directory:

```sh
cp xymonserver.d/temp.cfg /etc/xymon/xymonserver.d/
```

```
TEST2RRD+=",temp=ncv"
SPLITNCV_temp="*:GAUGE"
GRAPHS+=",temp"
GRAPHS_temp="temp"
```

**Caveat:** the first match in `TEST2RRD` wins. If your stock
`TEST2RRD` already contains a `temp` entry (some setups map it to the
`temperature` module), appending has no effect — change that entry in
`xymonserver.cfg` to `temp=ncv` instead and drop the `TEST2RRD` line
from the copied file.

The column name `temp` does not collide with Xymon's own stock
`[temperature]` graph (a different name), so no `tempext` alias is
needed.

## 2. graphs.d/temp.cfg

Copy the graph definition shipped next to this README:

```sh
cp graphs.d/temp.cfg /etc/xymon/graphs.d/
```

Split-NCV always stores the value in a dataset called `lambda`,
regardless of the test name. If you already have a `[temp]` section
from an older or unrelated setup, fix its `DEF` line to read from
`lambda` instead of adding a second section.

## 3. Restart / verify

Restart the Xymon server (a restart, not a reload — on Debian/Ubuntu
the list of included drop-in files is regenerated at start). After the
next report, check that files named `temp,<sensor>.rrd` appear:

```
ls $XYMONVAR/rrd/<host>/temp,*
```

If you upgraded from a version of this extension older than 0.10.4,
the server may still hold junk RRD files created from the display
lines (names like `temp,_green_armada_thermal_temp1.rrd`). They stop
being updated after the upgrade and can simply be deleted.

## Alerting

The column goes yellow/red on the per-sensor thresholds configured on
the client, so a normal `alerts.cfg` rule is enough, e.g.:

```
HOST=* TEST=temp
    MAIL admin@example.com COLOR=red REPEAT=4h
```
