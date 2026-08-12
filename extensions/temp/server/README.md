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

## 1. xymonserver.d/my-xymon-extensions-temp.cfg

Copy the snippet shipped next to this README into the server's
drop-in directory:

```sh
cp xymonserver.d/my-xymon-extensions-temp.cfg /etc/xymon/xymonserver.d/
```

```
TEST2RRD+=",temp=ncv"
SPLITNCV_temp="*:GAUGE"
GRAPHS+=",tempext"
GRAPHS_temp="tempext"
```

**Caveat:** the first match in `TEST2RRD` wins — `xymond` builds a tree
from the value and keeps the first entry per test name. If your stock
`TEST2RRD` already contains a `temp` entry (some setups map it to the
`temperature` module), appending has no effect — change that entry in
`xymonserver.cfg` to `temp=ncv` instead and drop the `TEST2RRD` line
from the copied file.

## 2. graphs.d/my-xymon-extensions-temp.cfg

Copy the graph definition shipped next to this README:

```sh
cp graphs.d/my-xymon-extensions-temp.cfg /etc/xymon/graphs.d/
```

Split-NCV always stores the value in a dataset called `lambda`,
regardless of the test name. The section is named `[tempext]`, not
`[temp]` — see [Coexisting with hobbit-plugins](#coexisting-with-hobbit-plugins).

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

## Coexisting with hobbit-plugins

Debian's `hobbit-plugins` package ships a temperature plugin of its own
and claims the same column. Its drop-ins are
`/etc/xymon/xymonserver.d/temp.cfg` and `/etc/xymon/graphs.d/temp.cfg`:

```
TEST2RRD="$TEST2RRD,temp"        # maps the column to an RRD module "temp"
GRAPHS="$GRAPHS,temp"
[temp]  … DEF:…=@RRDFN@:temp:AVERAGE
```

Two things follow, and both are handled by the file names and section
names this repository uses — do not rename them away:

- **`TEST2RRD` is first-match-wins**, and `temp` (without `=ncv`) maps
  the column to an RRD module that `xymond_rrd` does not have: no
  handler matches, so **no RRD file is written at all**. Our entry
  `temp=ncv` must therefore be read first. Drop-ins are read in
  alphabetical order, and `my-xymon-extensions-temp.cfg` sorts before
  `temp.cfg` — that is what makes it deterministic.
- **Duplicate graph sections**: with two `[temp]` sections the one
  parsed *last* wins (`load_gdefs` pushes each section onto the head of
  the list and the lookup takes the first hit). Our graph is therefore
  named `[tempext]`, so neither definition can silently replace the
  other — the same trick the `la` extension uses with `[laext]`.

That makes the two coexist without breaking, but they still both offer
a graph for the column: hobbit's `[temp]` has the same `FNPATTERN` and
would render an empty graph from our files, since it reads a dataset
named `temp` where split-NCV writes `lambda`. If you do not use
hobbit-plugins' temp plugin (it ships `DISABLED`), empty its two
`temp.cfg` drop-ins. If you *do* use it, the two cannot share the
column — give this extension another one via `TEMP_COLUMN` on its
clients and adjust `TEST2RRD`/`GRAPHS_*` in the copied file to match.

**If your temp RRDs predate this setup**, check what created them:
files written by another handler have a different dataset name, and
`xymond_rrd` cannot update them with `lambda`. `rrdtool info
$XYMONVAR/rrd/<host>/temp,<sensor>.rrd | grep '^ds\['` shows it; if it
says anything but `lambda`, delete those files once and let them be
recreated.

The column name `temp` does not collide with Xymon's own stock
`[temperature]` graph — that is a different name, and a different
handler.

## Alerting

The column goes yellow/red on the per-sensor thresholds configured on
the client, so a normal `alerts.cfg` rule is enough, e.g.:

```
HOST=* TEST=temp
    MAIL admin@example.com COLOR=red REPEAT=4h
```
