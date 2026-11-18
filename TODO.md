# Open work

## SMART polling interval

The [shipped task](packaging/common/clientlaunch.d/smart.cfg) runs every
10 minutes, exactly the 600-second heartbeat of the split-NCV RRDs.
Scheduler delays can push consecutive samples over the heartbeat and
leave gaps across all disks. Compare the planned 9-minute trial with a
5-minute interval before choosing a new default. If the default changes,
update the [SMART documentation](extensions/smart/README.md) and note
that upgrades preserve locally edited task files.

## Maintainer decisions

- **License:** Choose a license, then update the [README](README.md#license)
  and the [RPM spec](packaging/rpm/my-xymon-extensions.spec). Both still say TBD.
- **FreeBSD validation:** The VM job in the [CI workflow](.github/workflows/ci.yml)
  is disabled. Run the tests and a native package build on a supported
  FreeBSD release before claiming that platform has been verified.
- **Server packages outside Debian/Ubuntu:** The [manual install recipe](README.md#recipe-a-server-without-the-debian-package)
  covers source installations. If an RPM or FreeBSD server package is needed,
  check the server task paths and powerline helper's fixed tool paths on the
  target first.

## Checks that need hardware

- **Powerline:** Verify on PLC hardware how to handle a `plcrate` response
  naming a different MAC from the adapter queried. The collector currently
  reports an error for that adapter.
- **fritz-wifi:** Replace the synthetic 5 GHz per-client response with a
  masked `GetGenericAssociatedDeviceInfo` capture when a 5 GHz client is
  available. See the [fritz-wifi test notes](extensions/fritz-wifi/server/README.md).
