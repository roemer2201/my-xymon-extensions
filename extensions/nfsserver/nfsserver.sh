#!/bin/sh
# Monitor a local Linux kernel NFS server without root privileges.
# 1. Snapshot readable kernel and export data. 2. Compare with requirements.
# 3. Send the status and rate graphs, then publish the new counter baseline.
# Usage: nfsserver.sh [--help]
# Version: 1.0.0 (2026-11-27)
set -u
export LC_ALL=C

case "$#:${1:-}" in
    0:) ;;
    1:-h|1:--help)
        cat <<'HELP'
Usage: nfsserver.sh [--help]
Read Linux nfsd statistics and send a status and native trends to Xymon.
NFSSERVER_CFG selects the shell config in etc/my-xymon-extensions.
NFSSERVER_REQUIRED_EXPORTS, NFSSERVER_REQUIRED_LISTENERS,
NFSSERVER_CHECK_CONFIGURED and NFSSERVER_GLOBAL_BYTES override its settings.
NFSSERVER_PROC, NFSSERVER_ETC and NFSSERVER_ETAB override the input paths.
Example: NFSSERVER_REQUIRED_EXPORTS=/home nfsserver.sh
HELP
        exit 0 ;;
    *) printf 'Usage: nfsserver.sh [--help]\n' >&2; exit 2 ;;
esac

machine=${MACHINE:-$(uname -n | tr '.' ',')}
work=$(mktemp -d "${XYMONTMP:-${TMPDIR:-/tmp}}/nfsserver.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 1' INT TERM
proc=${NFSSERVER_PROC:-/proc}
etc=${NFSSERVER_ETC:-/etc}
etab=${NFSSERVER_ETAB:-/var/lib/nfs/etab}
config=${NFSSERVER_CFG:-${XYMONHOME:-${XYMONCLIENTHOME:-}}/etc/my-xymon-extensions/nfsserver.cfg}

send() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" @ < "$1"
    else
        cat "$1"
    fi
}
status() {
    printf 'status %s.nfsserver %s %s - %s\n' "$machine" "$1" "$(date)" "$2" > "$work/message" || return 1
    [ ! -f "$work/details" ] || cat "$work/details" >> "$work/message" || return 1
    send "$work/message"
}
if [ "$(uname -s)" != Linux ]; then
    status clear 'Linux kernel NFS statistics unavailable on this platform'
    exit "$?"
fi

if [ -f "$config" ] && [ -r "$config" ]; then
    case "$config" in */*) ;; *) config=./$config ;; esac
    # shellcheck disable=SC1090
    . "$config"
elif [ -e "$config" ] || [ -n "${NFSSERVER_CFG:-}" ]; then
    status yellow 'Cannot read NFS monitoring configuration'
    exit "$?"
fi
exports=${NFSSERVER_REQUIRED_EXPORTS-${REQUIRED_EXPORTS:-}}
listeners=${NFSSERVER_REQUIRED_LISTENERS-${REQUIRED_LISTENERS:-}}
compare=${NFSSERVER_CHECK_CONFIGURED-${CHECK_CONFIGURED:-yes}}
bytes=${NFSSERVER_GLOBAL_BYTES-${GLOBAL_BYTES:-auto}}
case "$compare:$bytes" in
    yes:auto|no:auto|yes:yes|no:yes|yes:no|no:no) ;;
    *) status yellow 'Invalid CHECK_CONFIGURED or GLOBAL_BYTES setting'; exit "$?" ;;
esac
if [ "$bytes" = auto ]; then
    kernel=$(uname -r)
    major=${kernel%%.*}
    if [ "$major" -ge 6 ] 2>/dev/null; then bytes=yes; else bytes=no; fi
fi

# Serialize the baseline and both sends. Use private state even when the
# manual diagnostic mode falls back to a shared temp directory.
case "$machine" in ''|*[!a-zA-Z0-9._,-]*) status yellow 'Invalid machine name'; exit "$?" ;; esac
state="${XYMONTMP:-${TMPDIR:-/tmp}}/nfsserver-$machine"
umask 077
if ! mkdir -m 700 "$state" 2>/dev/null; then
    if [ -L "$state" ] || [ ! -d "$state" ] ||
       [ "$(stat -c '%u:%a' "$state")" != "$(id -u):700" ]; then
        status yellow 'Cannot use private counter state directory'
        exit "$?"
    fi
fi
if ! command -v flock >/dev/null 2>&1; then
    status yellow 'flock is required for counter snapshots'
    exit "$?"
fi
exec 9< "$state" || exit 1
flock -x 9 || exit 1
# Stage complete reads: a failed read must never look like an empty table.
# Diagnostics use controlled labels (export filenames can contain HTML).
: > "$work/problems"
snapshot() { # SOURCE NAME required|optional
    if [ -e "$1" ] && cat "$1" > "$work/$2"; then return 0; fi
    : > "$work/$2" || exit 1
    if [ "$3" = required ] || [ -e "$1" ]; then
        printf '%s\n' "$2" >> "$work/problems" || exit 1
    fi
}
if [ ! -e "$proc/net/rpc/nfsd" ] && [ ! -e "$proc/fs/nfsd/portlist" ]; then
    status red 'Kernel NFS server interfaces are absent on this monitored host'
    exit "$?"
fi
snapshot "$proc/net/rpc/nfsd" rpc required
snapshot "$proc/fs/nfsd/portlist" ports required
snapshot "$etab" etab required
snapshot "$proc/fs/nfsd/export_stats" perexport optional
snapshot "$proc/fs/nfsd/reply_cache_stats" cache optional
snapshot "$proc/fs/nfsd/filecache" filecache optional
: > "$work/configured"
if [ "$compare" = yes ]; then
    if [ -d "$etc/exports.d" ] && { [ ! -r "$etc/exports.d" ] || [ ! -x "$etc/exports.d" ]; }; then
        printf 'configured\n' >> "$work/problems"
    fi
    for file in "$etc/exports" "$etc"/exports.d/*.exports; do
        [ -f "$file" ] || continue
        case "${file##*/}" in .*) continue ;; esac
        if cat "$file" >> "$work/configured"; then
            printf '\n' >> "$work/configured"
        else
            printf 'configured\n' >> "$work/problems"
        fi
    done
fi
: > "$work/rdma"
if grep -Eq '^rdma[[:space:]]' "$work/ports"; then
    for counter in recv read write sq_starve; do
        snapshot "$proc/sys/sunrpc/svc_rdma/rdma_stat_$counter" transport optional
        if IFS= read -r value < "$work/transport"; then
            printf '%s %s\n' "$counter" "$value" >> "$work/rdma"
        fi
    done
fi

# Compare consecutive samples only within the same kernel boot.
previous="$state/previous"
[ -f "$previous" ] || previous=/dev/null
boot=$(cat "$proc/sys/kernel/random/boot_id") || exit 1
now=$(date +%s) || exit 1
export NFS_REQUIRED_PATHS="$exports" NFS_REQUIRED_PORTS="$listeners"
awk -v machine="$machine" -v out="$work" -v now="$now" -v boot="$boot" -v bytes="$bytes" \
    -f "$(dirname "$0")/nfsserver.awk" \
    source=previous "$previous" source=problems "$work/problems" \
    source=configured "$work/configured" source=etab "$work/etab" \
    source=ports "$work/ports" source=rpc "$work/rpc" \
    source=cache "$work/cache" source=filecache "$work/filecache" \
    source=perexport "$work/perexport" source=rdma "$work/rdma" || exit 1
IFS= read -r color < "$work/color" || exit 1
IFS= read -r summary < "$work/summary" || exit 1
status "$color" "$summary" || exit 1
send "$work/trends" || exit 1
mv -f "$work/next" "$state/previous"
