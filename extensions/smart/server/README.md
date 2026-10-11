# smart — Xymon **server** configuration

The client extension sends a `data` message with one `NAME : VALUE`
line per disk and metric (`WD_WCAVY1234567_temp : 38`,
`S5GXNF0R123456A_wear : 3`, …). Disks are named by their serial number
or an alias, not by `/dev/sdX` — see "Device naming" in the client
README.
The Xymon server turns those into RRD files and graphs via
**split-NCV**. This is a one-time setup on the Xymon server host
(which may run any OS — these are plain Xymon config changes).

Both steps are **drop-in files**: nothing in a stock Xymon config file
has to be edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform (Debian/Ubuntu ship them ready to use).

## 1. xymonserver.d/smart.cfg

Copy the snippet shipped next to this README into the server's
drop-in directory:

```sh
cp xymonserver.d/smart.cfg /etc/xymon/xymonserver.d/
```

It appends the `smart` test to `TEST2RRD`, defines the split-NCV rule
and registers the graphs:

```
TEST2RRD+=",smart=ncv"
SPLITNCV_smart="*:GAUGE"
GRAPHS+=",smarttemp,smartwear,…"
GRAPHS_smart="smarttemp,smartwear,smartspare,…,smartdwpd,smartdwpdrecent"
```

`SPLITNCV_smart` (as opposed to `NCV_smart`) makes xymond_rrd create
**one RRD file per variable**, named `smart,<disk>_<metric>.rrd`, each
containing a single dataset named `lambda`. That is what allows an
arbitrary, per-host varying number of disks. See `man xymond_rrd`
(section NCV) if your Xymon version behaves differently.

`GRAPHS_smart` lists the graphs drawn on the `smart` status page, and
that page is the **only** place they appear — so the shipped file lists
all of them. Edit the copied file to drop the ones you do not care
about, but be aware that a graph removed there is gone from the web
interface entirely: the trends page cannot show these graphs.

The reason is in `lib/xymonrrd.c`, `find_xymon_graph()`. The trends page
walks the host's RRD directory and looks up a graph for each file by
comparing the **graph name** with the beginning of the *file* name (the
next character has to be `.`, `,` or end-of-string). `FNPATTERN` is not
consulted at that point. `smarttemp` is therefore not a match for
`smart,sda_temp.rrd` — only a single graph named `smart` would be, and
one graph cannot cover thirteen metrics with different units. The status
page takes the other route: `GRAPHS_smart` is read in `lib/htmllog.c`
and each name is passed to `showgraph.sh` verbatim, which looks the name
up in `graphs.cfg` and *does* use `FNPATTERN`.

A graph whose RRD files do not exist on a given host — `smartspare` on a
host without NVMe, `smartrealloc` on a host with nothing but NVMe — shows
up as nothing at all: no frame, no title, only the zoom icon next to an
invisible image. `showgraph.sh` answers with a valid but blank
placeholder PNG when no file matches `FNPATTERN` (`web/showgraph.c`,
`rrddbcount == 0`), not with an error and not with an empty graph.

`smartdwpd` and `smartdwpdrecent` show disk writes per day. Note that
`dwpdrecent` needs some history before it can report anything: a freshly
installed client (or one whose `$XYMONTMP` is a tmpfs that was cleared
by a reboot) starts sending it after `DWPD_WARMUP_HOURS` (default 6),
initially averaged over a shorter span that grows into the full
`DWPD_WINDOW_HOURS`. The client-side README explains the trade-off.

## 2. graphs.d/smart.cfg

Copy the graph definitions shipped next to this README:

```sh
cp graphs.d/smart.cfg /etc/xymon/graphs.d/
```

## 3. Restart / verify

Restart the Xymon server (a restart, not a reload — on Debian/Ubuntu
the list of included drop-in files is regenerated at start). After the
next client report, check that RRD files appear:

```
ls $XYMONVAR/rrd/<clienthost>/smart,*
```

(`$XYMONVAR` is `/var/lib/xymon` on Debian/Ubuntu.) The graphs appear
on the host's **smart status page** — not on the trends page, see
section 1.

**Give it 10–15 minutes.** Right after the setup the status page
already lists all graphs, but every one of them is the blank
placeholder described above:

- The RRD files are only created by the first `data` message that
  arrives *after* the restart.
- rrdtool needs at least two updates before it can draw a line; the
  client reports every 5 minutes.
- `xymond_rrd` caches updates before writing them to disk.

If the graphs are still blank after that, check in this order: the
`ls` above (no files: `TEST2RRD`/`SPLITNCV_smart` are not in effect for
`xymond_rrd`, or the `[rrddata]` task is not running — see
`/var/log/xymon/rrd-data.log`), then whether `graphs.d/smart.cfg` is
read (an unknown graph name makes `showgraph.sh` return an error
instead of an image, which the browser shows as a broken image).

## Alerting

Alerting needs no extra setup: the `smart` column goes yellow/red on
threshold violations and SMART health failures, so a normal
`alerts.cfg` rule matching `TEST=smart` is enough, e.g.:

```
HOST=* TEST=smart
    MAIL admin@example.com COLOR=red REPEAT=4h
```
