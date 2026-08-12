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

### Implausible readings (stuck or invalid sensors)

Some sensors report a bogus value instead of a real temperature —
observed on the **mt7915/mt76 wifi radio hwmon** on some
OpenWrt/TurrisOS devices (e.g. Zyxel NWA50AX Pro), which can get stuck
at a fixed, obviously-wrong reading such as several hundred degrees.
Unlike a real (even miscalibrated) ADC, repeated samples show zero
jitter, and no thermal-throttling kernel messages appear
(`logread | grep -i therm`) — both point to the firmware/MCU not
returning a real measurement at all, rather than a wrong scale or
offset applied to a real one. This can appear right after boot or
persist indefinitely; there is no known fix as of this writing (see
[openwrt/mt76#729](https://github.com/openwrt/mt76/issues/729) for
background on unreliable mt7915 thermal sensors).

`temp.sh` guards against this with a plausibility range
(`TEMP_PLAUSIBLE_MIN`/`TEMP_PLAUSIBLE_MAX`, default `-40`..`150` °C):
readings outside it are reported with color `clear` and an "ignored"
note instead of being scored, and are left out of the NCV data so they
cannot spike the RRD graph.

```
&clear mt7915_wifi0_temp1 = 491.0 C (ignored: outside plausible range -40..150 C, sensor reading invalid or stuck)
```

Note that this display line quotes the bogus value only for the human
reader — it never reaches the RRD, because the whole human-readable
part of the status message is fenced off from the NCV parser (see
[Graphing](#graphing-xymon-server-setup) below).

If a sensor stays outside the plausible range permanently, that
particular sensor simply never contributes to the column color or the
graph — nothing else to do on the monitoring side, since there is no
reliable real value to recover from a stuck reading.

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

Only these lines are meant for the RRD. Since `xymond_rrd`'s NCV
parser treats `=` exactly like `:`, the human-readable part above them
(`&green armada_thermal_temp1 = 62.3 C` …) would otherwise be turned
into datasets of its own — including the ignored, implausible
readings. It is therefore wrapped in the parser's skip markers:

```
<!-- ncv_skipstart -->
&green armada_thermal_temp1 = 62.3 C
&clear mt7915_wifi0_temp1 = 491.0 C (ignored: ...)
Checked 2 sensor(s). Thresholds per sensor: yellow >= 80 C, red >= 90 C
<!-- ncv_skipend -->
```

Both markers are HTML comments and stay invisible on the web page.
If you upgraded from an earlier version of this extension, the server
may already have collected junk RRD files from those display lines
(names like `temp,_green_armada_thermal_temp1.rrd`); they stop being
updated after the upgrade and can simply be deleted from
`$XYMONVAR/rrd/<host>/`.

Because the number of sensors varies per host, the server side uses
**split-NCV** (one RRD file per sensor). The needed configuration is
shipped as ready-made drop-in files in
[`server/`](server/) — copy `server/xymonserver.d/my-xymon-extensions-temp.cfg` into the
server's `xymonserver.d/` and `server/graphs.d/my-xymon-extensions-temp.cfg` into its
`graphs.d/`, then restart Xymon. See
[server/README.md](server/README.md) for the details (and the caveat
about a stock `TEST2RRD` that already maps `temp`).

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
