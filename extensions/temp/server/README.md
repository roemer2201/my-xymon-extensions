# temp — Xymon **server** configuration

The extension puts one machine-readable `NAME : VALUE` line per sensor
into its status message (hidden in an HTML comment — the NCV parser
still sees it). The Xymon server turns those into RRD files and graphs
via **split-NCV**, one RRD file per sensor, because the number of
sensors varies per host. This is a one-time setup on the Xymon server
host.

> **This extension is the one exception in the server package.** Its
> two drop-ins are *not* installed by `my-xymon-extensions-server`:
> `xymonserver.d/temp.cfg` and `graphs.d/temp.cfg` are file names that
> Debian's `hobbit-plugins` package already ships, and dpkg refuses to
> install two packages claiming one path. The files are shipped as
> documentation instead
> (`/usr/share/doc/my-xymon-extensions-server/temp/`) and are put in
> place by hand — two `cp` commands, nothing else differs from the
> other extensions. Which case you are in:
> [Coexisting with hobbit-plugins](#coexisting-with-hobbit-plugins).

See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how the drop-in directories are wired up on
your platform (Debian/Ubuntu ship them ready to use).

## 1. xymonserver.d/temp.cfg

```sh
cp xymonserver.d/temp.cfg /etc/xymon/xymonserver.d/
```

```
TEST2RRD+=",temp=ncv"
SPLITNCV_temp="*:GAUGE"
GRAPHS+=",temp"
GRAPHS_temp="temp"
```

**Caveat:** the first match in `TEST2RRD` wins — `xymond` builds a tree
from the value and keeps the first entry per test name. If something
read *earlier* already maps `temp` (a stock entry pointing at the
`temperature` module, or hobbit-plugins' drop-in), appending has no
effect. Two ways out: fix that entry, or make this one independent of
the read order by using

```
TEST2RRD="temp=ncv,$TEST2RRD"
```

instead of the `+=` line — prepending puts it in front of everything,
whatever is read when.

## 2. graphs.d/temp.cfg

```sh
cp graphs.d/temp.cfg /etc/xymon/graphs.d/
```

Split-NCV always stores the value in a dataset called `lambda`,
regardless of the test name. If you already have a `[temp]` section
from an older or unrelated setup, fix its `DEF` line to read from
`lambda` instead of adding a second section — with two sections of one
name the one parsed **last** wins (`load_gdefs` pushes each onto the
head of the list, the lookup takes the first hit), so duplicates make
the result depend on file order.

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

Debian's `hobbit-plugins` ships a temperature plugin of its own and
claims the same column, with the same two file names:

```
# /etc/xymon/xymonserver.d/temp.cfg
TEST2RRD="$TEST2RRD,temp"        # maps the column to an RRD module "temp"
GRAPHS="$GRAPHS,temp"

# /etc/xymon/graphs.d/temp.cfg
[temp]  … DEF:…=@RRDFN@:temp:AVERAGE
```

Three cases:

**hobbit-plugins is not installed.** Nothing special — copy both files
in as shown above and you are done. (The server package leaves them out
regardless, because it cannot know whether the package will be
installed later.)

**It is installed, but you do not use its temp plugin.** That is the
normal case: its client-side task ships `DISABLED`. Overwrite its two
files with ours. Note that both are conffiles of `hobbit-plugins`, so
dpkg will ask what to do with them on that package's next upgrade —
answer "keep the currently-installed version". If you prefer not to
touch another package's files, empty them instead
(`: > /etc/xymon/graphs.d/temp.cfg`) and put ours in under a different
name, e.g. `temp-ext.cfg`; then make step 1 order-independent with the
`TEST2RRD="temp=ncv,$TEST2RRD"` form above, because a file name alone
does not reliably decide the read order (the directory is expanded by a
shell glob in Debian's init script, i.e. with locale-dependent
collation).

Leaving both configurations active is the one thing that does *not*
work: their `TEST2RRD` entry maps the column to an RRD module
`xymond_rrd` does not have — no branch in `update_rrd` matches `temp`,
so whichever of the two is read first decides whether **any** RRD file
is written. And their `[temp]` graph reads a dataset named `temp` where
split-NCV writes `lambda`, so on top of that the graph would come out
empty.

**You actually use hobbit-plugins' temp plugin.** Then the two cannot
share the column: give this extension its own via `TEMP_COLUMN` on its
clients, and change `temp` to that name everywhere in the two copied
files (including the `FNPATTERN`).

**If your temp RRDs predate this setup**, check what created them:
files written by another handler have a different dataset name, and
`xymond_rrd` cannot update them with `lambda`.

```sh
rrdtool info $XYMONVAR/rrd/<host>/temp,<sensor>.rrd | grep '^ds\['
```

If that says anything but `lambda`, delete those files once and let
them be recreated.

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
