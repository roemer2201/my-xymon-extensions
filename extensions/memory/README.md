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
  and a full client report to the same server. The shipped `clientlaunch.d`
  snippet is **disabled by default** anyway, since a full-client host
  doesn't need this extension. This extension is meant for clientless
  hosts (routers, appliances) driven by the standalone runner, which
  runs every installed extension regardless of `clientlaunch.d`.

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

Plain NCV on the server turns it into one `mem.rrd` per host. The
needed configuration is shipped as ready-made drop-in files in
[`server/`](server/) — copy `server/xymonserver.d/my-xymon-extensions-memory.cfg` into the
server's `xymonserver.d/` and `server/graphs.d/my-xymon-extensions-memory.cfg` into its
`graphs.d/`, then restart Xymon. See
[server/README.md](server/README.md).

**Caveat:** the stock `TEST2RRD` already contains a `memory` entry that
maps that column to the built-in parser for full-client reports, which
cannot read this extension's output. With the default column name
`mem` that entry is not in the way and the drop-in file works as
shipped; if you set `MEM_COLUMN="memory"`, the existing entry has to
be changed to `memory=ncv` instead (the first match wins). The server
README spells both cases out.

## OpenWrt / TurrisOS

Runs through the standalone runner (see
[standalone/README.md](../../standalone/README.md)), scheduled by cron:

```
*/5 * * * * /usr/lib/xymon-standalone/xymon-run.sh all
```

Dry run on the router: `/usr/lib/xymon-standalone/xymon-run.sh -n memory`
(the extension file is still named `memory.sh`; only the reported
column defaults to `mem`)
