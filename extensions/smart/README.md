# smart — S.M.A.R.T. disk health monitoring

Xymon client extension that reads SMART data from all local disks with
`smartctl` (smartmontools), normalizes the vendor-specific attributes to
a small set of canonical metrics, alerts on thresholds and feeds RRD
graphs on the Xymon server.

- **Column:** `smart`
- **Platforms:** Ubuntu, Rocky Linux/EL, FreeBSD
- **Disk types:** SATA/ATA (HDD & SSD), NVMe, SAS/SCSI (temperature and
  grown defects only)
- **Requires:** smartmontools (≥ 7.0 recommended for NVMe), root or a
  sudo rule (see below)

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

Additionally, the SMART overall health verdict (`PASSED`/`FAILED`) turns
the column **red** on failure, and NVMe *Critical Warning* flags turn it
yellow — independent of the metric thresholds.

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
3. **Per-model overrides** in `smart.cfg` handle the remaining oddballs:

   ```sh
   # this model reports garbage in attribute 194, use 190 instead:
   attrmap "WDC WD40EFRX*" 194 none
   # this SSD keeps "percent life left" in the VALUE column of 233:
   attrmap "SuperSSD 2000*" 233 wear invnorm
   ```

NVMe needs none of this: the NVMe health log is standardized and is
mapped directly.

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
- NVMe `Temperature` is the composite value; individual sensors are not
  reported separately.
