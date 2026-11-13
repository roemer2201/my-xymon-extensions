# libvirt graphs

Install `my-xymon-extensions-server` on the Xymon server, or place the
supplied drop-ins in its `xymonserver.d` and `graphs.d` directories and
restart Xymon. See the [server setup in the project README](../../../README.md#server-side-setup-drop-in-directories).
The graphs appear under the hypervisor's `libvirt` status. The CPU graph
also appears under `trends`.

| Graph | Unit |
|---|---|
| CPU utilization | Percent of one host CPU core. A VM using two cores can reach 200%. |
| QEMU resident memory (RSS) | MiB measured on the hypervisor. |
| Network RX and TX | kbit/s from the corresponding libvirt counters, summed across the VM's interfaces. |
| Disk reads and writes | MiB/s summed across the VM's reported block devices. |

RRD files are named `libvirt,<vm>_<metric>.rrd`. Letters, digits and
hyphens are preserved in the VM name and other bytes are encoded as
`_hh`. Names whose encoded form exceeds 200 characters still appear in
the status but have no graphs.

The client calculates rates from consecutive polls and sends unknown
values when a counter resets, a VM stops, or a required counter is
missing from either poll. A guest with `block.count=0` has no disk
metrics. The first poll supplies the baseline for rates. Keep the
default five-minute interval. Rate calculations require two samples
less than ten minutes apart.
