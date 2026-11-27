# Open work

## SMART polling interval

The [shipped task](packaging/common/clientlaunch.d/smart.cfg) runs every
10 minutes, exactly the 600-second heartbeat of the split-NCV RRDs.
Scheduler delays can push consecutive samples over the heartbeat and
leave gaps across all disks. Compare the planned 9-minute trial with a
5-minute interval before choosing a new default. If the default changes,
update the [SMART documentation](extensions/smart/README.md) and note in
the changelog that upgrades preserve locally edited task files, so those
hosts keep the old interval.

The standalone runner's example schedule
([crontab.example](standalone/crontab.example), repeated in
[standalone/README.md](standalone/README.md) and the opkg postinst) runs
every extension every 10 minutes as well. cron starts on time, but the
samples still arrive after a varying run time, so its graphs probably
sit at the same limit; check them before choosing the new default.

## Maintainer decisions

- **License:** Choose a license, then update the
  [README](README.md#license) and the
  [RPM spec](packaging/rpm/my-xymon-extensions.spec). Both still say TBD.
- **FreeBSD validation:** The VM job in the
  [CI workflow](.github/workflows/ci.yml) is disabled. Decide whether to
  re-enable it (the commented-out job still pins FreeBSD 14.2; choose a
  currently supported release). Until it runs again, run the tests and
  a native package build on a supported FreeBSD release by hand before
  claiming that platform has been verified.
- **Server packages outside Debian/Ubuntu:** The
  [manual install recipe](README.md#recipe-a-server-without-the-debian-package)
  covers source installations. If an RPM or FreeBSD server package is
  needed, check the server task paths and powerline helper's fixed tool
  paths on the target first. A `make server-install` target was
  considered and not built: without a package manager it would have to
  handle edited files on an update by itself, and it must never touch a
  stock config file. A server rpm is the better answer if non-Debian
  servers become common.

## Checks that need hardware

- **Powerline:** Verify on PLC hardware how to handle a `plcrate` response
  naming a different MAC from the adapter queried. The collector currently
  reports an error for that adapter.
- **fritz-wifi:** Replace the synthetic 5 GHz per-client response with a
  masked `GetGenericAssociatedDeviceInfo` capture when a 5 GHz client is
  available. See the
  [fritz-wifi test notes](extensions/fritz-wifi/server/README.md#test-scope).
