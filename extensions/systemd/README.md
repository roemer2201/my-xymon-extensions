# systemd — systemd service manager health

Xymon client extension that reports the health of a host's **systemd**
service manager in one status column, with a `data` message for RRD
graphing: the overall system state, every failed unit, units that must
be running, and services that systemd had to restart by itself.

- **Column:** `systemd` (override with `SYSD_COLUMN`).
- **Platforms:** every Linux host booted with systemd — Ubuntu and
  Rocky Linux are the targets. Hosts with another init system
  (FreeBSD, OpenWrt/TurrisOS with procd, containers without systemd as
  PID 1) report `clear`.
- **Default:** the task ships **enabled** in all client packages. It
  needs no configuration and no root rights: every query is a
  read-only D-Bus call that systemd allows for any user.
- **Colors:** `red` for a failed unit, a required unit that is down and
  rescue/emergency mode; `yellow` for an automatic service restart (held
  for 30 minutes), a booting or shutting-down system and errors talking
  to systemd; `clear` when switched off or not applicable. All of them
  are configurable, see below.

## What is checked

| Check | Source | Color |
|---|---|---|
| System state | `systemctl is-system-running` | `running` green; `initializing`/`starting`/`stopping` `SYSD_TRANSITION_COLOR` (yellow); `maintenance` red; `unknown` yellow; `offline` clear; `degraded` is decided by the failed units |
| Failed units | `systemctl list-units --all` (ACTIVE = `failed`) | `SYSD_FAILED_COLOR` (red), `SYSD_WARN` matches yellow, `SYSD_IGNORE` matches not counted |
| Required units | `systemctl show` per unit in `SYSD_REQUIRED` | `SYSD_DOWN_COLOR` (red) unless `active`; a unit that does not exist counts as down |
| Automatic restarts | `NRestarts` of every loaded service | `SYSD_RESTART_COLOR` (yellow) for `SYSD_RESTART_HOLD` seconds (1800) after the last restart |

The failed units are evaluated by the extension itself rather than
taken from the `degraded` state: a single unit you have decided to
ignore (say, a `*-wait-online.service` on a host without that network
setup) keeps systemd in `degraded` for good, and the column would never
turn green again.

Failed units of **every** unit type count — a failed mount (`/scratch`
not mounted on a compute node) or a failed timer is as relevant as a
failed service.

### Automatic restarts

A service with `Restart=always` or `Restart=on-failure` that keeps
crashing is `active` almost all of the time, and without a start limit
it never becomes `failed`. Neither the system state nor the failed
units show it. What does show it is the per-service counter
`NRestarts`, which systemd increases on every automatic restart. The
extension reads it for every loaded service in one `systemctl show`
call and compares it with the value of the previous poll (state file
`$XYMONTMP/systemd.<host>.state`):

- A higher counter: the difference is the number of restarts since the
  previous poll. The column takes `SYSD_RESTART_COLOR` and keeps it
  for `SYSD_RESTART_HOLD` seconds after the **last** restart seen, so a
  single crash is still visible half an hour later; more restarts
  within that window add up.
- A lower counter: systemd resets `NRestarts` on every start that is
  not an automatic restart (`systemctl start/restart`, also `systemctl
  reset-failed` and a reboot — `src/core/service.c`: *"This is not an
  automatic restart? Flush the restart counter then."*). Everything the
  counter shows now therefore happened after that reset, i.e. since the
  previous poll, and is counted.
- A service loaded since the previous poll: all its restarts are new.
- An unloaded service: an already detected restart stays visible until
  the hold expires. Its old counter is discarded, so a newly loaded
  instance is treated as new without losing the earlier warning.
- A failed counter query: at least yellow, no metrics for that poll;
  the last successful snapshot and unexpired restart warnings remain.
- The first poll after installation only records the counters.

`NRestarts` exists since systemd 235 (Rocky 8 ships 239, Ubuntu 20.04
ships 245). On older versions the restart check — and the graph — is
skipped with a note; everything else works.

## Configuration

`$XYMONHOME/etc/my-xymon-extensions/systemd.cfg`
(Debian/Ubuntu: `/etc/xymon/my-xymon-extensions/systemd.cfg`). Every
setting can also come from the environment; the config file wins.

The variables start with `SYSD_` and not `SYSTEMD_` on purpose: systemd
itself reads a long list of `SYSTEMD_*` environment variables
(`docs/ENVIRONMENT.md` in the systemd sources, e.g.
`SYSTEMD_BUS_TIMEOUT`), and a setting of this extension that ends up
exported must never change what `systemctl` does.

| Variable | Default | Meaning |
|---|---|---|
| `SYSD_ENABLE` | `yes` | `no` switches the test off: the column reports `clear` ("disabled") |
| `SYSD_COLUMN` | `systemd` | Xymon column name |
| `SYSD_FAILED_COLOR` | `red` | color of a failed unit (`red`/`yellow`) |
| `SYSD_IGNORE` | — | glob patterns: failed units listed but not counted (not graphed either) |
| `SYSD_WARN` | — | glob patterns: failed units that only turn the column yellow |
| `SYSD_REQUIRED` | — | unit names that must be active; no suffix means `.service` |
| `SYSD_DOWN_COLOR` | `red` | color of a required unit that is not active (`red`/`yellow`) |
| `SYSD_RESTART_HOLD` | `1800` | seconds the restart color is kept after the last restart; `0` = only the poll that saw it |
| `SYSD_RESTART_COLOR` | `yellow` | color of a restarted service (`yellow`/`red`/`green`; `green` only lists and graphs) |
| `SYSD_RESTART_IGNORE` | — | glob patterns: services whose restarts are listed but ignored |
| `SYSD_TRANSITION_COLOR` | `yellow` | color while booting or shutting down (`yellow`/`red`/`green`) |
| `SYSD_SYSTEMCTL` | `command -v systemctl` | path of systemctl |
| `SYSD_RUNDIR` | `/run/systemd/system` | marker directory of a systemd boot (`sd_booted(3)`) |

Example for a Slurm compute node:

```sh
SYSD_REQUIRED="sshd chronyd munge slurmd"
SYSD_IGNORE="NetworkManager-wait-online.service"
SYSD_WARN="dnf-makecache.service"
```

`SYSD_REQUIRED` takes plain unit names, no globs. systemd resolves
aliases itself: Debian/Ubuntu's `ssh.service` declares
`Alias=sshd.service`, so `sshd` works there as well as on Rocky; the
status then shows `sshd.service (= ssh.service)`. A required service
that waits for its next automatic restart (`activating (auto-restart)`)
counts as down; one that is starting up normally (`activating
(start)`) is yellow.

To switch the column off on a host, either set `SYSD_ENABLE="no"`
(the column stays, `clear`) or comment out the task in
`clientlaunch.d/systemd.cfg` and restart the client. In the second case
the column goes purple once its last status has expired; remove it on
the Xymon server with `xymon 127.0.0.1 "drop <host> systemd"`.

## Status message

```
&red System state: degraded

Failed units:
&red scratch.mount  failed  /scratch
&clear NetworkManager-wait-online.service  failed - ignored (SYSD_IGNORE)  Network Manager Wait Online

Required units (SYSD_REQUIRED):
&green sshd.service  active (running)  OpenSSH server daemon
&red nfs-server.service  inactive (dead)  NFS server and services

Automatic restarts (Restart=), last 30 min:
&yellow slurmd.service  3 restart(s), the last one 4 min ago (NRestarts=5)
```

The whole status text is wrapped in `<!-- ncv_skipstart -->` /
`<!-- ncv_skipend -->`, because the server's NCV parser also reads the
status message of an NCV column and would turn lines such as
`NRestarts=5` into RRD files.

## Metrics (NCV names)

From the second poll on, a separate `data` message carries:

| Name | Meaning |
|---|---|
| `failed` | failed units right now (`SYSD_IGNORE` matches excluded) |
| `restarts` | automatic service restarts since the previous poll (`SYSD_RESTART_IGNORE` matches excluded) |

Both values are always sent together or not at all: plain NCV creates
the RRD file with the datasets of the first message it receives
(`xymond/rrd/do_ncv.c`), so a first message without `restarts` would
leave the file without that dataset for good.

Server-side setup (TEST2RRD, NCV definition, graph and MAX archives):
see [server/README.md](server/README.md).

## Manual test

```sh
sh /usr/lib/xymon/client/ext/systemd.sh     # Debian/Ubuntu
```

Without the Xymon environment the messages are printed to stdout
instead of being sent. A manual run updates the restart state file
like a regular poll would.
