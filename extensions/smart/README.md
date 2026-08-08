# smart — S.M.A.R.T. disk health monitoring

Xymon client extension that reads SMART data from all local disks with
`smartctl` (smartmontools), normalizes the vendor-specific attributes to
a small set of canonical metrics, alerts on thresholds and feeds RRD
graphs on the Xymon server.

- **Column:** `smart`
- **Platforms:** Ubuntu, Rocky Linux/EL, FreeBSD, OpenWrt/TurrisOS
  (via the standalone runner)
- **Disk types:** SATA/ATA (HDD & SSD), NVMe, SAS/SCSI (temperature and
  grown defects only), eMMC (Linux only, wear and pre-EOL health)
- **Requires:** smartmontools (≥ 7.0 recommended for NVMe), mmc-utils
  for eMMC devices, root or a sudo rule (see below)

## Canonical metrics

| Metric       | Meaning                            | ATA source (typical)                       | NVMe source                     | Default warn/crit |
|--------------|------------------------------------|--------------------------------------------|---------------------------------|-------------------|
| `temp`       | drive temperature (°C)             | 194 `Temperature_Celsius`, 190 `Airflow_…` | `Temperature`                   | 55 / 65           |
| `wear`       | percent of rated SSD life **used** | 177/231/233 (life-left style, inverted)    | `Percentage Used`               | 80 / 90           |
| `realloc`    | reallocated sectors                | 5 `Reallocated_Sector_Ct`                  | —                               | 1 / 50            |
| `pending`    | sectors pending reallocation       | 197 `Current_Pending_Sector`               | —                               | 1 / 10            |
| `uncorr`     | uncorrectable sectors              | 198 `Offline_Uncorrectable`                | —                               | 1 / 10            |
| `crc`        | interface CRC errors (cabling)     | 199 `UDMA_CRC_Error_Count`                 | —                               | 1 / 100           |
| `mediaerr`   | media/data integrity errors        | —                                          | `Media and Data Integrity Err.` | 1 / 10            |
| `spare`      | available spare (%, lower=worse)   | —                                          | `Available Spare`               | 50 / 10           |
| `hours`      | power-on hours                     | 9 `Power_On_Hours`                         | `Power On Hours`                | graph only        |
| `cycles`     | power cycles                       | 12 `Power_Cycle_Count`                     | `Power Cycles`                  | graph only        |
| `unsafeshut` | unsafe shutdowns                   | —                                          | `Unsafe Shutdowns`              | graph only        |
| `written`    | host data written (GiB)            | 241 `Total_LBAs_Written`, `Host_Writes_…`  | `Data Units Written`            | graph only        |
| `read`       | host data read (GiB)               | 242 `Total_LBAs_Read`, `Host_Reads_…`      | `Data Units Read`               | graph only        |
| `dwpd`       | lifetime avg writes per day        | computed: `written` ÷ capacity ÷ days      | computed (same)                 | graph only        |
| `dwpdrecent` | writes per day, recent window      | computed from stored samples               | computed (same)                 | graph only        |

Additionally, the SMART overall health verdict (`PASSED`/`FAILED`) turns
the column **red** on failure, and NVMe *Critical Warning* flags turn it
yellow — independent of the metric thresholds.

## eMMC devices (Linux)

eMMC (soldered flash on routers, SBCs, appliances — e.g. Turris Omnia)
is not covered by smartctl. For these devices the extension reads the
standardized JEDEC health fields from the EXT_CSD register using
`mmc extcsd read` from **mmc-utils** (OpenWrt/TurrisOS:
`opkg install mmc-utils`; Debian/Ubuntu: `apt install mmc-utils`) and
maps them into the same schema:

| EXT_CSD field                  | Mapping                                       |
|--------------------------------|-----------------------------------------------|
| `DEVICE_LIFE_TIME_EST_TYP_A/B` | `wear` — reported in 10% steps (`0x01` = 0–10% used … `0x0B` = exceeded). The worse of the two estimates wins (A and B cover different flash regions, typically SLC and MLC); the upper bound of the step is reported, so `0x01` shows as `wear=10`. Uses the normal `WEAR_WARN`/`WEAR_CRIT` thresholds. |
| `PRE_EOL_INFO`                 | health verdict, like SMART `PASSED`/`FAILED`: `0x01` Normal → green, `0x02` Warning (80% of reserved blocks consumed) → **yellow**, `0x03` Urgent (90%) → **red**. |

Notes:

- Auto-discovery checks every `/dev/mmcblkN` whose sysfs type is `MMC`.
  **SD cards** (type `SD`) have no EXT_CSD and are skipped. Override
  with `MMC_DEVICES` in `smart.cfg` (`"none"` disables the check);
  `EXCLUDE` applies here too.
- These fields exist since eMMC 5.0; older devices report
  `no usable eMMC health data` (clear).
- If an eMMC device is present but mmc-utils is not installed, the
  device is shown as `clear` with an installation hint — mirroring the
  behaviour when disks are present but smartmontools is missing.
- `mmc extcsd read` needs root; when running unprivileged add the mmc
  line from `sudoers.example`. On OpenWrt the standalone runner is
  driven by root's crontab, so no sudo setup is needed there.

## How vendor normalization works

Every disk vendor uses SMART attribute IDs slightly differently. The
extension attacks this in three layers:

1. **smartmontools' drive database** already translates raw attribute
   IDs into meaningful names (`Wear_Leveling_Count`,
   `Percent_Lifetime_Remain`, …) for thousands of drive models. Keep
   smartmontools up to date (or run `update-smart-drivedb`) and most of
   the vendor mess disappears before this extension even sees the data.
2. **The built-in map in `smart.sh`** matches those attribute *names*
   (not just IDs) and folds them into the canonical metrics above, e.g.
   `Wear_Leveling_Count`, `SSD_Life_Left`, `Media_Wearout_Indicator` and
   `Percent_Lifetime_Remain` all become `wear`, converted so that the
   value is always "percent of life used".

   For drives that are **not in smartctl's drive database** (smartctl
   prints `Device is: Not in smartctl database`, common on OpenWrt/
   TurrisOS builds without drivedb updates), the name-based matching
   cannot work: vendor attributes show up as `Unknown_Attribute`, and
   241/242 get the generic `Total_LBAs_Written`/`_Read` labels even on
   drives that count in other units. The built-in map therefore starts
   with model-specific entries matched by attribute *ID* for known
   drive families (e.g. Kingston KC600: 241/242 count 32-MiB units,
   231 is "SSD life left"). Such drives are marked
   `(not in smartctl drive database)` on the status page; if metrics
   look wrong there, update the drive database
   (`update-smart-drivedb`) or add an `attrmap` override.
3. **Per-model overrides** in `smart.cfg` handle the remaining oddballs:

   ```sh
   # this model reports garbage in attribute 194, use 190 instead:
   attrmap "WDC WD40EFRX*" 194 none
   # this SSD keeps "percent life left" in the VALUE column of 233:
   attrmap "SuperSSD 2000*" 233 wear invnorm
   ```

NVMe needs none of this: the NVMe health log is standardized and is
mapped directly.

## Disk writes per day (DWPD)

DWPD expresses write load in the unit SSD endurance is rated in: how
many times the drive's own capacity is written per day. Two variants are
reported, both **graph only** — they never colour the column, because
the acceptable DWPD depends on the drive's endurance rating (enterprise
SSDs 1–10, consumer SSDs often below 0.3), which the extension cannot
know.

**Capacity** comes from the `smartctl -i` output that is already
fetched for every device: `User Capacity:` (ATA) or
`Namespace 1 Size/Capacity:` (NVMe, falling back to
`Total NVM Capacity:`). No extra command, no extra privileges. Devices
without a usable capacity or host-writes counter — SAS/SCSI, plain
HDDs, eMMC — simply do not get these metrics.

### `dwpd` — lifetime average, immune to reboots

```
dwpd = written / capacity / (power-on hours / 24)
```

Both inputs are counters kept by the **drive's firmware**, not by this
extension, so nothing about it depends on the host: a reboot, a wiped
`$XYMONTMP`, a reinstalled package or a moved disk all leave it intact,
and the next run recomputes exactly the same value. This is why the
metric needs no state file at all.

Below `DWPD_MIN_HOURS` (default 24) it is withheld — right after a disk
is installed, dividing by a few hours produces a meaningless number.

### `dwpdrecent` — rolling window

The lifetime average is by definition slow: on a disk that has been
running for years, a workload change barely moves it. `dwpdrecent`
therefore averages over a sliding window (`DWPD_WINDOW_HOURS`, default
24). One sample per device — timestamp, writes and serial number — is
kept in `$XYMONTMP/smart.<host>.state`, at most one every
`DWPD_SAMPLE_HOURS`; samples older than two windows are dropped.

A value is emitted on **every** run (not once per window), computed
against the most recent sample that is at least one window old. That
matters for graphing: Xymon's RRD files use a 300-second step with a
600-second heartbeat, so a metric that only appears once a day would
leave the RRD almost entirely undefined and the graph empty. Emitting
every run keeps the line continuous while the *measurement* still spans
the full window.

**The poll interval does not affect the values.** Neither metric assumes
a fixed schedule: `dwpd` uses only firmware counters, and `dwpdrecent`
divides by the *measured* time between two samples, not by an assumed
one. Running every 5 minutes on one host and every 10 on another (or
switching between them) yields the same number for the same workload —
only how densely the graph is populated differs. The one thing worth
knowing is that Xymon's RRDs use a 600-second heartbeat, so a 10-minute
schedule sits right at that limit: a late run can leave a gap in the
graph. That applies to every metric this extension sends, not just
DWPD; a 5-minute schedule has margin, a 10-minute one does not.

The state file is expendable by design. If it is missing, unreadable,
truncated, holds a different serial number (disk replaced), or the
writes counter went backwards, the extension silently starts a fresh
sample and reports nothing this round — indistinguishable from a fresh
install, and never a false spike. A read-only `$XYMONTMP` only disables
this one metric; the rest of the report is unaffected.

### Choosing the window

The window controls two things that pull in opposite directions.

**Responsiveness.** "Per day" is a *unit*, not an averaging period —
like km/h does not require driving for an hour. A sliding window of
length *W* turns a step change in write rate into a linear ramp exactly
*W* long. If the write rate doubles, the graph reaches the new value
after 1 h with `DWPD_WINDOW_HOURS=1`, and after 24 h with the default.
Neither is more "correct"; a short window shows *when* something
changed, a long one shows the trend.

**Counter quantization.** Drives report writes in coarse units, and
that — not the averaging — is usually the limiting factor:

| Attribute source | Resolution | At 0.8 GiB/day, one step takes |
|------------------|-----------|--------------------------------|
| `Total_LBAs_Written` (512-byte LBAs) | 0.5 KiB | under a second |
| NVMe `Data Units Written` (512000 B) | 500 kB   | ~50 seconds |
| `Host_Writes_32MiB` / 32-MiB units   | 32 MiB   | ~55 minutes |
| `Host_Writes_GiB` (whole GiB)        | 1 GiB    | ~30 hours |

The extension stores the **unrounded** counter in its state file, so
drives in the first three rows are limited only by their own hardware.
The `written` metric shown on the status page and in its own graph
stays whole GiB — only DWPD uses the finer value.

A drive that counts in whole GiB cannot do better than 1 GiB per
sample, though. On a lightly loaded system (say a constant 10 kB/s ≈
0.8 GiB/day on a 480 GB SSD, a true DWPD of 0.0018) a 24-hour window
sees either zero or one GiB and the graph alternates between `0` and
`0.00224` instead of showing a flat line. Raising
`DWPD_WINDOW_HOURS` to several days fixes that; the guide is that the
window should be long enough to accumulate a good handful of counter
steps. Drives counting in LBAs or NVMe data units produce a flat,
accurate line even at a one-hour window.

Because RRD consolidates to averages for the weekly and monthly graphs
anyway, it is generally better to collect with a window just long
enough to beat the quantization and let RRD do the rest of the
smoothing — smoothing applied at collection time cannot be undone.

## Client installation

1. Copy `smart.sh` to `$XYMONHOME/ext/smart.sh` (executable).
2. Optional: copy `smart.cfg` to `$XYMONHOME/etc/smart.cfg` and adjust.
3. Install the task snippet (see `packaging/common/tasks.d/smart.cfg`)
   into the client's `tasks.d`/`clientlaunch.cfg`.
4. Grant privileges (below), then restart the Xymon client.

The packages built from this repository do steps 1–3 automatically.

### Privileges (sudo)

`smartctl` needs raw device access, but the Xymon client runs as user
`xymon`. Install the rule from `sudoers.example` (as
`/etc/sudoers.d/xymon-smart` on Linux, `/usr/local/etc/sudoers.d/` on
FreeBSD). Without root/sudo the column reports `clear` with a hint —
never wrong data.

### Manual test run

```sh
sudo sh extensions/smart/smart.sh
```

Without the Xymon environment variables the script prints the status
and data messages to stdout instead of sending them.

## Server-side setup (graphs)

The client sends one `data` message per run containing lines like
`sda_temp : 38`, `nvme0_wear : 3`. Turning these into per-disk RRDs and
graphs requires a one-time configuration on the **Xymon server** —
see [`server/README.md`](server/README.md).

## Platform notes

- **Device discovery** uses `smartctl --scan`; it finds `/dev/sd*` and
  `/dev/nvme*` on Linux, `/dev/ada*`, `/dev/da*` and `/dev/nvme*` on
  FreeBSD. Only the device path is used; the type is autodetected.
- **USB bridges** often need `-d sat`; **RAID controllers** need e.g.
  `-d megaraid,N` / `-d 3ware,N` — declare those with `device` lines
  (auto-discovery is disabled as soon as one `device` line exists).
- **Disks in standby** are not woken up (`NOSPINUP=yes`, uses
  `smartctl -n standby`); they are skipped for that run.
- **SAS/SCSI disks** report no ATA attribute table; only temperature and
  grown-defect count are collected (mapped to `temp`/`realloc`).

## Caveats worth knowing

- `crc` errors count *lifetime* events and never reset. After fixing a
  bad cable the column stays yellow; raise `CRC_WARN` above the current
  count (or set `0`) to re-arm it.
- Some Seagate attributes (1 `Raw_Read_Error_Rate`, 7 `Seek_Error_Rate`)
  hold huge packed raw values that look alarming but are normal — they
  are deliberately **not** mapped by default.
- A few drives report attribute 9 in minutes or other units; override
  with `attrmap` if the `hours` graph looks off by a constant factor.
- `written`/`read` are normalized to **GiB** from whatever unit the
  drive uses (`…_GiB` attributes, 512-byte LBAs, 32-MiB units, NVMe
  data units). Some drives lie about the unit of `Total_LBAs_Written`;
  if the value is off by a constant factor, override the source, e.g.
  `attrmap "Intel SSD*" 241 written mib32`.
- NVMe `Temperature` is the composite value; individual sensors are not
  reported separately.
- `dwpdrecent` restarts its window whenever the sample file is lost, so
  after a reboot with a tmpfs `$XYMONTMP` it stays absent for one
  window. `dwpd` is unaffected — see the DWPD section above.
- If a device fails to report for a single run (standby, a transient
  `smartctl` error), its samples are carried over so the window is not
  reset; only devices absent for more than two windows are forgotten.
