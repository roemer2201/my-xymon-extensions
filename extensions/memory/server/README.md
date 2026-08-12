# memory — Xymon **server** configuration

The extension puts one machine-readable line into its status message
(hidden in an HTML comment — the NCV parser still sees it):

```
used : 42.5
```

The Xymon server turns it into one `mem.rrd` per host, via plain
**NCV**. This is a one-time setup on the Xymon server host.

Both steps are **drop-in files**: nothing in a stock Xymon config file
has to be edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform (Debian/Ubuntu ship them ready to use).

## 1. xymonserver.d/memory.cfg

Copy the snippet shipped next to this README into the server's
drop-in directory:

```sh
cp xymonserver.d/memory.cfg /etc/xymon/xymonserver.d/
```

```
TEST2RRD+=",mem=ncv"
NCV_mem="used:GAUGE"
GRAPHS+=",memused"
GRAPHS_mem="memused"
```

**Caveat:** the stock `TEST2RRD` already contains a `memory` entry that
maps that column to the built-in parser for full-client reports, and
that parser cannot read this extension's output. Two cases:

1. **Default (column `mem`).** The stock entry is not in the way — the
   file above simply appends a fresh `mem` entry. Nothing to edit.
2. **`MEM_COLUMN="memory"`** on a host that never runs a full client:
   the first match in `TEST2RRD` wins, so appending does not help. Edit
   the existing `memory` entry in `xymonserver.cfg` to `memory=ncv`
   instead, and use `memory`/`memory.rrd`/`GRAPHS_memory` throughout
   the copied files.

## 2. graphs.d/memory.cfg

Copy the graph definition shipped next to this README:

```sh
cp graphs.d/memory.cfg /etc/xymon/graphs.d/
```

## 3. Restart / verify

Restart the Xymon server (a restart, not a reload — on Debian/Ubuntu
the list of included drop-in files is regenerated at start). After the
next report, check that the RRD file appears:

```
ls $XYMONVAR/rrd/<host>/mem.rrd
```

(With option 2 above it is `memory.rrd`.)

## Alerting

The column goes yellow/red on the thresholds configured on the client,
so a normal `alerts.cfg` rule is enough, e.g.:

```
HOST=* TEST=mem
    MAIL admin@example.com COLOR=red REPEAT=4h
```
