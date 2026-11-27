# Linux NFS server (nfsserver)

Enable the disabled clientlaunch.d/nfsserver.cfg task on Linux hosts that
must run kernel nfsd. For the standalone runner add nfsserver to TESTS.
The Xymon user needs read access to /proc/net/rpc/nfsd, the nfsd portlist,
the export configuration and /var/lib/nfs/etab. No sudo, exportfs lock,
exported data access or client-side mount is required. A Linux flock
command and a writable XYMONTMP are needed for serialized sampling.

The column is red for zero workers, absent kernel service interfaces, or
a missing required listener/export. It is yellow when required information
cannot be read or validated. Non-Linux hosts are clear. A valid idle server
stays green. Optional kernel statistics may be absent. An export registered
in etab describes the local server; measuring client latency needs a client.
Problems are listed first in the status, followed by the threads, the etab
exports and the listeners. Reading the portlist and filecache files takes
the kernel's nfsd mutex and can hang while nfsd is stuck; an overlapping invocation
reports yellow immediately. If the scheduler suppresses overlapping runs,
the previous status expires when no fresh report arrives.

## Configuration

Edit etc/my-xymon-extensions/nfsserver.cfg. Set REQUIRED_LISTENERS to
space-separated transport:port pairs (for example tcp:2049 rdma:20049).
By default the check compares paths in /etc/exports and non-hidden
/etc/exports.d/*.exports with etab. It compares paths only and displays the
registered client/options from etab. CHECK_CONFIGURED=no disables this
comparison. Add space-separated REQUIRED_EXPORTS to detect paths removed
from both the configuration and etab. Use exports-style octal escapes for
whitespace in these settings. The task ships with no site-specific paths.

## Trends

* Server-wide NFSv3/v4 data and metadata operation rates, RPC calls, bad RPCs
  and stale file handles. NFSv4 COMPOUND can contain several operations.
* Global payload read/write MiB/s. GLOBAL_BYTES=auto enables these on Linux
  5.12 and later (Rocky 9 and 10), where nfsd keeps its byte counters as
  64-bit per-CPU counters (fs/nfsd/stats.c). On older kernels the
  nfsserver-sampler task provides them; see "Byte sampler" below.
* Reply-cache entries, occupancy and reported memory; file-cache inodes/LRU
  when available. Transport events/s and send queue starvation when an RDMA
  listener and readable transport statistics are present.
* Per-export MiB/s when export_stats actually supplies samples. Rates sum
  the individual client-domain deltas. A change of membership/start time,
  counter reset, reboot, first observation or gap over ten minutes produces
  unknown. An empty statistics table is valid. An absent optional interface
  creates no RRD. Names in per-export graphs encode '/' as '+'.

## Rocky 8 (Linux 4.18)

The Rocky 8 kernel still has nfsd's old statistics code. Checked in the
Rocky 8.6, 8.8 and 8.10 kernel sources (ctrliq/kernel-src-tree, branches
rocky8_6, rocky8_8, rocky8_10):

* The "io" byte counters in /proc/net/rpc/nfsd are 32 bit (`unsigned int
  io_read, io_write` in fs/nfsd/stats.h) and wrap at 4 GiB. No counter
  records the wraps. At 13.65 MiB/s a five-minute interval transfers a full counter range.
  A decreasing counter produces an unknown sample; an increase after a
  full counter cycle can silently understate throughput.
* They are increased with a plain `+=` on a global variable
  (fs/nfsd/vfs.c), neither atomic nor locked, so nfsd threads running at
  the same time on different CPUs can lose increments.

Leave GLOBAL_BYTES at auto there: it uses the totals of the byte sampler
below when that task runs, and stays off otherwise. GLOBAL_BYTES=yes reads
the raw 32-bit counters every five minutes and gives no reliable
throughput. The operation and RPC counters are 32 bit too, but wrap only
after 2^32 operations.

The 8.10 kernel has neither /proc/fs/nfsd/filecache nor export_stats
(fs/nfsd/nfsctl.c), so the nfsfiles and nfsexport graphs do not appear;
the other graphs do.

Without the sampler, or to cross-check it, these counters are 64 bit on
Rocky 8; choose one based on scope:

* Interface counters, /sys/class/net/IF/statistics/rx_bytes and tx_bytes:
  all traffic of the interface, protocol overhead included, so only a good
  estimate on dedicated storage interfaces. The stock Xymon Linux client
  already sends them in its [ifstat] section (read with /sbin/ifconfig
  from net-tools) for the ifstat graphs. NFS over RDMA bypasses the
  network stack and is not counted on IPoIB interfaces.
* InfiniBand port counters for RDMA,
  /sys/class/infiniband/HCA/ports/N/counters/port_rcv_data and
  port_xmit_data: 64 bit when the HCA reports the extended width
  (drivers/infiniband/core/sysfs.c), otherwise 32 bit; in units of
  4 bytes, all traffic of the port.
* On the clients, the bytes: line of /proc/self/mountstats: exact NFS
  payload per mount, but per client.

## Byte sampler (kernels before 5.12)

nfsserver-sampler.sh is a second, long-running task in
clientlaunch.d/nfsserver.cfg ([nfsserver-sampler], shipped disabled).
Enable it only on kernels before 5.12, such as Rocky 8; on newer kernels
it logs once that there is nothing to sample and idles. It reads the
same nfsserver.cfg and needs no other rights than nfsserver.sh.

* Every SAMPLER_STEP seconds (1, or 0.5 where sleep accepts fractions) it
  reads /proc/uptime (1/100 s) and the io and rpc counters, and adds the
  32-bit increments to 64-bit totals.
* An interval is ambiguous when one more wrap would have fitted into it at
  SAMPLER_MAX_GBIT (default 25, per direction, the sum of all links that
  carry NFS), or when it counted faster than that plus 10 %. Such an
  interval makes the nfsserver byte rate of its five-minute window
  unknown; nothing is guessed. At 25 Gbit/s a 1 s sample may be about
  0.37 s late, a 0.5 s sample about 0.87 s.
* The totals start at 0 when the sampler starts (a restart of the Xymon
  client included), when nfsd's statistics are reset (loading the nfsd
  module; the RPC call counter drops without being near 2^32), while
  nfsd's statistics are unavailable, and before they reach 2^52 bytes.
  The first nfsserver run after such a start has nothing to compare with
  and reports unknown; the next one, five minutes later, has the rate.
* The totals go to $XYMONTMP/nfsserver-HOST/sampler every SAMPLER_SAVE
  seconds (default 10) and are removed when the sampler stops. A state
  older than 30 s turns the column yellow ("NFS byte sampler stopped
  updating"). The status lists the step, the age of the totals and the
  number of ambiguous intervals.
* It runs only under xymonlaunch, which starts it directly, and stops as
  soon as its parent process changes, i.e. when xymonlaunch is gone, or
  on TERM. A second instance exits at once (lock file). INTERVAL 1m in
  the task only restarts it should it ever stop; it has no MAXTIME and
  does not run through xymonext.sh. The standalone runner skips it.
* Lost increments of the kernel's plain `+=` remain: the totals are a
  lower bound.
* Cost: one sleep process per step and two small reads in /proc; a few
  bytes written every SAMPLER_SAVE seconds.

For a manual test, run it as the Xymon user with a separate XYMONTMP and
NFSSERVER_SAMPLER_ANYPARENT=yes; it then stops with that shell.

Use nfsserver.sh --help for environment overrides. With XYMON or XYMSRV
unset, the collector prints its messages; use a separate XYMONTMP when
testing manually to keep production baselines intact.
