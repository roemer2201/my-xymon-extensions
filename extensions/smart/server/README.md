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

## 1. xymonserver.d/my-xymon-extensions-smart.cfg

Copy the snippet shipped next to this README into the server's
drop-in directory:

```sh
cp xymonserver.d/my-xymon-extensions-smart.cfg /etc/xymon/xymonserver.d/
```

It appends the `smart` test to `TEST2RRD`, defines the split-NCV rule
and registers the graphs:

```
TEST2RRD+=",smart=ncv"
SPLITNCV_smart="*:GAUGE"
GRAPHS+=",smarttemp,smartwear,…"
GRAPHS_smart="smarttemp,smartwear,smartrealloc,smartpending,smartcrc"
```

`SPLITNCV_smart` (as opposed to `NCV_smart`) makes xymond_rrd create
**one RRD file per variable**, named `smart,<disk>_<metric>.rrd`, each
containing a single dataset named `lambda`. That is what allows an
arbitrary, per-host varying number of disks. See `man xymond_rrd`
(section NCV) if your Xymon version behaves differently.

`GRAPHS_smart` is the selection shown on the `smart` status page
itself — edit the copied file to pick the ones you care about.

`smartdwpd` and `smartdwpdrecent` show disk writes per day. Note that
`dwpdrecent` needs some history before it can report anything: a freshly
installed client (or one whose `$XYMONTMP` is a tmpfs that was cleared
by a reboot) starts sending it after `DWPD_WARMUP_HOURS` (default 6),
initially averaged over a shorter span that grows into the full
`DWPD_WINDOW_HOURS`. The client-side README explains the trade-off.

## 2. graphs.d/my-xymon-extensions-smart.cfg

Copy the graph definitions shipped next to this README:

```sh
cp graphs.d/my-xymon-extensions-smart.cfg /etc/xymon/graphs.d/
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
