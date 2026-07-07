# diskio — local disk I/O metrics (throughput, latency, IOPS, saturation)

Xymon client extension that measures local block-device I/O — read/write
throughput, per-operation latency, IOPS, utilization and queue depth —
and feeds the values into the Xymon server's RRD graphs (trends column).
It covers both **physical disks** and **aggregated volumes** (md-RAID,
LVM, ZFS pools, dm-crypt), each as its own graph instance, so you can
see whether a slow RAID is caused by a single member disk.

- **Column:** `diskio`
- **Platforms:** Ubuntu, Rocky Linux/EL, FreeBSD
- **Default behavior:** graph-only — the column stays `green`;
  optional latency/utilization thresholds can be enabled per device in
  `diskio.cfg`
- **Requires:** no extra tools on Linux (`/proc/diskstats` + `/sys`);
  `gstat` on FreeBSD (base system); `zpool` only when ZFS pools exist

## Metrics

All values are averages over the measurement interval (see
"How rates are measured" below), sent as ready-to-graph GAUGE values.

| Metric  | Meaning                                        | Unit    |
|---------|------------------------------------------------|---------|
| `rbps`  | read throughput                                | bytes/s |
| `wbps`  | write throughput                               | bytes/s |
| `riops` | read operations per second                     | ops/s   |
| `wiops` | write operations per second                    | ops/s   |
| `rlat`  | avg. time per read op (incl. queue wait)       | ms      |
| `wlat`  | avg. time per write op (incl. queue wait)      | ms      |
| `util`  | share of wall time the device was busy         | %       |
| `qlen`  | avg. number of in-flight/queued requests       | count   |

Notes:

- `rlat`/`wlat` are *averages per completed operation over the whole
  interval* — a single 5-minute value smooths out short spikes. That is
  inherent to RRD-style trending and acceptable for capacity/health
  trending; it is not a substitute for `blktrace`-style analysis.
- `util` saturates at 100 % for a single disk but is misleading for
  striped/parallel devices (a 4-disk stripe can be "100 % busy" and
  still have headroom) — that is why the member disks are graphed too.
- ZFS pools report `rbps`/`wbps`/`riops`/`wiops`/`rlat`/`wlat` only;
  the kernel does not expose `util`/`qlen` at pool level.

## Device layers and instance naming

Every monitored device becomes one *instance*, named
`<layer>_<name>` (sanitized to `[a-z0-9_]`, so LV `vg0/root` becomes
`lv_vg0_root`):

| Prefix | Layer                          | Examples                        | Source                          |
|--------|--------------------------------|---------------------------------|---------------------------------|
| `pd_`  | physical disk / whole device   | `pd_sda`, `pd_nvme0n1`, `pd_ada0` | `/proc/diskstats`, `gstat`    |
| `md_`  | Linux md software RAID         | `md_md0`                        | `/proc/diskstats`               |
| `lv_`  | LVM logical volume             | `lv_vg0_root`                   | `/proc/diskstats` (dm-*)        |
| `cr_`  | dm-crypt / LUKS mapping        | `cr_cryptdata`                  | `/proc/diskstats` (dm-*)        |
| `dm_`  | other device-mapper targets    | `dm_mpatha` (multipath, …)      | `/proc/diskstats` (dm-*)        |
| `zp_`  | ZFS pool                       | `zp_tank`                       | `zpool iostat`                  |
| `gm_`  | FreeBSD GEOM mirror/raid       | `gm_gm0`                        | `gstat`                         |

- Both layers are reported by default: a box with an md-RAID over four
  disks yields `pd_sda…pd_sdd` **and** `md_md0`. The layer set is
  configurable (`LAYERS` in `diskio.cfg`).
- **Partitions are not monitored** — only whole devices and mapped
  volumes. Partition traffic is contained in the whole-device numbers.
- **btrfs:** a multi-device btrfs performs its own striping/mirroring
  in the filesystem, and the kernel exposes no aggregate block-layer
  counters for it. Its *member devices* are covered as `pd_*`
  instances; there is no `btrfs_*` aggregate instance in v1 (see
  CLAUDE.md, "Out of scope").

## How rates are measured

- **Linux:** the kernel counters in `/proc/diskstats` are cumulative.
  The extension keeps the previous counters in a state file under
  `$XYMONTMP` and computes true averages over the full interval between
  two runs (default 5 min) — no sampling window, no missed spikes
  between samples. The very first run (and the first run after a
  reboot or counter wrap) only stores the baseline and reports no data
  for the affected device.
- **FreeBSD:** the base system exposes no shell-parseable cumulative
  counters, so the extension takes one `gstat -b` batch sample of
  `SAMPLE_SECONDS` (default 10 s) per run. This measures a window, not
  the full interval — documented platform difference.
- **ZFS pools** (both OSes): one `zpool iostat -Hpl` sample of
  `SAMPLE_SECONDS`, using the `total_wait` latencies.

## Configuration (`diskio.cfg`, optional)

Read from `$XYMONHOME/etc/diskio.cfg`; the extension works without it.

```sh
# Layers to report (default: all detected)
LAYERS="pd md lv cr dm zp gm"

# Device name patterns to skip (shell patterns, matched against the
# bare kernel/mapper/pool name). Default skips pseudo devices:
EXCLUDE="loop* ram* sr* fd* cd* zram* zd* nbd* pass*"

# Only monitor matching devices (empty = all not excluded)
INCLUDE=""

# FreeBSD gstat / zpool iostat sampling window in seconds (1..60)
SAMPLE_SECONDS=10

# Optional alerting — default: none, column stays green.
# threshold <instance-pattern> <metric> <warn> <crit>
#threshold "pd_*"  rlat 50 200      # ms
#threshold "pd_*"  wlat 50 200      # ms
#threshold "zp_*"  rlat 100 500
#threshold "*"     util 95 -        # "-" = no red threshold
```

A device (instance) that violates a `threshold` line turns the column
yellow/red and is flagged in the status text; the first matching
`threshold` line wins per value. Without `threshold` lines the column
is always `green` — or `clear` when the platform offers no usable
data source at all.

## Status column content

The `diskio` status message shows a per-instance table of the current
interval (device, r/w MB/s, r/w IOPS, r/w latency, util, queue), plus
notes for devices skipped this run (baseline collection after
boot/first run, counter wrap). Threshold violations, if configured,
are listed first with their measured values.

## Server-side setup (graphs)

Exactly like the `smart` extension, the client sends one `data`
message per run with `NAME : VALUE` lines
(`pd_sda_rbps : 52428800`, `md_md0_rlat : 4.2`, …) and the server
turns them into one RRD per instance and metric via **split-NCV**:

```
TEST2RRD="...,diskio=ncv"
SPLITNCV_diskio="*:GAUGE"
GRAPHS="...,diskiorbps,diskiowbps,diskioriops,diskiowiops,diskiorlat,diskiowlat,diskioutil,diskioqlen"
GRAPHS_diskio="diskiorbps,diskiowbps,diskiorlat,diskiowlat"
```

Graph definitions are shipped in
[`server/graphs-diskio.cfg`](server/graphs-diskio.cfg) (one graph per
metric, all instances as lines — same pattern as the smart
extension), and [`server/README.md`](server/README.md) contains the
full walk-through.

## Client installation

1. Copy `diskio.sh` to `$XYMONHOME/ext/diskio.sh` (executable).
2. Optional: copy `diskio.cfg` to `$XYMONHOME/etc/diskio.cfg`.
3. Install the `tasks.d` snippet
   (`packaging/common/tasks.d/diskio.cfg`, `INTERVAL 5m`), restart
   the Xymon client.
4. Do the one-time server-side setup above.

The packages built from this repository do steps 1–3 automatically.

### Manual test run

```sh
sh extensions/diskio/diskio.sh
```

Without the Xymon environment variables the script prints the status
and data messages to stdout instead of sending them. Remember that on
Linux the first run only stores the baseline — run it twice (at least
30 seconds apart) to see values.

No root/sudo is required on Linux (`/proc/diskstats` is world-readable)
or for `zpool iostat`. FreeBSD `gstat` needs read access to
`/dev/devstat` (works for the xymon user on stock installs; documented
fallback: `clear` status with a hint).

## Platform notes and caveats

- **md-RAID `util`/`qlen`:** the md layer does not account busy time on
  all kernels; `util` for `md_*` instances may read 0 there. The
  member-disk `pd_*` values are always correct.
- **dm device numbering** (`dm-0`, `dm-1`, …) is not stable across
  reboots; instances are therefore keyed by their *resolved* LV/crypt
  name, never by `dm-N`.
- **Latency includes queue time** (Linux counters measure completion
  minus submission). A saturated device shows rising latency even if
  the medium itself is healthy — that is intentional for this metric.
- **VM disks** (`vd*`, `xvd*`) are treated as physical (`pd_`).
- Values are 5-minute averages; short bursts are visible in `qlen`
  and latency rather than in throughput peaks.
