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
GRAPHS+=",tempext"
GRAPHS_temp="tempext"
```

Note the leading comma — `+=` concatenates verbatim. If your stock
`TEST2RRD` already contains a `temp` entry (some setups map it to the
`temperature` module), replace that entry instead of appending.

Then add a graph definition to `graphs.cfg` (the name `tempext`
avoids colliding with the stock `[temperature]` graph):

```
[tempext]
    FNPATTERN temp,(.+).rrd
    TITLE Temperature sensors
    YAXIS Celsius
    DEF:t@RRDIDX@=@RRDFN@:lambda:AVERAGE
    LINE2:t@RRDIDX@#@COLOR@:@RRDPARAM@
    GPRINT:t@RRDIDX@:LAST: %5.1lf (cur)
    GPRINT:t@RRDIDX@:MAX: %5.1lf (max)
    GPRINT:t@RRDIDX@:MIN: %5.1lf (min)\n
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
