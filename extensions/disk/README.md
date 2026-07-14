# disk — filesystem usage

Xymon client extension that reports the used capacity of all mounted
filesystems from `df -P -k` in the **standard Xymon `disk` column**,
with global and per-mount thresholds. The status ends with a df-style
table that the Xymon server's built-in disk parser understands, so the
stock per-filesystem RRD graphs work with **zero server-side setup**.

- **Column:** `disk` (override with `DISK_COLUMN`)
- **Platforms:** Linux (GNU coreutils and BusyBox df — i.e. including
  OpenWrt/TurrisOS via the standalone runner) and FreeBSD; `df -P -k`
  is POSIX and behaves identically on all of them. Reports `clear` if
  `df` is missing or produces no usable output.
- **Requires:** nothing — BusyBox userland is enough.
- **Note:** a full Xymon client builds the `disk` column from its own
  df report, and this extension writes into **exactly that column** —
  so the shipped `tasks.d` snippet is **disabled by default**. It is
  meant for clientless hosts (routers, appliances) driven by the
  standalone runner, which runs every installed extension regardless
  of `tasks.d`. Never enable both on one host without changing
  `DISK_COLUMN`.

## Filtering

Uninteresting mount points are hidden via `DISK_EXCLUDE`, a
space-separated list of shell globs matched against both the mount
point and the device column of df. The default is:

```
DISK_EXCLUDE="/dev /rom"
```

- `/dev` — the tiny devtmpfs/tmpfs, never actionable.
- `/rom` — the read-only squashfs on OpenWrt, 100% full by design.

Everything else (including tmpfs like `/tmp` and the overlay) is
reported. Example additions: `tmp*` (hides all tmpfs devices),
`/mnt/backup`, `*.example.com:*` (NFS).

## Thresholds and colors

| Setting           | Default | Meaning                                        |
|-------------------|---------|------------------------------------------------|
| `DISK_WARN`       | `90`    | yellow at/above this percent used              |
| `DISK_CRIT`       | `95`    | red at/above this percent used                 |
| `DISK_THRESHOLDS` | empty   | per-mount overrides, `PATTERN:WARN:CRIT` list  |

`DISK_THRESHOLDS` is a space-separated list of `PATTERN:WARN:CRIT`
entries; `PATTERN` is a shell glob matched against the mount point,
the first match wins:

```
DISK_THRESHOLDS="/srv:80:90 /overlay:95:98"
```

The evaluated value is df's own `Use%`/`Capacity` column. Only
`green`/`yellow`/`red` are sent (`clear` when df is unusable) — never
`blue`/`purple`, those are managed by the server.

## Configuration

Every setting is an environment variable with a built-in default and
can also be set in `$XYMONHOME/etc/disk.cfg` (sourced POSIX shell; a
value set there wins over the environment). See the shipped
[disk.cfg](disk.cfg).

## Graphing (Xymon server setup)

**None needed.** The status body ends with a `df -P -k`-style table:

```
Filesystem           1024-blocks      Used Available  Use% Mounted on
/dev/mmcblk0p1           7634936   2937768   4468216   40% /
/dev/sda               468851544 373607712  92898704   81% /srv
```

The Xymon server's built-in RRD handler for the `disk` column (part
of the default `TEST2RRD` setting, `disk=disk`) parses exactly this
format and creates one `disk,<mountpoint>.rrd` per filesystem; the
stock `[disk]` graph in `graphs.cfg` displays them. NCV is not used.

## OpenWrt / TurrisOS

Runs through the standalone runner (see
[standalone/README.md](../../standalone/README.md)), scheduled by cron:

```
*/5 * * * * /usr/lib/xymon-standalone/xymon-run.sh all
```

Dry run on the router: `/usr/lib/xymon-standalone/xymon-run.sh -n disk`
