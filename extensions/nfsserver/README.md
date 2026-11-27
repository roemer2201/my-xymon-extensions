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
  6 and later; older vendor kernels require explicit GLOBAL_BYTES=yes after
  confirming wide byte counters. Multiple 32-bit wraps per poll lose data.
* Reply-cache entries, occupancy and reported memory; file-cache inodes/LRU
  when available. Transport events/s and send queue starvation when an RDMA
  listener and readable transport statistics are present.
* Per-export MiB/s when export_stats actually supplies samples. Rates sum
  the individual client-domain deltas. A change of membership/start time,
  counter reset, reboot, first observation or gap over ten minutes produces
  unknown. An empty statistics table is valid. An absent optional interface
  creates no RRD. Names in per-export graphs encode '/' as '+'.

Use nfsserver.sh --help for environment overrides. With XYMON or XYMSRV
unset, the collector prints its messages; use a separate XYMONTMP when
testing manually to keep production baselines intact.
