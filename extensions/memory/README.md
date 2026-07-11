# memory — memory utilization

Xymon client extension that reports the used share of physical memory
in one status column, plus an NCV line for RRD graphing.

- **Column:** `memory` (override with `MEM_COLUMN`)
- **Platforms:** Linux (`/proc/meminfo`) including OpenWrt/TurrisOS
  via the standalone runner. Platforms without `/proc/meminfo`
  (FreeBSD) report `clear`.
- **Requires:** nothing — BusyBox userland is enough.
- **Note:** a full Xymon client already delivers a `memory` column of
  its own; running this extension there would fight over the same
  column, so the shipped `tasks.d` snippet is **disabled by default**.
  This extension is meant for clientless hosts (routers, appliances)
  driven by the standalone runner, which runs every installed
  extension regardless of `tasks.d`.

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
Two ways out:

1. Edit the existing `TEST2RRD` value and change the `memory` entry to
   `memory=ncv` (do **not** just append — the first match wins), or
2. rename the column on the clientless hosts (`MEM_COLUMN="mem"` in
   `memory.cfg`) and append a fresh entry: `TEST2RRD+=",mem=ncv"`.

Then (assuming the default column name and option 1):

```
NCV_memory="used:GAUGE"
GRAPHS+=",memused"
GRAPHS_memory="memused"
```

and add a graph definition to `graphs.cfg`:

```
[memused]
    TITLE Memory used
    YAXIS Percent
    DEF:used=memory.rrd:used:AVERAGE
    LINE2:used#0000FF:memory used
    GPRINT:used:LAST: %5.1lf%% (cur)
    GPRINT:used:MAX: %5.1lf%% (max)\n
```

Restart the Xymon server side (`xymond_rrd`) and check that
`memory.rrd` appears under `$XYMONVAR/rrd/<host>/` after the next
report.

## OpenWrt / TurrisOS

Runs through the standalone runner (see
[standalone/README.md](../../standalone/README.md)), scheduled by cron:

```
*/5 * * * * /usr/lib/xymon-standalone/xymon-run.sh all
```

Dry run on the router: `/usr/lib/xymon-standalone/xymon-run.sh -n memory`
