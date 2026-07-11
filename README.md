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
├── standalone/          # Run extensions WITHOUT a Xymon client
│   ├── xymon-run.sh     # xymonlaunch replacement (env + scheduler glue)
│   └── xymon-send.sh    # xymon(1) replacement (protocol sender)
├── packaging/
│   ├── common/          # Shared staging logic + tasks.d snippets
│   ├── deb/             # Debian/Ubuntu packaging
│   ├── rpm/             # RPM spec for Rocky/EL
│   ├── freebsd/         # FreeBSD pkg manifest + plist
│   └── opkg/            # OpenWrt/TurrisOS .ipk (standalone runner)
├── tests/               # Unit tests (canned command output)
└── Makefile             # Entry point: build, test, package
```

## Available extensions

| Name | Column | Description |
|------|--------|-------------|
| [smart](extensions/smart/) | `smart` | SMART disk health for SATA/ATA, NVMe and (basic) SAS disks plus eMMC wear/pre-EOL health (Linux, via mmc-utils): vendor-normalized metrics, thresholds/alerts and per-disk RRD graphs |
| [temp](extensions/temp/) | `temp` | All hardware temperature sensors from the Linux hwmon sysfs (fallback: thermal zones) — e.g. CPU/SoC and switch sensors on a Turris Omnia — with per-sensor thresholds and RRD graphs |
| [la](extensions/la/) | `la` | Load average (1/5/15 min) with thresholds per CPU core; for clientless hosts — the task ships disabled where a full Xymon client runs |
| [memory](extensions/memory/) | `memory` | Memory utilization in percent from /proc/meminfo; for clientless hosts — the task ships disabled where a full Xymon client runs |
| [fritzdsl](extensions/fritzdsl/) | `fritzdsl` | AVM FRITZ!Box DSL line monitoring via TR-064 (curl): line state, sync rate, noise margin, attenuation, error counters — thresholds/alerts and RRD graphs; polls the box from the Xymon server, no software on the box |
| [fritzwan](extensions/fritzwan/) | `fritzwan` | AVM FRITZ!Box WAN throughput monitoring (curl): physical link state, average throughput, link capacity and utilization from the box's 64-bit UPnP counters (TR-064 fallback) — optional utilization thresholds and RRD graphs |

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

## Hosts without a Xymon client (OpenWrt / TurrisOS)

No Xymon client exists for OpenWrt/TurrisOS — the extensions run there
anyway: [`standalone/`](standalone/) contains a minimal replacement for
the client's environment (`xymon-run.sh`) and for the `xymon` sender
binary (`xymon-send.sh`, plain TCP via BusyBox `nc`/`ncat`/`socat`).
Extensions run unmodified on top of it, scheduled by cron, and the
same mechanism works for every future extension in this repository.
`make opkg` builds an installable `.ipk` package. See
[standalone/README.md](standalone/README.md).

## Building packages

Package builds are driven by the top-level `Makefile`:

```sh
make deb        # Build .deb (on Debian/Ubuntu, requires dpkg-deb)
make rpm        # Build .rpm (on Rocky/EL, requires rpm-build)
make freebsd    # Build FreeBSD .pkg (on FreeBSD, requires pkg(8))
make opkg       # Build OpenWrt/TurrisOS .ipk (builds on any platform)
make test       # Run shellcheck + unit tests
```

Each package installs the extension scripts into the platform's Xymon
client `ext/` directory and drops a matching `tasks.d` snippet, so an
extension is active after installation without manual editing.

## Testing

- `shellcheck` (with `--shell=sh`) must pass for all scripts.
- Linux targets are tested in Ubuntu and Rocky Linux containers.
- FreeBSD is tested in CI using a FreeBSD VM (`vmactions/freebsd-vm`
  on GitHub Actions).
- OpenWrt/TurrisOS compatibility is enforced by running the test suite
  under BusyBox `sh` with BusyBox userland in CI.

## Contributing

See [CLAUDE.md](CLAUDE.md) for the coding and portability rules that all
contributions — human or AI-assisted — must follow.

## License

TBD.
