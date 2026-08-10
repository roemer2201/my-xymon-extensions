# if_link — Xymon **server** configuration

The extension sends a `data` message with one `NAME : VALUE` line per
interface (`changes_lan4 : 2`, …). The Xymon server turns those into
RRD files and graphs via **split-NCV**. This is a one-time setup on
the Xymon server host.

The archive definition (step 2) has to be in place before the RRD files
are created, so on an installation that already graphs `if_link` the
existing files have to go once — step 4. The graph definition itself is
safe to install at any point: without MAX archives rrdtool silently
falls back to AVERAGE, so it just keeps showing the old, diluted
picture until the files have been recreated.

## 1. xymonserver.cfg

The metric is a plain gauge (the extension computes the delta itself,
so no COUNTER/DERIVE handling is needed). Append:

```
TEST2RRD+=",if_link=ncv"
SPLITNCV_if_link="*:GAUGE"
```

Note the leading comma: `+=` concatenates verbatim and does not
insert a separator.

To make the graph appear on the trends column and on the `if_link`
status page, also extend:

```
GRAPHS+=",iflink"
GRAPHS_if_link="iflink"
```

## 2. rrddefinitions.cfg

Include the archive definition shipped in this directory
(`rrddefinitions.d/if_link.cfg`):

```
include /etc/xymon/rrddefinitions.d/if_link.cfg
```

or append its contents to your `rrddefinitions.cfg`.

It keeps Xymon's default AVERAGE archives and adds a matching set of
**MAX** archives. Without them a flap is diluted in every graph longer
than 48 hours until it is invisible — see
[Why the graph showed 0.4](#why-the-graph-showed-04).

> Xymon 4.2 had a `TRACKMAX` setting in `xymonserver.cfg` for this.
> It was **dropped in 4.3** — `rrddefinitions.cfg` replaces it.

## 3. graphs.cfg

Include the graph definition shipped in this directory
(`graphs.d/if_link.cfg`):

```
include /etc/xymon/graphs.d/if_link.cfg
```

or append the contents of `graphs.d/if_link.cfg` to your `graphs.cfg`.

The definition draws its line from the MAX archive and prints the exact
number of changes in the shown window as `(total)`, integrated from the
AVERAGE archive. Installing it before step 4 does no harm: rrdtool falls
back to the AVERAGE archive when a file has no MAX archive, so the graph
renders either way.

## 4. Existing installations: recreate the RRD files

`rrddefinitions.cfg` is only consulted when an RRD file is **created**.
Files that already exist keep the archives they were born with, so an
installation that has been graphing `if_link` since before this change
has to drop them once:

```sh
service xymon stop                       # or: systemctl stop xymon
rm $XYMONVAR/rrd/*/if_link,changes_*.rrd
service xymon start
```

Stopping the server first avoids xymond_rrd's write cache (up to 30
minutes of buffered updates) writing into a file you just deleted.

This discards the history of that column — for `if_link` that is
usually a small price, and there is no way around it: `rrdtool tune`
cannot add an archive to an existing file. If you do want to keep the
history, `rrdtool dump` the file, add the `<rra>` blocks by hand and
`rrdtool restore` it; that is rarely worth the effort here.

The files are recreated with the next `data` message from each client,
i.e. within one poll interval — the clients keep counting across this,
their state files are untouched.

## 5. Verify

Check that the RRD files exist and — the point of step 2 — that they
carry MAX archives:

```sh
ls $XYMONVAR/rrd/<host>/if_link,*
rrdtool info $XYMONVAR/rrd/<host>/if_link,changes_eth0.rrd | grep 'cf = "MAX"'
```

One RRD file per monitored interface; the number varies with the host's
ports, which is expected — the FNPATTERN in `graphs.d/if_link.cfg`
picks up whatever exists.

The `grep` must print four `cf = "MAX"` lines. **If it prints nothing**,
the `[if_link]` section did not apply to these files. `rrddefinitions.cfg`
sections are keyed by the column name, which is what `[if_link]` is —
but the split-NCV files are named `if_link,changes_<if>.rrd`, and this
repository has not verified against the Xymon sources which of the two
forms the lookup uses for `SPLITNCV_*` columns. If the section is
ignored, add the four `RRA:MAX` lines to the `[default]` section of
`rrddefinitions.cfg` instead (they then apply to newly created RRDs of
every column, which is harmless but not minimal) and redo step 4.

## Why the graph showed 0.4

The extension only ever sends whole numbers, and none of this is a bug
in it — the fractions are produced by RRDtool, by two independent
mechanisms. Both were reproduced with rrdtool directly, feeding a
24-hour series of integer polls with a single 2-change flap into a
Xymon-shaped RRD:

- **Step normalization.** RRDtool aligns its 5-minute grid to the epoch,
  not to your poll times. A poll that sits at a fixed offset inside that
  grid — which is the normal case, the offset being whenever
  xymonlaunch or cron happens to fire — has *every* value split across
  the two adjacent slots by time. At an offset of 100 s the flap of 2
  was stored as 1.33 and 0.67. Regular polling does not help: this is a
  constant phase offset, not jitter. It is inherent to RRDtool, no
  dataset type avoids it, and it **cannot** be switched off.
- **Archive consolidation.** On top of that, Xymon's default archives
  consolidate with AVERAGE, so a graph longer than 48 hours divides the
  flap by the consolidation factor of the view. The stored 1.33 was
  drawn as **0.39** in a 5-day graph, 0.20 in a 12-day one and 0.07 over
  40 days — the reported 0.4 is this effect, not the first one.

So "only integers in the RRD file" is not something RRDtool can be made
to do. Steps 2–3 fix the second mechanism and work around the first:

| | before | after |
|---|---|---|
| line in a 5-day graph | 0.39 (AVERAGE) | 1.33 (MAX) |
| line in a 40-day graph | 0.07 (AVERAGE) | 1.33 (MAX) |
| exact event count | not shown | `(total)`, exact |

The MAX archives stop the dilution, so a flap keeps the same visible
height in every time range. They do not make the per-slot values whole
numbers — 1.33 stays 1.33 — which is why the graph also prints
`(total)`: the per-poll counts integrated back into an event count over
the shown window. That figure is resolution independent and came out
exactly 3 for the 3 changes in the test series. It is exact as long as
the poll interval equals the RRD step of 300 s; with an interval that
varies from poll to poll the gauge holds its level for the wrong length
of time and the total drifts (2.84 instead of 3 in a run with ±40 s of
jitter).

`ABSOLUTE` as the dataset type would fix that last inaccuracy — it is
the RRDtool type meant for "count since last read" — but it stores a
**rate per second**, so a raw value of 2 changes becomes `0.0067` in the
file and every graph has to multiply by the step again. `GAUGE` keeps
the stored numbers readable as counts, which is why it stays.

## Alerting

With no thresholds configured the column never leaves `green`, so no
`alerts.cfg` entry is needed — watch the graph instead. If you do set
`IF_LINK_YELLOW`/`IF_LINK_RED` (or `IF_LINK_THRESHOLDS`) on a client,
the column turns yellow/red like any other and the usual `alerts.cfg`
rules apply, e.g.:

```
HOST=router.example.com COLUMN=if_link
    MAIL admin@example.com REPEAT=6h
```

A flapping port typically recovers on its own before the next poll, so
a `DURATION>10m` clause is a good way to keep single events out of
your inbox while still catching a port that keeps bouncing.
