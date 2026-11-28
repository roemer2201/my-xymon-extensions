#!/bin/sh
# Count the wraps of Linux nfsd's 32-bit byte counters (kernels before 5.12).
# 1. Check platform, kernel, parent process and the private state directory.
# 2. Every SAMPLER_STEP seconds read /proc/net/rpc/nfsd between two
#    uptime reads,
#    add the 32-bit increments to 64-bit totals and count every interval in
#    which a second wrap would have been possible at SAMPLER_MAX_GBIT.
# 3. Publish the totals for nfsserver.sh every SAMPLER_SAVE seconds, by
#    default on /dev/shm (tmpfs), so sampling writes to no disk.
# A long-running xymonlaunch task: it stops when xymonlaunch is gone and
# removes its totals when it stops.
# Usage: nfsserver-sampler.sh [--help]
# Version: 1.1.0 (2026-11-28)
set -u
export LC_ALL=C

case "$#:${1:-}" in
    0:) ;;
    1:-h|1:--help)
        cat <<'HELP'
Usage: nfsserver-sampler.sh [--help]
Sample the 32-bit byte counters of Linux nfsd (kernels before 5.12) every
second, count their wraps and publish 64-bit totals for nfsserver.sh.
Started by xymonlaunch (clientlaunch.d/nfsserver.cfg, [nfsserver-sampler]);
it exits when xymonlaunch is gone. SAMPLER_MAX_GBIT, SAMPLER_STEP and
SAMPLER_SAVE and SAMPLER_DIR in etc/my-xymon-extensions/nfsserver.cfg can be
overridden with NFSSERVER_SAMPLER_MAX_GBIT, NFSSERVER_SAMPLER_STEP,
NFSSERVER_SAMPLER_SAVE and NFSSERVER_SAMPLER_DIR. SAMPLER_DIR=auto keeps the
totals on /dev/shm (tmpfs) for a system user, else in XYMONTMP.
NFSSERVER_SAMPLER_ANYPARENT=yes runs it from a shell for a manual test; it
then stops with that shell. Use a separate XYMONTMP and
NFSSERVER_SAMPLER_DIR for manual tests.
HELP
        exit 0 ;;
    *) printf 'Usage: nfsserver-sampler.sh [--help]\n' >&2; exit 2 ;;
esac

machine=${MACHINE:-$(uname -n | tr '.' ',')}
proc=${NFSSERVER_PROC:-/proc}
config=${NFSSERVER_CFG:-${XYMONHOME:-${XYMONCLIENTHOME:-}}/etc/my-xymon-extensions/nfsserver.cfg}
# Test hooks: stop after this many passes and keep the totals; another
# sleep command (BusyBox ash has a sleep builtin that PATH cannot replace).
limit=${NFSSERVER_SAMPLER_LIMIT:-}
sleeper=${NFSSERVER_SAMPLER_SLEEP:-sleep}
passes=0
parent=$PPID

log() { printf '%s nfsserver-sampler: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }
# shellcheck disable=SC2086 # the hook may be a command with arguments
pause() { $sleeper "$1"; }
pass() { # false once the test hook's passes are done
    [ -n "$limit" ] || return 0
    passes=$((passes + 1))
    [ "$passes" -le "$limit" ]
}
# The parent stays the same while xymonlaunch runs; once it is gone the
# kernel hands this process to another one (PID 1 or a subreaper).
alive() {
    line=
    read -r line < "/proc/$$/stat" || return 1
    set -f
    # shellcheck disable=SC2086 # fields after "(comm) " are split on purpose
    set -- ${line##*) }
    set +f
    [ "${2:-}" = "$parent" ]
}

if [ "$(uname -s)" != Linux ]; then
    log 'not Linux - there are no nfsd counters to sample'
    exit 0
fi
if [ "$parent" = 1 ]; then
    log 'started without a parent process - refusing to run unattended'
    exit 1
fi
if [ "${NFSSERVER_SAMPLER_ANYPARENT:-no}" != yes ]; then
    comm=
    read -r comm < "/proc/$parent/comm" || comm=
    if [ "$comm" != xymonlaunch ]; then
        log "not started by xymonlaunch (parent: ${comm:-unknown}); NFSSERVER_SAMPLER_ANYPARENT=yes runs it by hand"
        exit 1
    fi
fi
if [ "$((4294967296 * 2))" != 8589934592 ]; then
    log 'this shell has no 64-bit arithmetic'
    exit 1
fi

if [ -f "$config" ] && [ -r "$config" ]; then
    case "$config" in */*) ;; *) config=./$config ;; esac
    # shellcheck disable=SC1090
    . "$config"
elif [ -e "$config" ] || [ -n "${NFSSERVER_CFG:-}" ]; then
    log "cannot read $config"
    exit 1
fi
maxgbit=${NFSSERVER_SAMPLER_MAX_GBIT-${SAMPLER_MAX_GBIT:-25}}
step=${NFSSERVER_SAMPLER_STEP-${SAMPLER_STEP:-1}}
save=${NFSSERVER_SAMPLER_SAVE-${SAMPLER_SAVE:-10}}
dirset=${NFSSERVER_SAMPLER_DIR-${SAMPLER_DIR:-auto}}
case "$dirset" in
    auto|/*) ;;
    *) log 'SAMPLER_DIR must be auto or an absolute path'; exit 1 ;;
esac
upto() { # upto VALUE MAX - a positive integer up to MAX
    case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 5 ] && [ "$1" -le "$2" ]
}
if ! upto "$maxgbit" 10000 || ! upto "$save" 60; then
    log 'SAMPLER_MAX_GBIT must be 1 to 10000, SAMPLER_SAVE 1 to 60'
    exit 1
fi
case "$step" in
    1) ;;
    0.5)
        # Fractions of a second are not POSIX; GNU coreutils has them, and
        # so does BusyBox in the usual configuration. The probe decides.
        if ! pause 0.01 2>/dev/null; then
            log 'this sleep has no fractions of a second - sampling every 1 s'
            step=1
        fi ;;
    *) log 'SAMPLER_STEP must be 1 or 0.5'; exit 1 ;;
esac

# Upstream nfsd keeps 64-bit byte counters since Linux 5.12
# (fs/nfsd/stats.c); nfsserver.sh reads those directly.
kernel=$(uname -r)
major=${kernel%%.*}
minor=${kernel#*.}
minor=${minor%%[!0-9]*}
if [ "$major" -gt 5 ] 2>/dev/null ||
   { [ "$major" -eq 5 ] 2>/dev/null && [ "${minor:-0}" -ge 12 ] 2>/dev/null; }; then
    # Idle instead of exiting, or xymonlaunch would restart it every minute.
    log "Linux $kernel has 64-bit nfsd byte counters - nothing to sample"
    while pass && alive; do pause 5 || sleep 1; done
    exit 0
fi

# The totals live on tmpfs where possible, so sampling never writes to a
# disk. nfsserver.sh and nfsserver-sampler.sh carry this function alike.
sampler_dir() { # sampler_dir SETTING FALLBACK - prints the directory
    case "$1" in
        auto)
            shm=${NFSSERVER_SHM:-/dev/shm}
            # systemd-logind's RemoveIPC (default yes) deletes every
            # /dev/shm entry of a non-system user at its last logout
            # (logind.conf(5), src/shared/clean-ipc.c): only a system
            # user (UID up to 999) keeps its totals there.
            if [ "$(id -u)" -le 999 ] && [ -d "$shm" ] && [ -w "$shm" ] &&
               awk -v d="$shm" '$2 == d && ($3 == "tmpfs" || $3 == "ramfs") {f = 1} END {exit !f}' \
                   "$proc/mounts" 2>/dev/null; then
                printf '%s\n' "$shm/nfsserver-$machine"
            else
                printf '%s\n' "$2"
            fi ;;
        *) printf '%s\n' "${1%/}/nfsserver-$machine" ;;
    esac
}
case "$machine" in ''|*[!a-zA-Z0-9._,-]*) log 'invalid machine name'; exit 1 ;; esac
# A private directory, with the same checks as nfsserver.sh's own.
state=$(sampler_dir "$dirset" "${XYMONTMP:-${TMPDIR:-/tmp}}/nfsserver-$machine") || exit 1
umask 077
if ! mkdir -m 700 "$state" 2>/dev/null; then
    if [ -L "$state" ] || [ ! -d "$state" ] ||
       [ "$(stat -c '%u:%a' "$state")" != "$(id -u):700" ]; then
        log "cannot use the private state directory $state"
        exit 1
    fi
fi
if ! command -v flock >/dev/null 2>&1; then
    log 'flock is required'
    exit 1
fi
# Its own lock: nfsserver.sh locks the directory itself.
exec 8> "$state/sampler.lock" || exit 1
if ! flock -n 8; then
    log 'another sampler is running'
    exit 0
fi
log "totals in $state"
# A former owner may have been killed without a chance to clean up.
# Never reuse its state while waiting for a first readable sample.
rm -f "$state/sampler" "$state/sampler.new" || exit 1
boot=
read -r boot < "$proc/sys/kernel/random/boot_id" || boot=
if [ -z "$boot" ]; then
    log 'cannot read the boot id'
    exit 1
fi

stop() { # stop REASON - totals are only valid while this process runs
    rm -f "$state/sampler" "$state/sampler.new" || exit 1
    log "$1 - stopping"
    exit 0
}
trap 'stop terminated' TERM INT HUP

two32=4294967296
# Bytes per 1/100 s at the configured line rate (per direction), and RPC
# calls per 1/100 s that no NFS server reaches (10 million per second).
rmax=$((maxgbit * 1250000))
callmax=100000

read_uptime() { # sets stamp (1/100 s)
    up=
    read -r up _ < "$proc/uptime" || return 1
    case "$up" in
        [0-9]*.[0-9][0-9]) ;;
        *) return 1 ;;
    esac
    case "${up%.*}" in *[!0-9]*) return 1 ;; esac
    stamp=$(( ${up%.*} * 100 + 1${up#*.} - 100 ))
}
sample() { # sets first/now and cr, cw, cc; false when a value is missing
    # The kernel formats the counters during the read. If the sampler
    # is delayed anywhere around it, use both timestamps to bound the
    # interval instead of assuming the counters were read at its start.
    read_uptime || return 1
    first=$stamp
    cr='' cw='' cc=''
    [ -r "$proc/net/rpc/nfsd" ] || return 1
    while read -r key a b _; do
        case "$key" in
            io) cr=$a; cw=$b ;;
            rpc) cc=$a ;;
        esac
        [ -z "$cr" ] || [ -z "$cw" ] || [ -z "$cc" ] || break
    done < "$proc/net/rpc/nfsd" || return 1
    read_uptime || return 1
    now=$stamp
    [ "$now" -ge "$first" ] || return 1
    for value in "$cr" "$cw" "$cc"; do
        case "$value" in ''|*[!0-9]*) return 1 ;; esac
    done
    # Larger values mean the counters are not the 32-bit ones after all.
    [ $(( cr < two32 && cw < two32 && cc < two32 )) -eq 1 ]
}
save_state() {
    if printf 'version 1\nboot %s\nepoch %s\ngen %s\ntime %s\nread %s\nwrite %s\nstep %s\nsave %s\n' \
            "$boot" "$epoch" "$gen" "$last" "$tr" "$tw" "$step" "$save" > "$state/sampler.new" &&
       mv -f "$state/sampler.new" "$state/sampler"; then
        :
    else
        log 'cannot write the totals'
    fi
    saved=$last
}
new_epoch() { # new_epoch REASON - totals restart at 0
    epoch=$now gen=0 tr=0 tw=0
    pr=$cr pw=$cw pc=$cc last=$now prev_first=$first
    log "counting from 0: $1"
    save_state
}

epoch=
while :; do
    pass || exit 0
    alive || stop 'xymonlaunch is gone'
    if ! sample; then
        if [ -n "$epoch" ]; then
            log 'nfsd statistics unavailable - totals dropped'
            rm -f "$state/sampler"
            epoch=
        fi
    elif [ -z "$epoch" ]; then
        new_epoch 'sampler started'
    elif [ "$now" -gt "$last" ]; then
        # Add one centisecond for /proc/uptime rounding. At 1 Gbit/s
        # even the largest modulo delta could hide a wrap after 70 s.
        # Capping the bound there also keeps byte-rate arithmetic safe
        # after a very long suspend.
        dt=$((now - prev_first + 1))
        bdt=$dt
        [ "$bdt" -le 7000 ] || bdt=7000
        # A reset (only on loading the nfsd module) sets every counter to
        # 0. The RPC call counter can only wrap from just below 2^32.
        if [ $(( cc < pc && dt < 42950 && pc < two32 - callmax * dt )) -eq 1 ]; then
            new_epoch 'nfsd statistics were reset'
        else
            dr=$(( (cr - pr + two32) % two32 ))
            dw=$(( (cw - pw + two32) % two32 ))
            # Ambiguous: one more wrap would have fitted into this interval.
            if [ $(( dr + two32 <= rmax * bdt || dw + two32 <= rmax * bdt )) -eq 1 ]; then
                gen=$((gen + 1))
            # Faster than SAMPLER_MAX_GBIT (10 % for timing jitter): the
            # limit is too low, so a second wrap could go unnoticed.
            elif [ $(( dr * 10 > rmax * bdt * 11 || dw * 10 > rmax * bdt * 11 )) -eq 1 ]; then
                gen=$((gen + 1))
                [ -n "${fast:-}" ] || log "traffic above SAMPLER_MAX_GBIT=$maxgbit - raise it"
                fast=yes
            fi
            tr=$((tr + dr)) tw=$((tw + dw))
            pr=$cr pw=$cw pc=$cc last=$now prev_first=$first
            # awk, which computes the rates, is exact up to 2^53.
            if [ $(( tr > 4503599627370496 || tw > 4503599627370496 )) -eq 1 ]; then
                new_epoch 'the totals reached 2^52'
            else
                [ $((last - saved)) -lt $((save * 100)) ] || save_state
            fi
        fi
    fi
    # Never spin: a failing sleep (hook) still waits a second.
    pause "$step" || sleep 1
done
