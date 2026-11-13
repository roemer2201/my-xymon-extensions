# libvirt

The `libvirt` column lists the state of every visible QEMU/KVM guest on the
local system connection. The extension runs as the Xymon client user and
uses one read-only `virsh domstats` query. It needs `virsh` and `timeout`.

1. Verify that the client user can see the system guests. Run as root.

   ```sh
   runuser -u xymon -- virsh --readonly --connect qemu:///system \
       domstats --state --raw
   ```

2. Edit `$XYMONHOME/etc/my-xymon-extensions/libvirt.cfg`
   (`/etc/xymon/my-xymon-extensions/libvirt.cfg` on Debian and Ubuntu).
   List the guests that must be running by their exact libvirt names,
   separated by spaces. For example:

   ```sh
   LIBVIRT_REQUIRED="vm01 vm02"
   ```

3. Remove `DISABLED` from the `[libvirt]` task in
   `$XYMONHOME/etc/clientlaunch.d/libvirt.cfg`. The task runs every five
   minutes. With the standalone runner, add `libvirt` to `TESTS` instead.

| Color | Condition |
|---|---|
| Green | All required guests are running. With an empty list, a successful query is sufficient. |
| Red | A required guest is missing or has a state other than running, or the query fails or times out. |
| Clear | A required tool is missing. |

Guests outside the required list appear in the details in any state. The
test checks the state reported by libvirt. Guest network reachability and
services inside the guest can be monitored separately through Xymon.

Running guests also supply CPU utilization, QEMU resident memory and
network and disk throughput where libvirt exposes the counters. See the
[server setup](server/README.md) for the graph definitions and units.

[libvirt read-only sockets](https://libvirt.org/daemons.html) ·
[virsh domstats](https://libvirt.org/manpages/virsh.html#domstats)
