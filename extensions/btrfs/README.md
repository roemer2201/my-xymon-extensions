# btrfs — btrfs filesystem health

Xymon client extension that reports every mounted **btrfs** filesystem
of a host in one status column, with a `data` message for RRD graphing:
device state and error counters, the space btrfs can still allocate,
metadata usage, the last scrub, and performance (throughput, IOPS,
device utilisation, transaction commits).

- **Column:** `btrfs` (override with `BTRFS_COLUMN`).
- **Platforms:** Linux — Ubuntu, and OpenWrt/TurrisOS through the
  standalone runner (the Turris Omnia's root filesystem is btrfs).
  Rocky Linux/RHEL kernels have no btrfs since RHEL 8; there, like on
  FreeBSD and on every host without a mounted btrfs, the column is
  `clear`.
- **Default:** the task ships **enabled** in all client packages. It
  needs no configuration and **no root rights** for everything but the
  result of the last scrub (see [Scrub](#scrub)).
- **Colors:** `red` for a missing or read-only device, a filesystem the
  kernel switched to read-only, a degraded mount, a device error
  counter that just grew, uncorrectable scrub errors and metadata that
  is about to run out; `yellow` for device errors on record, too little
  unallocated space, an old or missing scrub; `clear` when not
  applicable or switched off. Thresholds and colors are configurable.

## What is checked

| Check | Source | Color |
|---|---|---|
| Device missing / not writeable | `devinfo/<devid>/missing`, `writeable` | red |
| Read-only filesystem | every mount of the filesystem has `ro` in `/proc/mounts` | red, unless listed in `BTRFS_RO_OK` |
| Degraded mount | mount option `degraded` | red |
| Device error counters | `devinfo/<devid>/error_stats` | `BTRFS_ERR_COLOR` (yellow) while above 0; `BTRFS_ERR_NEW_COLOR` (red) for `BTRFS_ERR_HOLD` seconds (1800) after a counter grew |
| Unallocated space | device size minus `allocation/*/disk_total` | below `BTRFS_UNALLOC_WARN` % (5) yellow, `BTRFS_UNALLOC_CRIT` red (off) |
| Metadata | `allocation/metadata/` and `global_rsv_size` | only while no new metadata chunk fits into the unallocated space: from `BTRFS_META_WARN` % (75) yellow, `BTRFS_META_CRIT` % (90) red |
| Mixed profiles | more than one profile directory per type, e.g. `single` + `raid1` | yellow (an interrupted `balance -convert`), except while a balance runs |
| Last scrub | `btrfs scrub status -R` (root), else the status file's mtime | older than `BTRFS_SCRUB_MAXAGE` days (35) or never: `BTRFS_SCRUB_COLOR` (yellow); corrected errors yellow, uncorrectable errors red |
| Running operation | `exclusive_operation` | shown only (balance, device add/remove/replace, resize, ...) |
| Performance | `/proc/diskstats` of the member devices, `commit_stats` | graphed and shown, never alarms |

All paths are below `/sys/fs/btrfs/<uuid>/` (see btrfs-progs
`Documentation/ch-sysfs.rst`). The error counters, the allocation
directories per type and `exclusive_operation` need **kernel 5.14**,
`commit_stats` **kernel 6.0**. On an older kernel the missing parts are
reported as "not available" and the rest still works.

### Why unallocated space and metadata

btrfs does not hand out free space byte by byte: it allocates *chunks*
(typically 1 GiB of data or 256 MiB–1 GiB of metadata) and fills them.
Once every byte of the devices belongs to some chunk, *unallocated* is
zero and no new chunk can be created. Data chunks that are only partly
used do not help the metadata: when the metadata chunks fill up, writes
fail with `ENOSPC` although `df` still reports free space. That is
exactly the situation the Xymon `disk` column cannot see.

The extension therefore checks the metadata only when no new metadata
chunk fits into the unallocated space any more (chunk size × the
metadata profile's copies, e.g. 2 × 1 GiB for RAID1/DUP), and counts
the global reserve as used — it is carved out of the metadata and not
available for ordinary writes. While a new chunk still fits, a full
metadata chunk is no problem: btrfs simply allocates another one.

The remedy, shown as a hint in the status: give partly used data chunks
back with a filtered balance, e.g.

```sh
btrfs balance start -dusage=10 /      # then 25, 50 if not enough
```

The space check uses the RAID profile of the filesystem as it is: with
RAID1 a new metadata chunk needs room on two devices. The extension
cannot see how the unallocated space is spread over the devices without
root rights, so it compares against the total.

### Device error counters

The kernel counts write, read, flush, corruption and generation errors
per device and keeps them in the filesystem across reboots — the same
numbers `btrfs device stats` prints. A counter above zero is yellow; a
counter that **grew** since the previous poll is red for
`BTRFS_ERR_HOLD` seconds. Once the cause is dealt with, reset them:

```sh
btrfs device stats -z /media/raid
```

The kernel names devices by **devid** here, not by device node. The
mapping needs root rights (`btrfs filesystem show`); the status lists
the device nodes of the filesystem next to it.

### Scrub

`btrfs scrub status` needs root rights: its status file
`/var/lib/btrfs/scrub.status.<uuid>` is mode 0600, and the ioctl
behind it requires `CAP_SYS_ADMIN`.

- **As root** (the standalone runner on OpenWrt/TurrisOS) the extension
  reads it directly: start time, status, duration and the error
  counters.
- **As user `xymon`** (Xymon client on Ubuntu) it uses `sudo -n` when
  `BTRFS_SUDO="yes"` and the rule from [sudoers.example](sudoers.example)
  is installed.
- **Without either** the age of the last scrub still comes from the
  modification time of the status file (its directory is readable for
  everybody); the result is unknown.

A filesystem without a status file counts as never scrubbed. On
OpenWrt/TurrisOS `/var` is a RAM disk, so the status file is gone after
a reboot — as root the extension asks btrfs-progs instead, which then
also reports "no stats available". Schedule scrubs (monthly is common;
the Ubuntu package `btrfsmaintenance` does that) or set
`BTRFS_SCRUB_MAXAGE` to match your interval, or to `0` to switch the age
check off.

### Device size

Unallocated space is the device size minus everything allocated. The
size comes from `btrfs filesystem usage -b` (works as an ordinary
user). Without btrfs-progs the sum of the member block devices is used,
which is the same unless the filesystem was shrunk with
`btrfs filesystem resize`. The status names the source.

### Performance

From the second poll on, per filesystem:

- read and write throughput and IOPS — the sum over the member devices
  from `/proc/diskstats` (fields as in the kernel's
  `Documentation/admin-guide/iostats.rst`). RAID copies count: a RAID1
  filesystem writes every byte twice. For bcache-backed devices these
  are the bcache devices, i.e. what btrfs sees.
- utilisation of the **busiest** member device (time with I/O in
  flight), which shows the device that limits the filesystem
- transaction commits per minute and their average duration in the poll
  interval (`commit_stats`, kernel 6.0+); the longest commit since mount
  is shown in the status

A counter that went backwards (reboot, remount, device replaced) skips
one poll instead of producing a negative rate.

## Configuration

`$XYMONHOME/etc/my-xymon-extensions/btrfs.cfg` (Debian/Ubuntu:
`/etc/xymon/my-xymon-extensions/btrfs.cfg`), POSIX shell; every setting
can also come from the environment, the file wins. See the shipped
[btrfs.cfg](btrfs.cfg) for all of them. The most important:

| Setting | Default | Meaning |
|---|---|---|
| `BTRFS_NAMES` | — | `"<uuid>=<name> ..."`: name a filesystem in status and graphs |
| `BTRFS_EXCLUDE` | — | UUIDs or names (globs) not monitored |
| `BTRFS_RO_OK` | — | UUIDs or names (globs) read-only on purpose |
| `BTRFS_UNALLOC_WARN` / `_CRIT` | `5` / — | unallocated space, percent of the device size |
| `BTRFS_META_WARN` / `_CRIT` | `75` / `90` | metadata usage incl. global reserve, percent |
| `BTRFS_ERR_COLOR` / `_NEW_COLOR` / `_HOLD` | `yellow` / `red` / `1800` | device error counters |
| `BTRFS_SCRUB_MAXAGE` / `_COLOR` | `35` / `yellow` | days since the last scrub |
| `BTRFS_SUDO` | `no` | read the scrub result via `sudo -n` |

A filesystem is named after its label; without one after its shortest
mount point (`/` → `root`, `/media/raid` → `media_raid`), sanitized to
`[a-z0-9_]`. A filesystem mounted several times (subvolumes) is
reported once.

## Status message

Real data from an Ubuntu 22.04 workstation (second poll, run as user
`xymon`):

```
status wsrbreb.btrfs red ... - btrfs: media_raid: device errors on devid 6 growing, last scrub 80 days ago; root: unallocated 0.0 %, metadata 84.9 % full, never scrubbed

&red media_raid  /media/raid  (2221fe30-7ed7-4cee-9109-ed341b266b30)
   Devices: 6 (bcache0 bcache1 bcache2 bcache3 bcache4 bcache5)   Profiles: data RAID1, metadata RAID1, system RAID1
&red devid 6: read 3 - grew by 1 since the previous poll
   Device errors: none on devid 1 2 3 4 7
   Size: 10.92 TiB, allocated 9.63 TiB, unallocated 1.29 TiB (11.8 %)   [device size from btrfs filesystem usage]
   Data: 4.80 TiB used of 4.81 TiB allocated (99.8 %), free (estimated) 670.23 GiB
   Metadata: 6.87 GiB used + 512.00 MiB global reserve of 8.00 GiB allocated (92.1 %) - can grow into unallocated space
   System: 720.00 KiB used of 32.00 MiB allocated
&yellow Scrub: last activity 80 day(s) ago (modification time of /var/lib/btrfs/scrub.status.<uuid>), result unknown  [yellow > 35 days]
   I/O: read 23.38 KiB/s (1.4 IOPS), write 2.12 MiB/s (73.9 IOPS), busiest device bcache3 1.0 %  [member devices, RAID copies included]
   Commits: 1.7 per minute, 148 ms on average since the previous poll; last 115 ms, longest 9286 ms since mount

&yellow root  / /home  (38065fdd-24e0-449b-9f6a-b778cba05bc3)
   Devices: 2 (nvme1n1p3 nvme2n1p3)   Profiles: data RAID1, metadata RAID1, system RAID1
   Device errors: none on devid 1 2
   Size: 1.81 TiB, allocated 1.81 TiB, unallocated 2.00 MiB (0.0 %)   [device size from btrfs filesystem usage]
&yellow Unallocated space below 5 % - btrfs can hardly allocate new chunks
   Data: 682.82 GiB used of 919.04 GiB allocated (74.3 %), free (estimated) 236.22 GiB
&yellow Metadata: 8.02 GiB used + 512.00 MiB global reserve of 10.03 GiB allocated (84.9 %) - NO room for a new metadata chunk (needs 2.00 GiB unallocated)  [yellow >= 75 %]
   System: 176.00 KiB used of 32.00 MiB allocated
   Hint: 236.22 GiB of the data chunks are unused; "btrfs balance start -dusage=10 /" (then 25, 50) returns partly used data chunks to the unallocated space
&yellow Scrub: no record (no status file in /var/lib/btrfs), result unknown  [yellow: never scrubbed]
   I/O: read 1.45 KiB/s (0.1 IOPS), write 1.10 MiB/s (52.2 IOPS), busiest device nvme2n1p3 59.1 %  [member devices, RAID copies included]
   Commits: 2.0 per minute, 72 ms on average since the previous poll; last 71 ms, longest 4663 ms since mount

btrfs-progs: /usr/bin/btrfs; scrub result not read (needs root rights: BTRFS_SUDO="yes" and the rule from sudoers.example).
```

(The read error on devid 6 grew from 2 to 3 for the illustration; on the
real host it stays at 2 and the line is yellow.)

## Metrics (NCV names)

One line per filesystem and metric in a separate `data` message,
`<fs>_<metric> : <value>`; the Xymon server stores each in its own RRD
file `btrfs,<fs>_<metric>.rrd` (split-NCV, see
[server/README.md](server/README.md)).

| Metric | Unit | |
|---|---|---|
| `unalloc` | bytes | unallocated device space (raw, all copies) |
| `free` | bytes | estimated free space for data (like `btrfs filesystem usage`) |
| `datapct` | % | usage of the allocated data chunks |
| `metapct` | % | usage of the allocated metadata chunks incl. global reserve |
| `errors` | count | sum of all device error counters |
| `read_bps`, `write_bps` | bytes/s | member devices, from the second poll on |
| `read_iops`, `write_iops` | 1/s | member devices, from the second poll on |
| `busy` | % | busiest member device, from the second poll on |
| `commits` | 1/min | transaction commits, from the second poll on (kernel 6.0+) |
| `commitms` | ms | average commit duration in the poll interval (kernel 6.0+) |

## Manual test

```sh
sudo -u xymon sh /usr/lib/xymon/client/ext/btrfs.sh     # Debian/Ubuntu
```

Running it as `xymon` shows what the client sees (as root the scrub
result is read directly). Without the Xymon environment the messages
are printed to stdout instead of being sent, and the state file goes to
`/tmp` instead of the client's `$XYMONTMP`. The first run only records
the counters; run it twice to see the rates.
