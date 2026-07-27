# temp — hardware temperature sensors

Xymon client extension that reads **every** temperature sensor the
Linux kernel exposes and reports them in one status column, with
per-sensor threshold checks and NCV lines for RRD graphing.

- **Column:** `temp` (override with `TEMP_COLUMN`)
- **Platforms:** any Linux with hwmon/thermal sysfs — Ubuntu, Rocky
  Linux/EL, OpenWrt/TurrisOS (via the standalone runner). Platforms
  without that interface (FreeBSD) report `clear`.
- **Requires:** nothing beyond the kernel's sysfs — no `lm-sensors`,
  no `jq`, no `bc`; runs fine on BusyBox.

## Data sources

1. **`/sys/class/hwmon/hwmon*/`** (preferred): per chip the `name`
   file is read, then every `temp*_input` (value in millidegrees
   Celsius, converted to °C with one decimal). If a `temp*_label`
   exists it is used for the sensor name, otherwise the file's base
   name (`temp1`, …). Older kernels that keep the files one level
   down in `device/` are handled too.
2. **`/sys/class/thermal/thermal_zone*/temp`** (fallback if no hwmon
   sensor was found), labelled with the zone's `type`.

Sensor identifiers are built as `<chip>_<label>`, lowercased and
reduced to `[a-z0-9_]`. Duplicate chips get a numeric suffix. On a
Turris Omnia this yields e.g.:

```
armada_thermal_temp1     (CPU/SoC)
mv88e6xxx_internal       (Marvell switch #1)
mv88e6xxx_internal_2     (Marvell switch #2)
```

## Thresholds and colors

| Setting     | Default | Meaning                              |
|-------------|---------|--------------------------------------|
| `TEMP_WARN` | `80`    | yellow at/above this many °C         |
| `TEMP_CRIT` | `90`    | red at/above this many °C            |

The thresholds apply **per sensor**; the column color is the worst of
all sensor colors. Only `green`/`yellow`/`red` are sent (`clear` when
no sensor exists) — never `blue`/`purple`, those are managed by the
server.

### Implausible readings (sensor warm-up glitches)

Some sensors briefly report an uncalibrated raw value instead of a
real temperature — most notably the **mt7915/mt76 wifi radio hwmon**
on OpenWrt/TurrisOS devices, which can show several hundred degrees
(or `0.0`) for a while after a reboot, until the driver's thermal
calibration completes. `temp.sh` guards against this with a
plausibility range (`TEMP_PLAUSIBLE_MIN`/`TEMP_PLAUSIBLE_MAX`, default
`-40`..`150` °C): readings outside it are reported with color `clear`
and an "ignored" note instead of being scored, and are left out of the
NCV data so they cannot spike the RRD graph. Re-run the extension a
minute or two later (or wait for the next cron run) — once the sensor
settles, it reports normally again.

```
&clear mt7915_wifi0_temp1 = 491.0 C (ignored: outside plausible range -40..150 C, sensor still initializing?)
```

## Configuration

Every setting is an environment variable with a built-in default and
can also be set in `$XYMONHOME/etc/temp.cfg` (sourced POSIX shell; a
value set there wins over the environment). See the shipped
[temp.cfg](temp.cfg).

## Graphing (Xymon server setup)

The status text contains one machine-readable line per sensor, hidden
inside an HTML comment (the NCV parser still sees it):

```
armada_thermal_temp1 : 62.3
mv88e6xxx_internal : 71.5
```

Because the number of sensors varies per host, use **split-NCV** (one
RRD file per sensor) on the server. In `xymonserver.cfg` (or a local
include) append:

```
TEST2RRD+=",temp=ncv"
SPLITNCV_temp="*:GAUGE"
GRAPHS+=",temp"
GRAPHS_temp="temp"
```

Note the leading comma — `+=` concatenates verbatim. If your stock
`TEST2RRD` already contains a `temp` entry (some setups map it to the
`temperature` module), replace that entry instead of appending. `temp`
does not collide with Xymon's own stock `[temperature]` graph (a
different name), so the plain name is fine here — no need for a
separate `tempext`/`temperature` alias.

Then add a graph definition to `graphs.cfg`. Split-NCV always stores
the value in a dataset called `lambda`, regardless of test name — if
you already have a `[temp]` section from an older/unrelated setup,
just fix its `DEF` line to read from `lambda` instead of adding a new
section:

```
[temp]
    FNPATTERN temp,(.*).rrd
    TITLE Temperature sensors
    YAXIS Celsius
    DEF:temp@RRDIDX@=@RRDFN@:lambda:AVERAGE
    LINE2:temp@RRDIDX@#@COLOR@:@RRDPARAM@
    GPRINT:temp@RRDIDX@:LAST: \: %4.1lf (cur)
    GPRINT:temp@RRDIDX@:MAX: \: %4.1lf (max)
    GPRINT:temp@RRDIDX@:MIN: \: %4.1lf (min)
    GPRINT:temp@RRDIDX@:AVERAGE: \: %4.1lf (avg)\n
```

Restart the Xymon server side (`xymond_rrd`) and check that files
named `temp,<sensor>.rrd` appear under `$XYMONVAR/rrd/<host>/` after
the next report.

## OpenWrt / TurrisOS

No Xymon client exists there — run this extension through the
standalone runner (see [standalone/README.md](../../standalone/README.md)),
scheduled by cron:

```
*/5 * * * * /usr/lib/xymon-standalone/xymon-run.sh all
```

Dry run on the router: `/usr/lib/xymon-standalone/xymon-run.sh -n temp`

To debug an implausible reading, read the raw sysfs value directly and
compare it against the plausibility range, e.g.
`cat /sys/class/hwmon/hwmon*/name /sys/class/hwmon/hwmon*/temp*_input`
— a value that only settles down a minute or so after boot confirms
the sensor warm-up glitch described above rather than an extension
bug.
