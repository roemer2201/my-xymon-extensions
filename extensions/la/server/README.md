# la — Xymon **server** configuration

The extension puts three machine-readable lines into its status
message (hidden in an HTML comment — the NCV parser still sees them):

```
la1 : 0.42
la5 : 1.20
la15 : 0.30
```

The Xymon server turns those into one `la.rrd` per host with three
datasets, via plain **NCV** (a fixed set of metrics — no split-NCV
needed). This is a one-time setup on the Xymon server host.

Both steps are **drop-in files**: nothing in a stock Xymon config file
has to be edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform (Debian/Ubuntu ship them ready to use).

## 1. xymonserver.d/la.cfg

Copy the snippet shipped next to this README into the server's
drop-in directory:

```sh
cp xymonserver.d/la.cfg /etc/xymon/xymonserver.d/
```

```
TEST2RRD+=",la=ncv"
NCV_la="la1:GAUGE,la5:GAUGE,la15:GAUGE"
GRAPHS+=",laext"
GRAPHS_la="laext"
```

## 2. graphs.d/la.cfg

Copy the graph definition shipped next to this README:

```sh
cp graphs.d/la.cfg /etc/xymon/graphs.d/
```

The graph is called `laext`, not `la`, on purpose: Xymon's stock `[la]`
graph expects the dataset layout produced from full-client reports and
would not find these datasets.

## 3. Restart / verify

Restart the Xymon server (a restart, not a reload — on Debian/Ubuntu
the list of included drop-in files is regenerated at start). After the
next report, check that the RRD file appears:

```
ls $XYMONVAR/rrd/<host>/la.rrd
```

## Alerting

The column goes yellow/red on the per-core thresholds configured on the
client, so a normal `alerts.cfg` rule is enough, e.g.:

```
HOST=* TEST=la
    MAIL admin@example.com COLOR=red REPEAT=4h
```
