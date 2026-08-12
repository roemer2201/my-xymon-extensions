# smart — Xymon **server** configuration

The client extension sends a `data` message with one `NAME : VALUE`
line per disk and metric (`sda_temp : 38`, `nvme0_wear : 3`, …).
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
host without NVMe, `smartrealloc` on a host with nothing but NVMe — is
drawn as an empty frame (title and axes, no data), not as a broken
image, because `showgraph.sh` still emits a valid PNG.

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

Then the graphs show up on the host's trends page.

## Alerting

Alerting needs no extra setup: the `smart` column goes yellow/red on
threshold violations and SMART health failures, so a normal
`alerts.cfg` rule matching `TEST=smart` is enough, e.g.:

```
HOST=* TEST=smart
    MAIL admin@example.com COLOR=red REPEAT=4h
```
