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

The package installs to `/usr/lib/xymon-standalone/` and puts the
config at `/etc/xymon-standalone.cfg` (preserved on sysupgrade).

### Manual (three files + extension)

```sh
DEST=/usr/lib/xymon-standalone
mkdir -p $DEST/ext $DEST/etc
scp standalone/xymon-run.sh standalone/xymon-send.sh root@router:$DEST/
scp extensions/smart/smart.sh root@router:$DEST/ext/
scp extensions/smart/smart.cfg root@router:$DEST/etc/       # optional
scp standalone/standalone.cfg root@router:/etc/xymon-standalone.cfg
```

## Setup

1. Edit `/etc/xymon-standalone.cfg` — at minimum set `XYMSRV` (the
   Xymon server) and check `MACHINEDOTS` (must match the host's entry
   in the server's `hosts.cfg`).
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
  `/usr/lib/xymon-standalone/etc/smart.cfg` as usual.
- BusyBox `nc` is part of the default OpenWrt/TurrisOS busybox build;
  if yours lacks it, install `netcat` or `socat`.
- Only the extension columns are reported — this runner does not
  replace a full Xymon client. The `temp`, `la` and `memory`
  extensions in this repository cover the most important local health
  metrics for such hosts (temperatures, load average, memory
  utilization); disk usage, network etc. remain unreported.
- The transport is the plain Xymon protocol (unencrypted TCP :1984),
  exactly like a normal Xymon client — fine on a LAN/VPN, not meant to
  cross the open internet.

## Using it for future extensions

Nothing extension-specific lives in the runner. To run another
extension from this repository (or your own) on such a host:

1. Copy `extensions/<name>/<name>.sh` to
   `/usr/lib/xymon-standalone/ext/<name>.sh`.
2. Optional config to `/usr/lib/xymon-standalone/etc/<name>.cfg`.
3. It is picked up by `xymon-run.sh all` automatically (or schedule
   `xymon-run.sh <name>` separately).

The `make opkg` package already ships every extension in the repo, so
rebuilding and reinstalling the package achieves the same.
