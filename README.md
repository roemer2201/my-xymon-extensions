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
│       ├── README.md    # What it monitors, columns, thresholds
│       └── server/      # Xymon SERVER side (only where RRD graphs exist)
│           ├── README.md
│           ├── xymonserver.d/my-xymon-extensions-<name>.cfg
│           ├── graphs.d/my-xymon-extensions-<name>.cfg
│           └── rrddefinitions.d/my-xymon-extensions-<name>.cfg
├── standalone/          # Run extensions WITHOUT a Xymon client
│   ├── xymon-run.sh     # xymonlaunch replacement (env + scheduler glue)
│   └── xymon-send.sh    # xymon(1) replacement (protocol sender)
├── packaging/
│   ├── common/          # Shared staging logic + clientlaunch.d snippets
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
| [memory](extensions/memory/) | `mem` | Memory utilization in percent from /proc/meminfo; for clientless hosts — the task ships disabled where a full Xymon client runs |
| [disk](extensions/disk/) | `disk` | Filesystem usage from `df -P -k` in the standard `disk` column with global and per-mount thresholds; `/dev` and `/rom` hidden by default, stock server-side graphs work as-is; for clientless hosts — the task ships disabled where a full Xymon client runs |
| [fritzdsl](extensions/fritzdsl/) | `fritzdsl` | AVM FRITZ!Box DSL line monitoring via TR-064 (curl): line state, sync rate, noise margin, attenuation, error counters — thresholds/alerts and RRD graphs; polls the box from the Xymon server, no software on the box |
| [fritzwan](extensions/fritzwan/) | `fritzwan` | AVM FRITZ!Box WAN throughput monitoring (curl): physical link state, average throughput, link capacity and utilization from the box's 64-bit UPnP counters (TR-064 fallback) — optional utilization thresholds and RRD graphs |
| [if_link](extensions/if_link/) | `if_link` | Link state changes per network interface, counted from the kernel's `carrier_changes` counter — so even a flap that starts and ends between two polls is seen (a short down+up is two changes); physical ports and DSA switch ports are auto-detected, thresholds are opt-in, RRD graphs per port; Linux only |
| [wifi](extensions/wifi/) | `wifi` | Wi-Fi access point metadata via iw/nl80211 plus ubus/hostapd and iwinfo on OpenWrt: client counts per SSID interface, channel utilization and noise per radio, throughput, client airtime and TX retry rates — informational only (green/clear), RRD graphs; for OpenWrt/TurrisOS APs via the standalone runner |
| [xymonext](extensions/xymonext/) | `xymonext` | What the extensions above cost this host: wall clock time, CPU time of the whole process tree and bytes sent to the server, measured on every run and graphed per test — thresholds on the runtime catch a hanging test; wraps the other extensions instead of being scheduled itself |

## Server-side setup: drop-in directories

Extensions that produce RRD graphs need a few lines of configuration on
the **Xymon server**. This repository never asks you to edit a stock
config file for that: every extension that needs server-side settings
ships them as ready-made drop-in files under
`extensions/<name>/server/`, one per Xymon config file.

| Drop-in file | goes into | contains |
|---|---|---|
| `server/xymonserver.d/my-xymon-extensions-<name>.cfg` | `xymonserver.d/` | `TEST2RRD`, `NCV_*`/`SPLITNCV_*`, `GRAPHS*` |
| `server/graphs.d/my-xymon-extensions-<name>.cfg` | `graphs.d/` | the `[graphname]` graph definitions |
| `server/rrddefinitions.d/my-xymon-extensions-<name>.cfg` | `rrddefinitions.d/` | RRA archive layout (only `if_link` so far) |

Every file name carries the package name on purpose. These directories
are shared: `hobbit-plugins`, for instance, ships a `temp.cfg` in
`graphs.d`, `xymonserver.d` **and** `clientlaunch.d`, and dpkg refuses
to install two packages that claim the same path. Keep the prefix when
you copy the files by hand — it also decides the read order, which
matters for `TEST2RRD` (see below).

### Why this works

Xymon reads **all** of its configuration files through one and the same
reader (`stackfgets()` in `lib/stackio.c`), which understands three
directives in every file it reads:

```
include /path/to/file
directory /path/to/dir        # every file in it, in alphabetical order
optional include|directory …  # no warning if it does not exist
```

The manual documents this only for `hosts.cfg` and `alerts.cfg`, but it
is a property of the reader, not of those files. Verified in the Xymon
sources for the three files used here:

| Config file | loaded by | uses the shared reader |
|---|---|---|
| `graphs.cfg` | `load_gdefs()`, `web/showgraph.c` | yes (`stackfopen`/`stackfgets`) |
| `rrddefinitions.cfg` | `load_rrddefs()`, `xymond/xymond_rrd.c` | yes |
| `xymonserver.cfg` | `loadenv()`, `lib/environ.c` | yes |

### Debian/Ubuntu: the server package

On Debian/Ubuntu there is no need to copy anything by hand —
`make deb-server` builds **`my-xymon-extensions-server`**, which
installs all drop-in files into `/etc/xymon/{xymonserver,graphs,
rrddefinitions}.d/` as conffiles:

```sh
make deb-server
sudo dpkg -i build/my-xymon-extensions-server_*.deb
sudo service xymon restart
```

It is independent of the client package: install it on the Xymon
server, the client package on the monitored hosts, both together where
the server also runs a client (which Debian does by default — `xymon`
depends on `xymon-client`). They share `/etc/xymon` but no single file:
the client owns `<name>.cfg` and its `clientlaunch.d` snippets, the
server package only writes into the three drop-in directories above,
and every file of both carries the `my-xymon-extensions-` prefix.

The package never edits `xymonserver.cfg`, `graphs.cfg` or
`rrddefinitions.cfg` — those are conffiles of the `xymon` package, and
editing another package's conffile makes dpkg prompt on its next
upgrade. Instead its post-install checks whether each drop-in directory
is actually read and prints the one line to add if not (in practice
only for `rrddefinitions.d`, which Debian does not ship). It also does
not restart Xymon by itself; a monitoring server restarts when *you*
say so.

### Wiring it up on your server

- **Debian/Ubuntu** already ship `/etc/xymon/graphs.d/` and
  `/etc/xymon/xymonserver.d/` and wire them up: the init script writes
  one `include` line per `*.cfg` file into
  `/var/run/xymon/graphs-include.cfg` resp.
  `xymonserver-include.cfg`, and the stock `graphs.cfg` and
  `xymonserver.cfg` include those at their end (Debian patch
  `12_hobbitvars.patch`, `debian/init-common.sh`). Both loops only run
  where `xymond` is installed, i.e. on a server. Drop the file in and
  **restart** Xymon — that list is regenerated at start, so a reload is
  not enough. `rrddefinitions.d/` does not exist there — create it and
  add `optional directory /etc/xymon/rrddefinitions.d` at the end of
  `rrddefinitions.cfg` once (the server package does the first half and
  tells you about the second).
- **Current upstream Xymon** ships every config file with a trailing
  `optional directory $XYMONHOME/etc/<name>.d`, so `graphs.d` and
  `rrddefinitions.d` work out of the box. Its drop-in directory for the
  server config is named `xymonserver.cfg.d`, not `xymonserver.d` —
  either put the file there or add
  `optional directory $XYMONHOME/etc/xymonserver.d` to
  `xymonserver.cfg`.
- **Anything else** (source installs, EL/FreeBSD packages): create the
  directory and add one line at the **end** of the matching config file,
  e.g. `optional directory $XYMONHOME/etc/xymonserver.d`. A single
  `include $XYMONHOME/etc/xymonserver.d/<name>.cfg` per file works too.

The **end** matters for `xymonserver.cfg`: the snippets extend the
stock settings with `NAME+="…"`, which appends verbatim (hence the
leading comma in every value) and requires the variable to be defined
already.

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

## Measuring the extensions themselves

The [`xymonext`](extensions/xymonext/) extension is a wrapper rather than a
scheduled test: the `clientlaunch.d` snippets call
`$XYMONCLIENTHOME/ext/xymonext.sh <name>` and the standalone runner does the
same, so every extension is measured while it runs — wall clock time, CPU
time of its whole process tree and the bytes it sends to the server. The
measured extension runs completely unchanged and its exit code is passed
through. Set `XYMONEXT_ENABLE="no"` in `xymonext.cfg` (or in
`standalone.cfg`) to run the extensions directly again.

## Installing an extension manually

1. Copy `extensions/<name>/<name>.sh` to `$XYMONHOME/ext/` on the client.
2. Copy the configuration file (if any) to `$XYMONHOME/etc/`.
3. Add a task section to `$XYMONHOME/etc/clientlaunch.d/<name>.cfg`
   (or directly to `clientlaunch.cfg`) — **not** to `tasks.d`, which
   is the drop-in directory of the *server's* xymonlaunch:

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
make deb        # Build client .deb (on Debian/Ubuntu, requires dpkg-deb)
make deb-server # Build server .deb (Xymon server configuration)
make rpm        # Build .rpm (on Rocky/EL, requires rpm-build)
make freebsd    # Build FreeBSD .pkg (on FreeBSD, requires pkg(8))
make opkg       # Build OpenWrt/TurrisOS .ipk (builds on any platform)
make test       # Run shellcheck + unit tests
```

Each package installs the extension scripts into the platform's Xymon
client `ext/` directory and drops a matching `clientlaunch.d` snippet, so an
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
