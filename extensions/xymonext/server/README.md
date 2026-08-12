# xymonext — Xymon **server** configuration

The extension sends a `data` message with one `NAME : VALUE` line per
metric of the extension that has just run (`wall_smart : 0.42`,
`cpu_smart : 0.21`, `bytes_smart : 1132`). The Xymon server turns
those into RRD files and graphs via **split-NCV**. This is a one-time
setup on the Xymon server host.

Note that each message updates only the RRDs of that one test — every
extension has its own `INTERVAL`, and each curve is written at the
rhythm of its own test.

Both steps are **drop-in files**: nothing in a stock Xymon config file
has to be edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform (Debian/Ubuntu ship them ready to use).

## 1. xymonserver.d/my-xymon-extensions-xymonext.cfg

Copy the snippet shipped next to this README into the server's
drop-in directory:

```sh
cp xymonserver.d/my-xymon-extensions-xymonext.cfg /etc/xymon/xymonserver.d/
```

All metrics are plain gauges (each value describes a single run, not a
counter):

```
TEST2RRD+=",xymonext=ncv"
SPLITNCV_xymonext="*:GAUGE"
GRAPHS+=",xymonextwall,xymonextcpu,xymonextbytes"
GRAPHS_xymonext="xymonextwall,xymonextcpu,xymonextbytes"
```

Split-NCV keeps underscores and does not truncate dataset names, so
`wall_if_link` and friends arrive intact — that is why this extension
uses split-NCV and not plain NCV.

## 2. graphs.d/my-xymon-extensions-xymonext.cfg

Copy the graph definitions shipped next to this README:

```sh
cp graphs.d/my-xymon-extensions-xymonext.cfg /etc/xymon/graphs.d/
```

## 3. Restart / verify

Restart the Xymon server (a restart, not a reload — on Debian/Ubuntu
the list of included drop-in files is regenerated at start). After the
first run of each measured extension, check that RRD files appear:

```
ls $XYMONVAR/rrd/<host>/xymonext,*
```

Three files per measured extension (`wall_`, `cpu_`, `bytes_`); with
`XYMONEXT_COUNT_BYTES="no"` on the client the `bytes_` file is absent,
which is expected. The number of files varies with the number of
extensions a host runs — the FNPATTERNs in `graphs.d/my-xymon-extensions-xymonext.cfg`
pick up whatever exists.

The status message itself carries no NCV data: the human-readable
table is fenced off with `<!-- ncv_skipstart -->` /
`<!-- ncv_skipend -->`, so the table text can never turn into RRD
datasets of its own.

## Alerting

The column turns yellow/red when a single run exceeds
`XYMONEXT_WALL_WARN` / `XYMONEXT_WALL_CRIT` on the client (default 30
resp. 60 seconds), and yellow when a measured extension exits
non-zero. That is mainly a hang detector — a test stuck on an
unresponsive disk or a hanging HTTP poll shows up here long before its
own column goes purple. A matching `alerts.cfg` entry:

```
HOST=* COLUMN=xymonext
    MAIL admin@example.com REPEAT=6h DURATION>20m
```

The `DURATION` clause keeps a single slow run (a disk spinning up, a
package list refresh) out of your inbox while still catching a test
that stays slow.

If you only want the graphs, set both thresholds to 0 on the client —
the column then stays green and never alerts.
