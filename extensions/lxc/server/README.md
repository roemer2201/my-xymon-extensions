# lxc — Xymon **server** configuration

The extension sends a `data` message with one `NAME : VALUE` line per
container and metric (`ca_ram : 116.0`, `ca_cpu : 5.0`, `ca_netin :
80.0`, …) plus the three host-wide counters `count_total`,
`count_running` and `count_down`. The Xymon server turns those into RRD
files and graphs via **split-NCV**. This is a one-time setup on the
Xymon server host.

Both config steps are **drop-in files**: nothing in a stock Xymon config
file has to be edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform.

## 1. xymonserver.d/lxc.cfg

Copy the snippet shipped next to this README into the server's drop-in
directory:

```sh
cp xymonserver.d/lxc.cfg /etc/xymon/xymonserver.d/
```

```
TEST2RRD+=",lxc=ncv"
SPLITNCV_lxc="*:GAUGE"
GRAPHS+=",lxccount,lxcram,lxccpu,lxcnetin,lxcnetout"
GRAPHS_lxc="lxccount,lxcram,lxccpu,lxcnetin,lxcnetout"
```

Split-NCV is what makes the container set dynamic: each metric of each
container gets its **own** RRD file, so creating or destroying a
container adds new files or leaves old ones orphaned and never disturbs
an existing graph. Plain NCV would put every metric into one file with a
fixed dataset list — and that list is frozen the moment the file is
created, so the first container added afterwards would be missing from
the graphs for good.

All metrics are gauges. The extension converts the cumulative CPU and
byte counters into rates itself and skips a poll whose counter went
backwards (i.e. after a container restart), so no `COUNTER`/`DERIVE`
handling is needed on the server.

## 2. graphs.d/lxc.cfg

Copy the graph definitions shipped next to this README:

```sh
cp graphs.d/lxc.cfg /etc/xymon/graphs.d/
```

Five graphs, all of them driven by an `FNPATTERN` so that they pick up
whatever containers a host happens to have:

| Graph | RRD files | shows |
|---|---|---|
| `lxccount` | `lxc,count_(total\|running\|down).rrd` | how many containers exist, run, are down |
| `lxcram` | `lxc,<ct>_ram.rrd` | resident memory per container, MiB |
| `lxccpu` | `lxc,<ct>_cpu.rrd` | CPU per container, percent of **one** core |
| `lxcnetin` | `lxc,<ct>_netin.rrd` | traffic into the container, kbit/s |
| `lxcnetout` | `lxc,<ct>_netout.rrd` | traffic out of the container, kbit/s |

The container name in the file name is the sanitized one: lowercase,
everything outside `[a-z0-9]` replaced by `_`. A container named
`thunderbird-test` therefore appears as `thunderbird_test` in the graph
legend.

## 3. Restart

Restart the Xymon server — a restart, not a reload: on Debian/Ubuntu the
list of included drop-in files under `xymonserver.d/` is regenerated at
start.

## 4. Verify

```sh
ls $XYMONVAR/rrd/<host>/lxc,*
```

Expect one file per container and metric plus the three `count_*` files,
e.g.:

```
lxc,ca_cpu.rrd  lxc,ca_netin.rrd  lxc,ca_netout.rrd  lxc,ca_ram.rrd
lxc,count_down.rrd  lxc,count_running.rrd  lxc,count_total.rrd
```

The number of files varies per host, which is expected. A container that
is stopped contributes no metric files at all until it runs for two
polls — CPU and traffic are differences between polls, so they appear
one interval after the container starts.

Metrics that never appear anywhere point at the client side, not here:
no `*_ram` means the memory measurement is switched off (`LXC_RAM="off"`
or `LXC_METRICS` without `ram`), and no `*_netin`/`*_netout` means
`lxc-info` is not installed on the client — on OpenWrt it is a package
of its own (`opkg install lxc-info`).

## Alerting

The column is red when a container that is supposed to run is not
running (see the client-side [README](../README.md) for how "supposed
to run" is determined), so the usual `alerts.cfg` rules apply:

```
HOST=turris.example.com COLUMN=lxc
    MAIL admin@example.com REPEAT=1h
```

A container that is restarted by hand goes red for one poll interval. A
`DURATION>10m` clause keeps those out of your inbox while still catching
one that stays down:

```
HOST=* COLUMN=lxc DURATION>10m
    MAIL admin@example.com REPEAT=1h
```
