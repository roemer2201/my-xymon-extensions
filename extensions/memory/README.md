# memory — memory utilization

Xymon client extension that reports the used share of physical memory
in one status column, plus an NCV line for RRD graphing.

- **Column:** `mem` (override with `MEM_COLUMN`)
- **Platforms:** Linux (`/proc/meminfo`) including OpenWrt/TurrisOS
  via the standalone runner. Platforms without `/proc/meminfo`
  (FreeBSD) report `clear`.
- **Requires:** nothing — BusyBox userland is enough.
- **Note:** a full Xymon client already delivers a `memory` column of
  its own; the default column name here is `mem`, not `memory`,
  precisely to avoid fighting over that column when this extension
  and a full client report to the same server. The shipped `tasks.d`
  snippet is **disabled by default** anyway, since a full-client host
  doesn't need this extension. This extension is meant for clientless
  hosts (routers, appliances) driven by the standalone runner, which
  runs every installed extension regardless of `tasks.d`.

## Metric

```
used % = (MemTotal - MemAvailable) / MemTotal * 100
```

`MemAvailable` is the kernel's own estimate of memory available for
new workloads without swapping (Linux ≥ 3.14). On older kernels it is
approximated as `MemFree + Buffers + Cached` (noted in the status
text).

## Thresholds and colors

| Setting    | Default | Meaning                          |
|------------|---------|----------------------------------|
| `MEM_WARN` | `80`    | yellow at/above this percent used |
| `MEM_CRIT` | `90`    | red at/above this percent used    |

Only `green`/`yellow`/`red` are sent (`clear` when `/proc/meminfo` is
missing) — never `blue`/`purple`, those are managed by the server.

## Configuration

Every setting is an environment variable with a built-in default and
can also be set in `$XYMONHOME/etc/memory.cfg` (sourced POSIX shell; a
value set there wins over the environment). See the shipped
[memory.cfg](memory.cfg).

## Graphing (Xymon server setup)

The status text contains one machine-readable line, hidden inside an
HTML comment (the NCV parser still sees it):

```
used : 42.5
```

**Caveat:** the stock `TEST2RRD` in `xymonserver.cfg` already contains
a `memory` entry that maps the column to the built-in parser for
full-client reports — that parser cannot read this extension's output.
Because this extension's default column is `mem`, not `memory`, the
common case needs no edit to that existing entry — just append a
fresh one:

1. Default (column `mem`): append a fresh `TEST2RRD` entry (see
   below) — nothing to change in the existing `memory` entry.
2. If you set `MEM_COLUMN="memory"` on a host that never runs a full
   client, edit the existing `TEST2RRD` value instead and change the
   `memory` entry to `memory=ncv` (do **not** just append — the first
   match wins), keeping the stock column name.

Then (assuming the default column name `mem`, option 1):

```
TEST2RRD+=",mem=ncv"
NCV_mem="used:GAUGE"
GRAPHS+=",memused"
GRAPHS_mem="memused"
```

and add a graph definition to `graphs.cfg`:

```
[memused]
    TITLE Memory used
    YAXIS Percent
    DEF:used=mem.rrd:used:AVERAGE
    LINE2:used#0000FF:memory used
    GPRINT:used:LAST: %5.1lf%% (cur)
    GPRINT:used:MAX: %5.1lf%% (max)\n
```

Restart the Xymon server side (`xymond_rrd`) and check that `mem.rrd`
appears under `$XYMONVAR/rrd/<host>/` after the next report. (With
option 2, use `memory`/`memory.rrd`/`GRAPHS_memory` throughout
instead.)

## OpenWrt / TurrisOS

Runs through the standalone runner (see
[standalone/README.md](../../standalone/README.md)), scheduled by cron:

```
*/5 * * * * /usr/lib/xymon-standalone/xymon-run.sh all
```

Dry run on the router: `/usr/lib/xymon-standalone/xymon-run.sh -n memory`
(the extension file is still named `memory.sh`; only the reported
column defaults to `mem`)
