# btrfs — Xymon **server** configuration

The extension sends a `data` message with one `NAME : VALUE` line per
filesystem and metric (`root_unalloc : 2097152`, `root_metapct : 84.94`,
`media_raid_write_bps : 2218444`, …). The Xymon server turns those into
RRD files and graphs via **split-NCV**. This is a one-time setup on the
Xymon server host.

On Debian/Ubuntu the `my-xymon-extensions-server` package installs both
files below; otherwise copy them by hand. Both are **drop-in files**:
nothing in a stock Xymon config file has to be edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform.

## 1. xymonserver.d/btrfs.cfg

```sh
cp xymonserver.d/btrfs.cfg /etc/xymon/xymonserver.d/
```

```
TEST2RRD+=",btrfs=ncv"
SPLITNCV_btrfs="*:GAUGE"
GRAPHS+=",btrfsspace,btrfsfill,btrfserrors,btrfsbps,btrfsiops,btrfsbusy,btrfscommits,btrfscommitms"
GRAPHS_btrfs="btrfsspace,btrfsfill,btrfserrors,btrfsbps,btrfsiops,btrfsbusy,btrfscommits,btrfscommitms"
```

Split-NCV gives each metric of each filesystem its **own** RRD file, so
adding or removing a filesystem never disturbs the graphs of another
one. All metrics are gauges: the extension converts the cumulative I/O
and commit counters into rates itself and skips a poll whose counter
went backwards (reboot, remount), so no `COUNTER`/`DERIVE` handling is
needed.

No `rrddefinitions.d` file: the metrics are levels and averages, not
single events, so Xymon's default AVERAGE archives are right.

## 2. graphs.d/btrfs.cfg

```sh
cp graphs.d/btrfs.cfg /etc/xymon/graphs.d/
```

Eight graphs, each driven by an `FNPATTERN` that picks up however many
filesystems a host has. `<fs>` is the filesystem's name in the status:
its label, else its mount point (`/` → `root`, `/media/raid` →
`media_raid`), or the `BTRFS_NAMES` override.

| Graph | RRD files | shows |
|---|---|---|
| `btrfsspace` | `btrfs,<fs>_unalloc.rrd`, `btrfs,<fs>_free.rrd` | unallocated device space and estimated free space, bytes |
| `btrfsfill` | `btrfs,<fs>_datapct.rrd`, `btrfs,<fs>_metapct.rrd` | usage of the allocated data / metadata chunks, % |
| `btrfserrors` | `btrfs,<fs>_errors.rrd` | sum of the device error counters |
| `btrfsbps` | `btrfs,<fs>_read_bps.rrd`, `btrfs,<fs>_write_bps.rrd` | throughput of the member devices, bytes/s |
| `btrfsiops` | `btrfs,<fs>_read_iops.rrd`, `btrfs,<fs>_write_iops.rrd` | I/O operations of the member devices |
| `btrfsbusy` | `btrfs,<fs>_busy.rrd` | utilisation of the busiest member device, % |
| `btrfscommits` | `btrfs,<fs>_commits.rrd` | transaction commits per minute |
| `btrfscommitms` | `btrfs,<fs>_commitms.rrd` | average commit duration, ms |

The graphs appear on the `btrfs` status page. The trends page finds
graphs by matching the graph name against the start of the RRD file
name, which these names never do — that is why every graph is listed
in `GRAPHS_btrfs`.

## 3. Restart

Restart the Xymon server — a restart, not a reload: on Debian/Ubuntu
the list of included drop-in files under `xymonserver.d/` is
regenerated at start.

## 4. Verify

```sh
ls $XYMONVAR/rrd/<host>/btrfs,*
```

Expect five files per filesystem after the first poll (`unalloc`,
`free`, `datapct`, `metapct`, `errors`) and the rates from the second
poll on, e.g.:

```
btrfs,root_busy.rrd      btrfs,root_errors.rrd     btrfs,root_read_iops.rrd
btrfs,root_commitms.rrd  btrfs,root_free.rrd       btrfs,root_unalloc.rrd
btrfs,root_commits.rrd   btrfs,root_metapct.rrd    btrfs,root_write_bps.rrd
btrfs,root_datapct.rrd   btrfs,root_read_bps.rrd   btrfs,root_write_iops.rrd
```

No `*_commits`/`*_commitms` means the client's kernel is older than 6.0
(no `commit_stats` in sysfs); no `*_errors` means it is older than 5.14.

## Alerting

The column is red for a missing or read-only device, a degraded mount,
a device error counter that grew within the last 30 minutes, an
uncorrectable scrub error, and metadata that is about to run out
(`BTRFS_META_CRIT`), so the usual `alerts.cfg` rules apply:

```
HOST=* COLUMN=btrfs COLOR=red
    MAIL admin@example.com REPEAT=1h
```

Yellow covers states that need attention but not a pager: device errors
on record, little unallocated space, an old scrub. Alert on those
separately if you want them by mail:

```
HOST=* COLUMN=btrfs COLOR=yellow DURATION>1h
    MAIL admin@example.com REPEAT=24h
```
