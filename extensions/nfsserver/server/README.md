# NFS server graphs

Install the server package or copy graphs.d/nfsserver.cfg and
xymonserver.d/nfsserver.cfg into the corresponding drop-in directories
loaded by the Xymon server, as described in the repository README.
Reload the server configuration. Check the nfsserver status page and the
host RRD directory after two five-minute polls. The collector uses native
trends messages with explicit unknowns. Missing optional data may leave
individual graphs unavailable. Configure alerts on the nfsserver column.

`make graphcheck` (Python 3 + rrdtool) runs the collector twice against a
fixture /proc tree that offers every optional interface, creates the RRDs
from its trends message and renders every graph. It fails when a graph
refers to a file or data source the collector does not send, or when the
collector sends a data source no graph draws. No NFS server or Xymon
daemon is involved.
