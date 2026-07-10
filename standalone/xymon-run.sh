#!/bin/sh
#
# xymon-run.sh - minimal xymonlaunch replacement for hosts without a
# Xymon client (OpenWrt/TurrisOS routers, appliances, ...).
#
# Provides the Xymon environment ($XYMON, $XYMSRV, $MACHINE, ...) that
# the extensions in this repository rely on, with xymon-send.sh as the
# message transport, then runs the requested extension(s) from
# $XYMONHOME/ext/. Extensions run unmodified - they cannot tell the
# difference from a full Xymon client.
#
# usage: xymon-run.sh [-n] all
#        xymon-run.sh [-n] EXTENSION [EXTENSION ...]
#
#   -n   dry run: do not send anything, print the reports to stdout
#
# Configuration (POSIX shell, sourced), first match wins:
#   $STANDALONE_CFG, /etc/xymon-standalone.cfg,
#   $XYMONHOME/etc/standalone.cfg
#
# Typically driven by cron - see crontab.example.
set -u

BASEDIR=$(cd "$(dirname "$0")" && pwd) || exit 1

usage() {
    echo "usage: $0 [-n] all|EXTENSION [EXTENSION ...]" >&2
}

DRYRUN=""
if [ "${1:-}" = "-n" ]; then
    DRYRUN=yes
    shift
fi
if [ $# -lt 1 ]; then
    usage
    exit 1
fi

XYMONHOME="${XYMONHOME:-$BASEDIR}"

# Defaults; the config file may override any of these.
XYMSRV="${XYMSRV:-}"
MACHINEDOTS="${MACHINEDOTS:-}"
XYMONTMP="${XYMONTMP:-/tmp}"
XYMONCLIENTLOGS="${XYMONCLIENTLOGS:-}"
XYMONDPORT="${XYMONDPORT:-1984}"

CFG=""
for f in "${STANDALONE_CFG:-}" /etc/xymon-standalone.cfg "$XYMONHOME/etc/standalone.cfg"; do
    if [ -n "$f" ] && [ -r "$f" ]; then
        CFG=$f
        break
    fi
done
if [ -n "$CFG" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFG"
fi

if [ -z "$MACHINEDOTS" ]; then
    MACHINEDOTS=$(hostname -f 2>/dev/null)
    [ -n "$MACHINEDOTS" ] || MACHINEDOTS=$(uname -n)
fi
MACHINE=$(printf '%s' "$MACHINEDOTS" | tr '.' ',')

LOGDIR="${XYMONCLIENTLOGS:-$XYMONTMP}"

# The configured directories may not exist yet: on OpenWrt /tmp is a
# RAM disk (and /var a symlink to it), so anything below it is gone
# after a reboot. Extensions expect $XYMONTMP to exist.
mkdir -p "$XYMONTMP" "$LOGDIR" || exit 1

if [ -n "$DRYRUN" ]; then
    # Empty XYMON/XYMSRV switch the extensions into print-to-stdout mode
    XYMON=""
    XYMSRV=""
else
    if [ -z "$XYMSRV" ]; then
        echo "$0: XYMSRV is not set - configure the Xymon server address" \
             "(e.g. in /etc/xymon-standalone.cfg)" >&2
        exit 1
    fi
    XYMON="$BASEDIR/xymon-send.sh"
fi

XYMSERVERS="$XYMSRV"
XYMONCLIENTLOGS="$LOGDIR"
export XYMON XYMSRV XYMSERVERS XYMONDPORT
export XYMONHOME XYMONTMP XYMONCLIENTLOGS
export MACHINE MACHINEDOTS

run_ext() {
    r_script="$XYMONHOME/ext/$1.sh"
    if [ ! -x "$r_script" ]; then
        echo "$0: extension not found or not executable: $r_script" >&2
        return 1
    fi
    if [ -n "$DRYRUN" ]; then
        "$r_script"
    else
        "$r_script" > "$LOGDIR/$1.log" 2>&1
    fi
}

RC=0
if [ "$1" = "all" ]; then
    found=""
    for script in "$XYMONHOME"/ext/*.sh; do
        [ -e "$script" ] || continue    # glob did not match anything
        found=yes
        ext=$(basename "$script" .sh)
        run_ext "$ext" || RC=1
    done
    if [ -z "$found" ]; then
        echo "$0: no extensions installed in $XYMONHOME/ext" >&2
        RC=1
    fi
else
    for ext in "$@"; do
        run_ext "$ext" || RC=1
    done
fi
exit "$RC"
