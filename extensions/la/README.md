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
  as its `cpu` column, so the shipped `clientlaunch.d` snippet is **disabled
  by default**. This extension is meant for clientless hosts (routers,
  appliances) driven by the standalone runner, which runs every
  installed extension regardless of `clientlaunch.d`.

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

Plain NCV on the server turns them into one `la.rrd` per host with
three datasets. The needed configuration is shipped as ready-made
drop-in files in [`server/`](server/) — copy
`server/xymonserver.d/la.cfg` into the server's `xymonserver.d/` and
`server/graphs.d/la.cfg` into its `graphs.d/`, then restart Xymon.
See [server/README.md](server/README.md).

The graph is called `laext`, not `la`: the stock `[la]` graph expects
the dataset layout produced from full-client reports.

## OpenWrt / TurrisOS

Runs through the standalone runner (see
[standalone/README.md](../../standalone/README.md)), scheduled by cron:

```
*/5 * * * * /usr/lib/xymon-standalone/xymon-run.sh all
```

Dry run on the router: `/usr/lib/xymon-standalone/xymon-run.sh -n la`
