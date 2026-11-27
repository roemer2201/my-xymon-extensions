#!/bin/sh
# Replay Rocky 8/10 style nfsd snapshots through the installed entry point.
set -u
here=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM
export MACHINE=nfstest XYMONTMP="$tmp" XYMON='' XYMSRV=''
export NFSSERVER_PROC="$tmp/proc" NFSSERVER_ETC="$tmp/etc" NFSSERVER_ETAB="$tmp/etab"
export NFSSERVER_REQUIRED_LISTENERS="tcp:2049" NFSSERVER_GLOBAL_BYTES=yes
export NFSSERVER_CFG="$tmp/monitor.cfg"
: > "$NFSSERVER_CFG"
p=$NFSSERVER_PROC
mkdir -p "$p/net/rpc" "$p/fs/nfsd" "$p/sys/kernel/random" "$p/sys/sunrpc/svc_rdma" "$tmp/etc/exports.d"
printf 'test-boot\n' > "$p/sys/kernel/random/boot_id"
printf '/home *(rw)\n"/work dir" *(rw)\n' > "$tmp/etc/exports"
printf '/home\t*(rw,async)\n/work\\040dir\t*(rw,sync)\n' > "$tmp/etab"
printf 'tcp 2049\ntcp 2049\n' > "$p/fs/nfsd/portlist"
printf 'num entries: 4535\nmax entries: 221120\nmem usage: 1201472688\n' > "$p/fs/nfsd/reply_cache_stats"
rpc() {
    awk -v val="$1" 'BEGIN {
        print "th 64 0"; print "rpc",val,0,0,0,0; print "fh 0 0 0 0 0"
        print "io", val*1024, val*2048
        printf "proc3 22"; for(i=0;i<22;i++) printf " %d", (i==6 ? val : 0); print ""
        printf "proc4ops 76"; for(i=0;i<76;i++) printf " %d", (i==25 ? val : 0); print ""
    }' > "$p/net/rpc/nfsd"
}
run() {
    # shellcheck disable=SC2086 # CI supplies "busybox sh".
    ${TESTSH:-sh} "$here/extensions/nfsserver/nfsserver.sh" > "$tmp/output" || exit 1
}
has() { grep -Eq "$1" "$tmp/output" || { cat "$tmp/output"; echo "missing: $1" >&2; exit 1; }; }
lacks() { if grep -Eq "$1" "$tmp/output"; then echo "unexpected: $1" >&2; exit 1; fi; }
age() {
    prev="$tmp/nfsserver-nfstest/previous"
    awk 'NR==1 {$2-=60} {print}' "$prev" > "$tmp/aged" && mv "$tmp/aged" "$prev"
}
export_sample() {
    printf '# Version 1.1\n# Path Client Start-time\n/home\t*\t%s\n\tio_read: %s\n\tio_write: 0\n' "$1" "$2" > "$p/fs/nfsd/export_stats"
}
value() { awk -v section="[$1.rrd]" -v ds="DS:$2:" '/^\[/ {use=($0==section)} use && index($0,ds)==1 {print $2}' "$tmp/output"; }
rpc 100
run
has '^status nfstest.nfsserver green'
has '^data nfstest\.trends$'
has '^Export /work'
has '^DS:entries:GAUGE:600:0:U 4535$'
lacks '^\[(nfsexport|nfsrdma|nfsfiles)'
[ "$(value nfsserver read)" = U ] || exit 1
age; rpc 160
printf 'rdma 20049\n' >> "$p/fs/nfsd/portlist"
printf '0\n' > "$p/sys/sunrpc/svc_rdma/rdma_stat_recv"
printf 'total inodes: 0\nlru entries: 0\n' > "$p/fs/nfsd/filecache"
export_sample 92 100
run
has '^\[nfsrdma.rrd\]'; has '^\[nfsfiles.rrd\]'
awk -v rate="$(value nfsserver read)" 'BEGIN {exit !(rate>1.88 && rate<=2)}' || exit 1
[ "$(value nfsexport,+home read)" = U ] || exit 1
age; export_sample 92 62914660; run
awk -v rate="$(value nfsexport,+home read)" 'BEGIN {exit !(rate>0.94 && rate<=1)}' || exit 1
age; export_sample 105 62914660; run
[ "$(value nfsexport,+home read)" = U ] || exit 1
printf '# Version 1.1\n' > "$p/fs/nfsd/export_stats"
age; run
[ "$(value nfsexport,+home read)" = U ] || exit 1
has '^status nfstest.nfsserver green'
printf '/scratchtemp *(rw)\n' > "$tmp/etc/exports.d/test.exports"
run; has '^status nfstest.nfsserver red'; has 'Missing export /scratchtemp'
rm "$tmp/etab"; run
has '^status nfstest.nfsserver yellow'; lacks 'Missing export'
printf '/home *(rw)\n' > "$tmp/etab"
NFSSERVER_CHECK_CONFIGURED=no NFSSERVER_REQUIRED_LISTENERS=rdma:333 run
has 'Missing listener rdma:333'
printf 'th 0\nrpc 0 0 0 0 0\n' > "$p/net/rpc/nfsd"
run; has 'No NFS server threads'
echo 'ok: NFS server service, permissions, transport, export generation and rates'
