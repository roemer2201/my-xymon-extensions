# TODO

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
