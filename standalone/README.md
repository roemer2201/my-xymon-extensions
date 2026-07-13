# standalone — running extensions without a Xymon client

Runs the extensions from this repository on hosts that have **no Xymon
client** — OpenWrt/TurrisOS routers, appliances, minimal containers.

## How it works

The extensions only talk to Xymon through a tiny contract: a handful of
environment variables plus the `$XYMON $XYMSRV "status ..."` call.
This directory provides drop-in replacements for both halves of that
contract:

- **`xymon-send.sh`** — replaces the `xymon(1)` client binary. Speaks
  the wire protocol directly (TCP to port 1984, write message, close)
  using whatever transport the host has: BusyBox `nc`, `ncat` or
  `socat`.
- **`xymon-run.sh`** — replaces `xymonlaunch`. Reads a small config
  file, exports the full Xymon environment (`$XYMON` → `xymon-send.sh`,
  `$XYMSRV`, `$MACHINE`, `$XYMONHOME`, `$XYMONTMP`, …) and runs the
  requested extension(s) from `$XYMONHOME/ext/`.

Extensions run **unmodified** — they cannot tell the difference from a
full client. Any future extension in this repo works the same way:
drop its script into `ext/`, done.

Scheduling is plain cron (`crontab.example`); no daemon needed.

## Installation on OpenWrt / TurrisOS

### Via package (recommended)

```sh
opkg install smartmontools
opkg install my-xymon-extensions_<version>_all.ipk   # built with "make opkg"
```

The package installs the scripts to `/usr/lib/xymon-standalone/` and
all configuration to `/etc/xymon-standalone/` (preserved on
sysupgrade): `standalone.cfg` for the runner itself plus one
`<extension>.cfg` per extension. `/usr/lib/xymon-standalone/etc` is a
symlink to `/etc/xymon-standalone`, so the extensions find their
config through `$XYMONHOME/etc/<name>.cfg` as on a full client.

### Manual (three files + extension)

```sh
DEST=/usr/lib/xymon-standalone
mkdir -p $DEST/ext
ssh root@router "ln -s /etc/xymon-standalone $DEST/etc"
scp standalone/xymon-run.sh standalone/xymon-send.sh root@router:$DEST/
scp extensions/smart/smart.sh root@router:$DEST/ext/
scp extensions/smart/smart.cfg root@router:/etc/xymon-standalone/  # optional
scp standalone/standalone.cfg root@router:/etc/xymon-standalone/
```

## Setup

1. Edit `/etc/xymon-standalone/standalone.cfg` — at minimum set
   `XYMSRV` (the Xymon server) and check `MACHINEDOTS` (must match the
   host's entry in the server's `hosts.cfg`). The `TESTS` line selects
   which extensions `xymon-run.sh all` runs; it defaults to the local
   health tests (`la memory smart temp`). Commented out or empty, all
   installed extensions run. The `memory` extension reports under the
   column name `mem` by default (see
   [extensions/memory/README.md](../extensions/memory/README.md)), so
   it never collides with the `memory` column a full Xymon client
   reports on the server.
2. Add the host to `hosts.cfg` on the Xymon server.
3. Test interactively on the router:

   ```sh
   /usr/lib/xymon-standalone/xymon-run.sh -n smart   # dry run, prints report
   /usr/lib/xymon-standalone/xymon-run.sh smart      # sends for real
   ```

4. Schedule it — append to `/etc/crontabs/root` (see
   `crontab.example`):

   ```
   */10 * * * * /usr/lib/xymon-standalone/xymon-run.sh all
   ```

   then `/etc/init.d/cron restart`. Keep the interval below 30
   minutes or the column turns purple (stale).

Run logs go to `$XYMONTMP` (default `/tmp`, a RAM disk on OpenWrt) as
`<extension>.log`.

## TurrisOS / OpenWrt notes

- Everything runs as **root** on the router, so the sudo setup from
  the smart extension docs does not apply (`USE_SUDO=auto` simply
  never engages).
- `smartctl` comes from the `smartmontools` package
  (`opkg install smartmontools`).
- USB disks may need `-d sat` — use a `device` line in
  `/etc/xymon-standalone/smart.cfg` as usual.
- BusyBox `nc` is part of the default OpenWrt/TurrisOS busybox build;
  if yours lacks it, install `netcat` or `socat`.
- Only the extension columns are reported — this runner does not
  replace a full Xymon client. The `temp`, `la` and `memory`
  extensions in this repository cover the most important local health
  metrics for such hosts (temperatures, load average, memory
  utilization); disk usage, network etc. remain unreported.
- The `wifi` extension is in the default `TESTS` list: on access
  points it reports client counts, channel utilization, airtime and
  more (see `extensions/wifi/README.md`). On routers without AP
  radios it reports a `clear` column — remove it from `TESTS` there
  if you don't want that.
- The FRITZ!Box pollers `fritzdsl`/`fritzwan` are installed but not in
  the default `TESTS` list: they are remote pollers that query a
  FRITZ!Box over the network, a job that normally belongs on the
  Xymon server (via the deb/rpm package and its tasks.d snippets).
  Run them from the router only when the server cannot reach the box
  itself — configure `/etc/xymon-standalone/fritzdsl.cfg` (resp.
  `fritzwan.cfg`) and add them to `TESTS`.
- The transport is the plain Xymon protocol (unencrypted TCP :1984),
  exactly like a normal Xymon client — fine on a LAN/VPN, not meant to
  cross the open internet.

## Using it for future extensions

Nothing extension-specific lives in the runner. To run another
extension from this repository (or your own) on such a host:

1. Copy `extensions/<name>/<name>.sh` to
   `/usr/lib/xymon-standalone/ext/<name>.sh`.
2. Optional config to `/etc/xymon-standalone/<name>.cfg`.
3. Add it to `TESTS` in `/etc/xymon-standalone/standalone.cfg` so
   `xymon-run.sh all` picks it up (or schedule `xymon-run.sh <name>`
   separately).

The `make opkg` package already ships every extension in the repo, so
rebuilding and reinstalling the package achieves the same.
