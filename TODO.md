# TODO

Open items of the repository, collected in one place. Each entry names
the document it came from; resolved entries are removed here.

## smart: reduce the default poll interval

`packaging/common/clientlaunch.d/smart.cfg` ships `INTERVAL 10m`, which
equals the 600 s heartbeat that Xymon hardcodes for split-NCV RRDs
(`xymond/rrd/do_ncv.c`: `DS:lambda:GAUGE:600:U:U`). xymonlaunch starts a
task 0-5 s late on every cycle (5 s main loop, `laststart = now`), and
the run time of smart.sh varies, so consecutive updates arrive just
above or just below 600 s apart. Every update later than the heartbeat
turns the preceding interval UNKNOWN: the smart graphs show short
dashes with gaps on all disks at once (observed on a host with 11
disks, NVMe included, so not a standby effect).

- Lower the default to `INTERVAL 5m` (like the other graphing
  extensions) or `9m`; a local test with `9m` is pending.
- Update `extensions/smart/README.md` (section on the poll interval,
  currently "a 10-minute schedule sits right at that limit").
- The snippet is a conffile: note in the changelog that edited copies
  are not replaced on upgrade.

## License

`README.md` ("License: TBD.") and the `License:` field of the rpm spec
(`packaging/rpm/`) are still placeholders. Choosing the license is a
maintainer decision (source: CODE_REVIEW.md, "Limits and maintainer
decisions").

## CI: FreeBSD job disabled

The FreeBSD VM job in `.github/workflows/` is commented out ("Temporarily
disabled"), while `README.md` (Testing) still states that FreeBSD is
tested in CI. Either re-enable the job or adjust the README. A native
FreeBSD package build and runtime test have not been done since
(source: CODE_REVIEW.md).

## Server package only for Debian/Ubuntu

There is no rpm or FreeBSD packaging for my-xymon-extensions-server. The
tasks.d layout and the powerline helper's fixed /usr/bin tool paths would
need review first (source: PLAN1.md, "Open TODOs").

Until then, other servers are set up by hand with the recipe in
`README.md` ("Recipe: a server without the Debian package"). A
`make server-install` target was considered and not built: it would
have to answer the same questions as a package (edited files in
`my-xymon-extensions-server/` on an update, never touching a stock
config file) without a package manager's help. If non-Debian servers
become common, a server rpm is the better answer (source: installation
on a Xymon 4.3.30 source build, Rocky Linux 10.3).

## dnf: reuse the previous result while nothing changed

A dnf run costs about 8 s wall clock and 7.6 s CPU (measured with
`xymonext` on Rocky Linux 10.3, 9 enabled repositories including
EPEL), every 5 minutes - about 2.5 % of one core for a result that
changes rarely: its inputs only change when root's cache is refreshed
(`dnf makecache --timer`, effectively every 3 hours or more, see
`extensions/dnf/README.md`, "How soon a new advisory shows up") or a
package is installed or removed. A longer `INTERVAL` is no way out: the
graphs need a value at least every 600 s (plain NCV heartbeat, see the
smart entry above).

Idea: keep the last status and data message in a state file together
with a fingerprint of everything they depend on, and send them again
unchanged while the fingerprint is the same, recomputing only the
metadata age (step 4) and with it the repository lines and colors:

- mtime of every `primary.xml*` of the enabled repositories (already
  collected in step 4);
- the rpm database - `/var/lib/rpm/rpmdb.sqlite` on EL 9 and 10,
  `/var/lib/rpm/Packages` (Berkeley DB) on EL 8; verify per release,
  e.g. with `rpm -E '%_dbpath'`;
- the boot id (`/proc/sys/kernel/random/boot_id`), for the reboot hint;
- `dnf.cfg` of this extension, `/etc/dnf/dnf.conf` and
  `/etc/yum.repos.d/*.repo` (excludes, enabled repositories).

Open: a full run at least every N hours anyway, where the state file
lives (`$XYMONTMP` may be a tmpfs) and how a reused result is marked in
the status. Not implemented (source: installation on a Xymon 4.3.30
source build, Rocky Linux 10.3).

## Unverified without hardware

- powerline: a plcrate response whose MAC differs from the queried
  adapter is treated as a hard error for that adapter; not verifiable
  without matching hardware (source: PLAN1.md).
- fritz-wifi: the 5 GHz per-client fixture
  (GetGenericAssociatedDeviceInfo) is still synthesized; replace it with
  a masked real response when a 5 GHz client is available (source:
  PLAN2.md, "Implementation status").
