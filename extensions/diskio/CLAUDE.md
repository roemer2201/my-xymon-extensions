# CLAUDE.md — diskio extension (implementation notes)

Developer guidance for the `diskio` extension. Read the
repository-level `CLAUDE.md` first — all portability rules apply
unchanged. The user-facing feature description is in
[`README.md`](README.md); this file fixes the *how*.

## Design decisions (agreed with the maintainer)

1. **Metrics:** throughput (`rbps`/`wbps`), latency (`rlat`/`wlat`),
   IOPS (`riops`/`wiops`), utilization (`util`), queue depth (`qlen`).
2. **Rate computation (Linux):** state file + delta over the full run
   interval. Client sends finished GAUGE values; server config is
   plain `SPLITNCV_diskio="*:GAUGE"`. No DERIVE/COUNTER RRDs, no live
   sampling on Linux.
3. **Volume layers:** physical disks *and* logical volumes are both
   reported, as separate instances with a layer prefix
   (`pd_`, `md_`, `lv_`, `cr_`, `zp_`, `gm_`).
4. **Alerting:** none by default (column green); optional
   `threshold` lines in `diskio.cfg`. `clear` when no data source
   exists on the platform.

## File layout

```
extensions/diskio/
├── diskio.sh                  # POSIX sh, #!/bin/sh, set -u
├── diskio.cfg                 # defaults, all optional (see README)
├── README.md                  # (keep in sync with the code!)
├── CLAUDE.md                  # this file
└── server/
    ├── README.md              # split-NCV walk-through (mirrors smart/server)
    └── graphs-diskio.cfg      # 8 graph definitions, FNPATTERN diskio,(.+)_<metric>.rrd
packaging/common/tasks.d/diskio.cfg   # INTERVAL 5m (not 10m — I/O trending wants 5m)
tests/diskio/                  # fixtures + test cfgs (see "Testing")
```

The `packaging/deb`, `packaging/rpm` and `packaging/freebsd` package
definitions do not exist yet (repo-wide TODO, see the top-level
Makefile); when they are created, they must ship the files above. The
extension table in the top-level `README.md` lists diskio.

## Data flow

```
collect (per platform) → normalize to "instance metric value" triples
→ apply INCLUDE/EXCLUDE/LAYERS → thresholds → send:
   1. status message  $XYMON $XYMSRV "status $MACHINE.diskio <color> ..."
   2. data message    $XYMON $XYMSRV "data $MACHINE.diskio\n<name> : <value>..."
```

Data line format (one per instance × metric):
`<instance>_<metric> : <value>` — e.g. `pd_sda_rbps : 52428800`.
Instance names must match `[a-z0-9_]+` (sanitize with `tr`), because
split-NCV derives RRD filenames from them.

## Linux collection (`/proc/diskstats`)

### Parsing

Fields 1–14 (all kernels since 2.6; kernels ≥ 4.18 append discard
fields, ≥ 5.5 flush fields — **parse by position, ignore extras**):

```
1 major  2 minor  3 name
4  reads_completed   5 reads_merged   6 sectors_read    7 ms_reading
8  writes_completed  9 writes_merged 10 sectors_written 11 ms_writing
12 ios_in_progress  13 ms_doing_io   14 weighted_ms_io
```

Use one `awk` pass. Sectors are **always 512 bytes** in diskstats,
regardless of the device's real sector size.

### Metric formulas (Δ = current − previous, `dt` = seconds between runs)

| Metric  | Formula                                   |
|---------|-------------------------------------------|
| `rbps`  | Δsectors_read × 512 / dt                  |
| `wbps`  | Δsectors_written × 512 / dt               |
| `riops` | Δreads_completed / dt                     |
| `wiops` | Δwrites_completed / dt                    |
| `rlat`  | Δms_reading / Δreads_completed (0 if Δreads = 0) |
| `wlat`  | Δms_writing / Δwrites_completed (0 if Δwrites = 0) |
| `util`  | Δms_doing_io / (dt × 1000) × 100, clamp to 100 |
| `qlen`  | Δweighted_ms_io / (dt × 1000)             |

Do the arithmetic in `awk` (needs floating point; POSIX sh arithmetic
is integer-only). Print with fixed `%.1f`/`%.0f` — no locale commas:
force `LC_ALL=C`.

### Device selection

Whole devices only. A `/proc/diskstats` line is a whole device iff
`/sys/block/<name>` exists (partitions only appear under
`/sys/block/<disk>/<part>`). This test is cheaper and more robust than
name-pattern games. Then classify:

| Layer | Test |
|-------|------|
| `md`  | name matches `md[0-9]*` |
| `lv` / `cr` | name matches `dm-[0-9]*` → read `/sys/block/<name>/dm/uuid`: prefix `LVM-` → `lv`, `CRYPT-` → `cr`, other prefixes (mpath, dm-raid…) → keep as `dm` layer, still reported |
| `pd`  | everything else that passes EXCLUDE (sd*, nvme*n*, vd*, xvd*, hd*, mmcblk*) |

For `dm-*`, the **instance name** comes from
`/sys/block/dm-N/dm/name` (e.g. `vg0-root`), sanitized. Never use
`dm-N` as the instance key — the numbering changes across reboots and
would corrupt both the state file matching and the RRD history.

### State file

- Path: `$XYMONTMP/diskio.state` (one per host; `$XYMONTMP` is
  client-private).
- Format, one line per instance:
  `<instance> <epoch> <reads> <sectors_r> <ms_r> <writes> <sectors_w> <ms_w> <ms_io> <weighted_ms>`
- Write to `mktemp`-file in `$XYMONTMP`, then `mv` (atomic; also the
  portable substitute for `sed -i`). Clean the temp file via
  `trap ... EXIT INT TERM`.
- **Always rewrite the full state file** from the current counters,
  even for devices skipped this run.

### Edge cases (must all be handled)

- **First run / new device:** no previous line → store baseline, emit
  no data for that instance, note it in the status text.
- **Reboot or counter wrap:** any Δ < 0, or current epoch ≤ stored
  epoch → treat like first run for that instance.
- **dt sanity:** if `dt < 30` or `dt > 3600`, skip rate computation
  (stale state file, clock jump) and re-baseline.
- **Disappeared device** (hot-unplug): its state line is dropped on
  rewrite; nothing is reported — the RRD simply goes to `unknown`.
- **Δreads = 0:** report `rlat` as 0, not NaN/div-by-zero (idem writes).

## FreeBSD collection (`gstat`)

No shell-accessible cumulative counters → **documented deviation**:
one batch sample per run, `gstat -b -I "${SAMPLE_SECONDS}s"`.
Column mapping (gstat batch output):

```
L(q) → qlen    ops/s → (unused)   r/s → riops   kBps(read) → rbps (×1024)
ms/r → rlat    w/s → wiops        kBps(write) → wbps (×1024)
ms/w → wlat    %busy → util       name → instance
```

- Keep only whole-device providers: `ada[0-9]*`, `da[0-9]*`,
  `nvd[0-9]*`, `nda[0-9]*`, `vtbd[0-9]*`, `mmcsd[0-9]*` → `pd_`;
  `mirror/*`, `raid/*` → `gm_` (strip the `mirror/` prefix).
  Skip partitions/labels (`ada0p2`, `gpt/*`, `label/*`, …).
- gstat needs `/dev/devstat`; if it fails, send `clear` with a hint —
  never a red.
- The `Linux)/FreeBSD)` split is a `case "$(uname -s)"` at the top,
  per repo rules. `*)` → `clear` status ("platform not supported").

## ZFS pools (Linux and FreeBSD, identical code path)

- Detect: `command -v zpool` and `zpool list -H -o name` non-empty.
- Sample: `zpool iostat -Hpl <SAMPLE_SECONDS> 2`, **use only the
  second block** (the first is the since-boot average — useless).
- `-Hp` = script-friendly, exact numbers; `-l` adds latency columns;
  use `total_wait` read/write (ns → ms: ÷ 1e6). Bandwidth columns are
  bytes/s, ops columns are ops/s — no conversion needed.
- If `zpool iostat -l` is unsupported (very old ZFS): fall back to
  `-Hp` without latency, emit throughput/IOPS only.
- No `util`/`qlen` for `zp_*` (not exposed at pool level) — simply
  don't emit those lines; split-NCV copes with per-instance varying
  variable sets.
- The two live samples (gstat, zpool) run **sequentially**; with
  default `SAMPLE_SECONDS=10` the script must stay well under the
  task INTERVAL. Cap `SAMPLE_SECONDS` at 60.

## Thresholds

- Parse `threshold <pattern> <metric> <warn> <crit>` lines from the
  cfg with the same technique as `smart.cfg`'s `attrmap` (the cfg is
  `.`-sourced sh; `threshold` is a shell function that appends to a
  list variable — no arrays, use a newline-separated string).
- Pattern matches the *instance* name (`case "$instance" in $pattern)`).
- `-` disables a level. Worst color wins. Violations go to the top of
  the status text with measured vs. threshold values.

## Testing (mirror `tests/smart/`)

- `tests/diskio/data/` fixtures:
  - `diskstats-t0.txt` / `diskstats-t1.txt` — two Linux snapshots
    (incl. sd*, nvme, md, dm with matching fake `/sys` tree metadata),
    plus wrap/reboot variants.
  - `gstat-batch.txt` — canned FreeBSD gstat batch output.
  - `zpool-iostat.txt` — two-block `zpool iostat -Hpl` output.
- `fakegstat`, `fakezpool` — PATH-prepended fakes (like
  `fakesmartctl`).
- For `/proc/diskstats` and `/sys`, the script reads paths from
  internal variables `DISKIO_PROC`/`DISKIO_SYS` (default `/proc`,
  `/sys`) overridable via environment — test hook, documented only in
  the test README.
- Unit tests (`tests/run.sh`) assert the exact `NAME : VALUE` output
  for the fixture deltas with anchored patterns, including the edge
  cases above (first run, counter reset, div-by-zero latency,
  partition/exclude filtering).
- `shellcheck --shell=sh` zero warnings; `make test` green before
  every commit.

## Out of scope for v1 (documented, deliberate)

- **btrfs aggregate instance** — no kernel aggregate counters; member
  disks are covered. Revisit if `/sys/fs/btrfs` ever grows I/O stats.
- **Per-partition or per-filesystem stats** — whole devices only.
- **Linux cumulative ZFS counters** — OpenZFS 2.x removed the
  per-pool `/proc/spl/kstat/zfs/<pool>/io` file; sampling via
  `zpool iostat` is the portable path.
- **NFS / network filesystems** — different subsystem entirely.
- **Histogram latencies** (`zpool iostat -w`, blk-mq stats) — RRD
  wants scalars.

## Resolved design questions

1. **dm targets that are neither LVM nor crypt** (multipath, …) get
   the generic `dm_` layer prefix and are reported; the layer can be
   dropped via `LAYERS`.
2. **`tasks.d` INTERVAL is 5m**, matching the default RRD step so
   every slot gets a fresh interval average.
3. **No `MAXDEVICES` safety valve.** Hosts with very many devices
   trim the instance list with `EXCLUDE`/`INCLUDE`/`LAYERS` instead —
   an implicit cut-off that silently drops devices would be worse
   than many RRD files.
