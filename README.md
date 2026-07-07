# my-xymon-extensions

A collection of extensions (custom tests) for the [Xymon](https://xymon.sourceforge.io/)
systems and network monitor.

All extensions are written to be **portable**: they run unmodified on
**Ubuntu**, **Rocky Linux** (and other EL derivatives) and **FreeBSD**.
Native packages (`.deb`, `.rpm` and FreeBSD `.pkg`) can be built from this
repository.

## Repository layout

```
my-xymon-extensions/
├── extensions/          # One directory per extension
│   └── <name>/
│       ├── <name>.sh    # The extension script (POSIX sh)
│       ├── <name>.cfg   # Default configuration (optional)
│       └── README.md    # What it monitors, columns, thresholds
├── packaging/
│   ├── deb/             # Debian/Ubuntu packaging (debian/ tree)
│   ├── rpm/             # RPM spec file(s) for Rocky/EL
│   └── freebsd/         # FreeBSD pkg manifest / port skeleton
├── scripts/             # Shared helpers and build scripts
└── Makefile             # Entry point: build, test, package
```

## Available extensions

| Name | Column | Description |
|------|--------|-------------|
| [diskio](extensions/diskio/) | `diskio` | Disk I/O throughput, latency, IOPS, utilization and queue depth for physical disks and aggregated volumes (md-RAID, LVM, dm-crypt, ZFS, GEOM), with per-device RRD graphs and optional thresholds |
| [smart](extensions/smart/) | `smart` | SMART disk health for SATA/ATA, NVMe and (basic) SAS disks: vendor-normalized metrics, thresholds/alerts and per-disk RRD graphs |

## Design principles

- **POSIX shell only.** Every script starts with `#!/bin/sh` and must run
  under `dash` (Ubuntu), `bash` in POSIX mode (Rocky) and FreeBSD `/bin/sh`.
  No bashisms, no GNU-only utility flags.
- **No hardcoded paths.** Extensions rely on the environment provided by
  `xymonlaunch` (`$XYMON`, `$XYMSRV`, `$XYMONHOME`, `$XYMONTMP`, …) so the
  same script works regardless of where the Xymon client is installed
  (`/usr/lib/xymon/client` on Debian/Ubuntu, `/usr/local/www/xymon/client`
  on FreeBSD, etc.).
- **Graceful degradation.** If a required tool or kernel interface is not
  available on a platform, the extension reports a `clear`/informational
  status instead of failing.
- **One extension = one column.** Each extension reports exactly one status
  column and ships with its own documentation.

## Installing an extension manually

1. Copy `extensions/<name>/<name>.sh` to `$XYMONHOME/ext/` on the client.
2. Copy the configuration file (if any) to `$XYMONHOME/etc/`.
3. Add a task section to `$XYMONHOME/etc/tasks.d/<name>.cfg` (or
   `tasks.cfg`):

   ```
   [myextension]
       ENVFILE $XYMONHOME/etc/xymonclient.cfg
       CMD $XYMONHOME/ext/myextension.sh
       LOGFILE $XYMONHOME/logs/myextension.log
       INTERVAL 5m
   ```

4. Restart the Xymon client.

## Building packages

Package builds are driven by the top-level `Makefile`:

```sh
make deb        # Build .deb (on Debian/Ubuntu, requires dpkg-dev, debhelper)
make rpm        # Build .rpm (on Rocky/EL, requires rpm-build, rpmdevtools)
make freebsd    # Build FreeBSD .pkg (on FreeBSD, requires pkg(8))
make test       # Run shellcheck + unit tests
```

Each package installs the extension scripts into the platform's Xymon
client `ext/` directory and drops a matching `tasks.d` snippet, so an
extension is active after installation without manual editing.

## Testing

- `shellcheck` (with `--shell=sh`) must pass for all scripts.
- Linux targets are tested in Ubuntu and Rocky Linux containers.
- FreeBSD is tested in CI using a FreeBSD VM (e.g. `vmactions/freebsd-vm`
  on GitHub Actions).

## Contributing

See [CLAUDE.md](CLAUDE.md) for the coding and portability rules that all
contributions — human or AI-assisted — must follow.

## License

TBD.
