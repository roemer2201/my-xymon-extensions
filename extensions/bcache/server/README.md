# bcache — Xymon **server** configuration

The extension sends a `data` message with one `NAME : VALUE` line per
device and metric (`17e640c6_hitpct : 90.0`, `17e640c6_dirty : 9.60`,
`06912c73_inuse : 15`, …). The Xymon server turns those into RRD files
and graphs via **split-NCV**: one file per device and metric, so a
device added later gets files of its own and never disturbs an existing
graph. This is a one-time setup on the Xymon server host.

On Debian/Ubuntu the `my-xymon-extensions-server` package installs both
files below; otherwise copy them by hand. Both are **drop-in files**:
nothing in a stock Xymon config file has to be edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform.

## 1. xymonserver.d/bcache.cfg

```sh
cp xymonserver.d/bcache.cfg /etc/xymon/xymonserver.d/
```

```
TEST2RRD+=",bcache=ncv"
SPLITNCV_bcache="*:GAUGE"
GRAPHS+=",bcachehit,bcacheio,bcachedirty,bcachewb,bcacheuse,bcachetp,bcacheops,bcachessd,bcachebtr"
GRAPHS_bcache="bcachehit,bcacheio,bcachedirty,bcachewb,bcacheuse,bcachetp,bcacheops,bcachessd,bcachebtr"
```

All metrics are gauges. The extension turns the cumulative counters
into rates itself and skips a poll whose counter went backwards
(reboot, `clear_stats`), so no `COUNTER`/`DERIVE` handling is needed
here.

## 2. graphs.d/bcache.cfg

```sh
cp graphs.d/bcache.cfg /etc/xymon/graphs.d/
```

The file names contain an id instead of `bcacheN` or `sdX`, because
those two can change at every boot: the first 8 hex digits of the
backing device UUID (`backing_dev_uuid`, the same UUID as in
`/dev/bcache/by-uuid/`) or of the cache set UUID (the directory name in
`/sys/fs/bcache/`). The status page lists which `bcacheN` and `sdX`
belong to which id.

| Graph | RRD files | shows |
|---|---|---|
| `bcachehit` | `bcache,<id>_hitpct.rrd` | hit ratio since the previous poll, per backing device and per cache set, % |
| `bcacheio` | `bcache,<set>_{hits,misses,bphits,bpmisses}.rrd` | requests per second of a cache set; `bp` = meant to bypass the cache |
| `bcachedirty` | `bcache,<id>_{dirty,target}.rrd` | dirty data per backing device and its writeback target, GiB |
| `bcachewb` | `bcache,<id>_wbrate.rrd` | writeback rate limit of the controller, KiB/s (a limit, not data written) |
| `bcacheuse` | `bcache,<set>_{inuse,cutwb,cutsync,bkunused,bkclean,bkdirty,bkmeta}.rrd` | cache in use against the two writeback cutoffs; buckets by content (`priority_stats`), % |
| `bcachetp` | `bcache,<id>_{rd,wr}bytes.rrd` | throughput of the `bcacheN` device, MiB/s |
| `bcacheops` | `bcache,<id>_{rd,wr}ops.rrd` | I/O operations of the `bcacheN` device, per second |
| `bcachessd` | `bcache,<set>_ssd{rd,wr}.rrd` | reads and writes of the cache device partition, MiB/s |
| `bcachebtr` | `bcache,<set>_bt{used,root}.rrd` | btree usage, only with `BCACHE_INTERNAL="yes"` on the client |

Write volume bcache itself reports (`written`, `btree_written`) is
rounded to three digits by the kernel (`2.5T`) and useless for a rate;
`bcachessd` uses the exact sector counters of the cache partition
instead. Wear of the SSD belongs to the `smart` extension.

## 3. Restart

Restart the Xymon server — a restart, not a reload: on Debian/Ubuntu the
list of included drop-in files under `xymonserver.d/` is regenerated at
start.

## 4. Verify

```sh
ls $XYMONVAR/rrd/<host>/bcache,*
```

Right after the first poll only the gauges exist (`*_dirty`,
`*_target`, `*_wbrate`, `*_inuse`, `*_cutwb`, `*_cutsync`, `*_bk*`). Hit
ratios, request rates and throughput are differences between two polls
and appear one interval later. A hit ratio needs requests: an idle
device has no `*_hitpct` value for that poll (a gap in the graph, not
0 %).

## Alerting

The column is red when bcache is broken — a backing device that is
inconsistent, not running or without its cache set, a disabled cache
set, a device that vanished, or a cache so full that writeback caching
stops — and yellow for I/O errors and softer conditions (see the
client-side [README](../README.md)). Ordinary `alerts.cfg` rules apply:

```
HOST=* COLUMN=bcache
    MAIL admin@example.com COLOR=red REPEAT=1h
```
