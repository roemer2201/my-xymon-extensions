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

## Optional `make server-install` target for non-Debian servers

The server side outside Debian/Ubuntu is installed by hand with the
recipe in `README.md` ("Recipe: a server without the Debian package"):
`stage-server.sh` into a staging directory, copy, then one
`optional directory` line per config file. A Makefile target could do
the first two steps, e.g. `make server-install SRV=/home/xymon/server
DESTDIR=...`, and print (never append) the missing lines. It must not
touch a stock config file, and it has to decide what happens to
edited files in `my-xymon-extensions-server/` on an update (skip them,
or install `.new` copies). Maintainer decision whether a target is
worth it next to the recipe (source: installation on a Xymon 4.3.30
source build, Rocky Linux 10.3).

## temp launch snippet in the rpm and FreeBSD packages

`stage.sh` leaves `clientlaunch.d/temp.cfg` out of every package
(`SKIP_SNIPPETS`), because Debian's `hobbit-plugins` owns that path and
dpkg refuses two packages claiming one file. rpm and FreeBSD have no
hobbit-plugins, so there the conflict does not exist, and the `temp`
extension never starts unless the snippet is copied from the doc
directory by hand. It could be installed for those two packages only,
following the dnf special case (a step in the spec's `%install`).
That needs:

- spec `%install`: copy the snippet from the staged docs into
  `%{xymonhome}/etc/clientlaunch.d/temp.cfg`; `%files`: a
  `%config(noreplace)` line for it;
- FreeBSD: the same step in `packaging/freebsd/build.sh` and an
  `@sample` line in `pkg-plist`;
- `tests/run.sh`: the pins for the skipped snippet (it must stay out of
  the deb and remain in the docs) and the pkg-plist/stage comparison;
- the post-install texts and `extensions/temp/README.md`, which say the
  snippet is installed by hand everywhere.

Not done: maintainer decision (source: installation on a Xymon 4.3.30
source build, Rocky Linux 10.3).

## README: "current upstream" drop-in lines unverified

`README.md` ("Wiring it up on your server") says current upstream
Xymon ships every config file with a trailing
`optional directory $XYMONHOME/etc/<name>.d` and names its server
drop-in directory `xymonserver.cfg.d`. Neither the 4.3.30 release nor
the SVN trunk (checked 2026-11-18) has such lines in `graphs.cfg`,
`rrddefinitions.cfg` or `xymonserver.cfg.DIST`, and their
`stackfgets()` expands no variables in a `directory` line, so a line
with `$XYMONHOME` would not work there. Find the release this
statement describes, or correct it (source: installation on a Xymon
4.3.30 source build, Rocky Linux 10.3).

## Unverified without hardware

- powerline: a plcrate response whose MAC differs from the queried
  adapter is treated as a hard error for that adapter; not verifiable
  without matching hardware (source: PLAN1.md).
- fritz-wifi: the 5 GHz per-client fixture
  (GetGenericAssociatedDeviceInfo) is still synthesized; replace it with
  a masked real response when a 5 GHz client is available (source:
  PLAN2.md, "Implementation status").
