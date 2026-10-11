# bcache — Linux block layer cache

Xymon client extension that reports the **bcache** devices of a host in
one status column, with a `data` message for RRD graphing: the cache
sets, their cache device (SSD) and every backing device (HDD) — their
state, dirty data, hit ratio, cache usage and throughput.

- **Column:** `bcache` (override with `BCACHE_COLUMN`).
- **Platforms:** Linux with bcache (`CONFIG_BCACHE`, e.g. Ubuntu).
  Everything is read from sysfs: no tool, no root rights (the attributes
  are mode 0444). Hosts without bcache report `clear`. Not tested on
  OpenWrt/TurrisOS and not in the standalone runner's default list.
- **Reference system:** Ubuntu 24.04, kernel 6.8, one cache set on an
  NVMe partition, six HDD backing devices in writeback mode (the test
  fixtures are recorded there).
- **Ships disabled:** uncomment the task in `clientlaunch.d/bcache.cfg`
  on a bcache host and restart the client.

## What is checked

Sources are the kernel's `Documentation/admin-guide/bcache.rst` and,
where it is outdated, `drivers/md/bcache/` (sysfs.c, super.c,
writeback.h).

| Condition | Color |
|---|---|
| backing device `state` is `inconsistent` (it was forced to run while the cache held its dirty data; the documentation says its data has "likely been corrupted") | red |
| backing device in state `clean`/`dirty` but not attached to a cache set — its cache device is missing | red |
| backing device registered but not running (`running=0`, no `/dev/bcacheN`) | red |
| `io_disable` set on a backing device or a cache set | red |
| cache usage above `cutoff_writeback_sync` while a device caches in writeback mode: no write is cached any more | red (`BCACHE_CUTOFF_SYNC_COLOR`) |
| a cache set or backing device seen before has vanished | red (`BCACHE_VANISHED_COLOR`) |
| fewer backing devices than `BCACHE_MIN_BDEVS` (off by default) | red |
| `io_errors` > 0 on a cache or backing device | yellow (`BCACHE_IOERR_COLOR`) |
| cache usage above `cutoff_writeback`: only synchronous writes are cached | yellow (`BCACHE_CUTOFF_COLOR`) |
| writeback mode with `writeback_running=0` | yellow |
| backing device in state `no cache` | yellow (`BCACHE_NOCACHE_COLOR`) |
| `cache_mode` other than `BCACHE_MODE` (off by default) | yellow (`BCACHE_MODE_COLOR`) |
| hit ratio of a cache set below `BCACHE_HIT_YELLOW`/`BCACHE_HIT_RED` (off by default) | yellow / red |

"Cache usage" is `100 - cache_available_percent`, the share of the
cache that holds dirty data or metadata as of the last garbage
collection. `should_writeback()` compares exactly this value with
`internal/cutoff_writeback` (kernel default 40) and
`internal/cutoff_writeback_sync` (default 70); both are read from sysfs,
not assumed.

### Why devices are found the way they are

Backing devices are searched in `/sys/block/*/bcache` and
`/sys/block/*/*/bcache` (partitions), not through `/sys/block/bcacheN`:
a backing device in state `clean` or `dirty` whose cache set is missing
is registered but **never started** (`register_bdev()` in super.c starts
only devices in state `no cache` or `inconsistent` right away), so it
has no `bcacheN` at all. That
is exactly the situation after a cache device failure at boot, and it
must not look like "no bcache here".

### Vanished devices

If the cache device fails while the system runs, the cache set is shut
down (`errors=unregister`). Backing devices with dirty data are then
**stopped** with the default `stop_when_cache_set_failed=auto`
(`conditional_stop_bcache_device()`), and they disappear from sysfs
completely — nothing is left to look at. Clean ones keep running
without a cache.

To catch that, the extension remembers the UUID of every cache set and
backing device it has seen in a state file, `bcache.<host>.state` in
`BCACHE_STATEDIR` (default `$XYMONTMP`). A UUID that disappears turns
the column red until the device comes back, or until you acknowledge it
with `BCACHE_FORGET="<uuid or first 8 hex digits>"`.

**If `$XYMONTMP` is a tmpfs**, the state file is lost at every reboot,
and a device that is missing right after a reboot (e.g. a dead HDD) goes
unnoticed. Set `BCACHE_STATEDIR` to a directory on disk the Xymon client
user may write to (`findmnt -T /var/lib/xymon/tmp` tells you which case
you have). `BCACHE_MIN_BDEVS` works without any state file.

Kernels without `backing_dev_uuid` (it is there in 6.8) fall back to the
device name for the RRD file names and are not tracked for vanishing,
because `sdX` names are not stable.

## Names: UUIDs, not bcacheN

`bcacheN` and `sdX` are assigned in the order the devices are found and
can change at every boot (on the reference system `bcache0` is `sdf`,
which is `bdev4` of its cache set). The graphs therefore use the first
8 hex digits of the **backing device UUID** (`backing_dev_uuid` from
its superblock — the same UUID udev uses in `/dev/bcache/by-uuid/`) and
of the **cache set UUID** (the directory name in `/sys/fs/bcache/`).
The cache device itself has a UUID of its own, but sysfs does not show
it; since a cache set has exactly one cache device in current kernels,
the cache set UUID identifies it.

To find a device: `ls -l /dev/bcache/by-uuid/`, or the status page,
which lists `bcacheN`, `sdX` and the id side by side.

## Metrics (NCV names)

Per backing device (`<id>` = first 8 digits of its UUID):

| Name | Unit | Source |
|---|---|---|
| `<id>_hitpct` | % | `stats_total/cache_hits`/`cache_misses`, difference since the previous poll |
| `<id>_dirty` | GiB | `dirty_data` |
| `<id>_target` | GiB | `writeback_rate_debug` target (writeback mode only) |
| `<id>_wbrate` | KiB/s | `writeback_rate` (writeback mode only) |
| `<id>_rdbytes`, `<id>_wrbytes` | MiB/s | `/sys/block/bcacheN/stat`, sectors read/written |
| `<id>_rdops`, `<id>_wrops` | 1/s | `/sys/block/bcacheN/stat`, I/Os completed |

Per cache set (`<id>` = first 8 digits of the set UUID):

| Name | Unit | Source |
|---|---|---|
| `<id>_hitpct` | % | `stats_total`, all backing devices together |
| `<id>_hits`, `<id>_misses`, `<id>_bphits`, `<id>_bpmisses` | 1/s | `stats_total/cache_{hits,misses,bypass_hits,bypass_misses}` |
| `<id>_inuse` | % | `100 - cache_available_percent` |
| `<id>_cutwb`, `<id>_cutsync` | % | `internal/cutoff_writeback`, `internal/cutoff_writeback_sync` |
| `<id>_bkunused`, `<id>_bkclean`, `<id>_bkdirty`, `<id>_bkmeta` | % | `priority_stats` of the cache device |
| `<id>_ssdrd`, `<id>_ssdwr` | MiB/s | `stat` of the cache device's partition |
| `<id>_btused`, `<id>_btroot` | % | `internal/btree_used_percent`, `root_usage_percent` (`BCACHE_INTERNAL="yes"`) |

Notes on the numbers:

- The `stats_five_minute`/`stats_hour`/`stats_day` directories are
  **not** time windows but exponentially decaying sums (half-lives of
  5 min, 1 h, 1 day; see the comment at the top of `stats.c`). The
  extension uses the exact `stats_total` counters and computes the
  difference between two polls instead. Requests are counted per I/O as
  bcache sees it; a partial hit counts as a miss.
- Byte values like `dirty_data` or `written` come out of `bch_hprint()`
  with about three significant digits (`9.6G`, `2.5T`, units of 1024).
  Fine for a gauge — the dirty data graph moves in steps of 0.1 GiB —
  but useless as the basis of a rate, which is why `bypassed` (bytes)
  and `written` are not graphed and the throughput comes from the
  `stat` files.
- Below its target, bcache writes dirty data back at the minimum rate
  only (`writeback_rate` 4.0k on the reference system), so the
  `bcachewb` graph is mostly flat; the target in `bcachedirty` says
  more. The target is `writeback_percent` of the cache, split between
  the backing devices by their size (`__calc_target_rate()`).
- `internal/writeback_keys_failed` is not an error counter: it counts
  btree insert collisions during writeback (`trace_bcache_writeback_collision`
  in writeback.c) and is neither shown nor graphed.

## Configuration

`$XYMONHOME/etc/my-xymon-extensions/bcache.cfg`
(Debian/Ubuntu: `/etc/xymon/my-xymon-extensions/bcache.cfg`). Every
setting can also come from the environment; the config file wins.

| Variable | Default | Meaning |
|---|---|---|
| `BCACHE_COLUMN` | `bcache` | Xymon column name |
| `BCACHE_STATEDIR` | `$XYMONTMP` | where the state file lives; put it on disk if `$XYMONTMP` is a tmpfs |
| `BCACHE_FORGET` | — | UUIDs or 8-digit prefixes of devices removed on purpose |
| `BCACHE_VANISHED_COLOR` | `red` | color of a vanished device (`red`/`yellow`/`green`) |
| `BCACHE_MIN_BDEVS` | — | minimum number of backing devices |
| `BCACHE_MODE` | — | expected `cache_mode` (`writethrough`, `writeback`, `writearound`, `none`) |
| `BCACHE_MODE_COLOR` | `yellow` | color of a device in another mode |
| `BCACHE_NOCACHE_COLOR` | `yellow` | color of a backing device in state `no cache` |
| `BCACHE_IOERR_COLOR` | `yellow` | color of `io_errors` > 0 |
| `BCACHE_CUTOFF_COLOR` | `yellow` | usage above `cutoff_writeback` |
| `BCACHE_CUTOFF_SYNC_COLOR` | `red` | usage above `cutoff_writeback_sync` |
| `BCACHE_HIT_YELLOW`, `BCACHE_HIT_RED` | — | hit ratio thresholds of a cache set, % |
| `BCACHE_HIT_MINREQ` | `1000` | requests a poll needs before the hit ratio is judged |
| `BCACHE_PRIO_STATS` | `yes` | read `priority_stats` (the kernel copies and sorts all bucket priorities for it) |
| `BCACHE_INTERNAL` | `no` | `yes` adds the btree usage graph |
| `BCACHE_SYSFS` | `/sys` | sysfs mount point (tests) |

## Status message

A healthy host (fixture data of the reference system, second poll):

```
&green Cache set 06912c73-4920-4fe7-9cec-cc398e17c092  (graphs: 06912c73)
    6 backing device(s) attached, on error: unregister, io_error_limit 8
    15% in use (writeback caching is reduced above 40% and stops above 70%)
    hit ratio 92% total, 75.0% since the previous poll
    &green cache device nvme0n1p1, 409600 buckets, 2.5T written
      buckets: unused 0%, clean 85%, dirty 14%, metadata 0%
&green bcache0  sdf  17e640c6  writeback  dirty  dirty 9.6G (target 13.3G)  hits 91% total, 90.0% last poll
&green bcache1  sda  5f42606b  writeback  dirty  dirty 9.6G (target 13.3G)  hits 91% total
...
```

The same host after the cache device was missing at boot (status line
`bcache: cache set 06912c73 (nvme0n1p1) vanished (+12 more)`):

```
&red cache set 06912c73-4920-4fe7-9cec-cc398e17c092 (last seen as nvme0n1p1) has vanished

Backing devices without a cache set:
&red (no bcache device)  sda  5f42606b  writeback  clean  dirty 0.0k (target 13.3G)  hits 91% total
    state "clean" but not attached to any cache set - the cache device is missing
    not running: no /dev/bcacheN exists for it (waiting for its cache set?)
&red (no bcache device)  sdb  56f0b7f4  writeback  dirty  dirty 9.6G (target 13.3G)  hits 91% total
    state "dirty" but not attached to any cache set - the cache device is missing and holds dirty data of this device
    not running: no /dev/bcacheN exists for it (waiting for its cache set?)
...
```

The whole status text sits between `<!-- ncv_skipstart -->` and
`<!-- ncv_skipend -->`, so the server's NCV parser graphs nothing from
it; the metrics travel in the separate `data` message.
