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

## Unverified without hardware

- powerline: a plcrate response whose MAC differs from the queried
  adapter is treated as a hard error for that adapter; not verifiable
  without matching hardware (source: PLAN1.md).
- fritz-wifi: the 5 GHz per-client fixture
  (GetGenericAssociatedDeviceInfo) is still synthesized; replace it with
  a masked real response when a 5 GHz client is available (source:
  PLAN2.md, "Implementation status").
