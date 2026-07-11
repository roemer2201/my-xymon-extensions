# la — load average

Xymon client extension that reports the 1/5/15 minute load averages in
one status column, with thresholds relative to the number of CPU cores,
and NCV lines for RRD graphing.

- **Column:** `la` (override with `LA_COLUMN`)
- **Platforms:** Linux (`/proc/loadavg`) including OpenWrt/TurrisOS
  via the standalone runner, FreeBSD (`sysctl vm.loadavg`). Reports
  `clear` where neither source exists.
- **Requires:** nothing — BusyBox userland is enough.
- **Note:** a full Xymon client already delivers the same information
  as its `cpu` column, so the shipped `tasks.d` snippet is **disabled
  by default**. This extension is meant for clientless hosts (routers,
  appliances) driven by the standalone runner, which runs every
  installed extension regardless of `tasks.d`.

## Thresholds and colors

The check is evaluated on the **5-minute value divided by the CPU core
count**; all three values are displayed and graphed anyway.

| Setting   | Default | Meaning                                        |
|-----------|---------|------------------------------------------------|
| `LA_WARN` | `1.5`   | yellow at/above this 5-min load per core       |
| `LA_CRIT` | `3.0`   | red at/above this 5-min load per core          |
| `LA_NCPU` | detect  | CPU core count (nproc, `/proc/cpuinfo`, `sysctl hw.ncpu`) |

Only `green`/`yellow`/`red` are sent (`clear` when the load cannot be
read) — never `blue`/`purple`, those are managed by the server.

## Configuration

Every setting is an environment variable with a built-in default and
can also be set in `$XYMONHOME/etc/la.cfg` (sourced POSIX shell; a
value set there wins over the environment). See the shipped
[la.cfg](la.cfg).

## Graphing (Xymon server setup)

The status text contains three machine-readable lines, hidden inside
an HTML comment (the NCV parser still sees them):

```
la1 : 0.42
la5 : 1.20
la15 : 0.30
```

In `xymonserver.cfg` (or a local include) append:

```
TEST2RRD+=",la=ncv"
NCV_la="la1:GAUGE,la5:GAUGE,la15:GAUGE"
GRAPHS+=",laext"
GRAPHS_la="laext"
```

Note the leading comma — `+=` concatenates verbatim. This creates one
`la.rrd` per host with the three datasets. The stock `[la]` graph in
`graphs.cfg` expects a different dataset layout (the one produced from
full-client reports), so define a separate graph:

```
[laext]
    TITLE Load average
    YAXIS Load
    DEF:la1=la.rrd:la1:AVERAGE
    DEF:la5=la.rrd:la5:AVERAGE
    DEF:la15=la.rrd:la15:AVERAGE
    LINE1:la1#00CC00:1 min
    LINE2:la5#0000FF:5 min
    LINE1:la15#FF0000:15 min
    GPRINT:la5:LAST: %5.2lf (cur 5 min)\n
```

Restart the Xymon server side (`xymond_rrd`) and check that `la.rrd`
appears under `$XYMONVAR/rrd/<host>/` after the next report.

## OpenWrt / TurrisOS

Runs through the standalone runner (see
[standalone/README.md](../../standalone/README.md)), scheduled by cron:

```
*/5 * * * * /usr/lib/xymon-standalone/xymon-run.sh all
```

Dry run on the router: `/usr/lib/xymon-standalone/xymon-run.sh -n la`
