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
# When the xymonext extension is installed, the extensions are run
# through its wrapper ($XYMONHOME/ext/xymonext.sh), which measures
# their runtime, CPU time and traffic and reports them in the
# "xymonext" column. XYMONEXT_ENABLE="no" in the config file turns
# that off and runs the extensions directly.
#
# "all" runs the extensions listed in TESTS in the config file; with
# TESTS unset or empty it runs every extension installed in
# $XYMONHOME/ext/. Naming extensions explicitly always runs exactly
# those, whether in TESTS or not.
#
# Configuration (POSIX shell, sourced), first match wins:
#   $STANDALONE_CFG, /etc/xymon-standalone/standalone.cfg,
#   /etc/xymon-standalone.cfg (legacy), $XYMONHOME/etc/standalone.cfg
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
TESTS="${TESTS:-}"
XYMONEXT_ENABLE="${XYMONEXT_ENABLE:-yes}"

CFG=""
for f in "${STANDALONE_CFG:-}" /etc/xymon-standalone/standalone.cfg \
         /etc/xymon-standalone.cfg "$XYMONHOME/etc/standalone.cfg"; do
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
             "(e.g. in /etc/xymon-standalone/standalone.cfg)" >&2
        exit 1
    fi
    XYMON="$BASEDIR/xymon-send.sh"
fi

XYMSERVERS="$XYMSRV"
XYMONCLIENTLOGS="$LOGDIR"
export XYMON XYMSRV XYMSERVERS XYMONDPORT
export XYMONHOME XYMONTMP XYMONCLIENTLOGS
export MACHINE MACHINEDOTS

# is_off <value> -- true for the usual spellings of "switched off"
is_off() {
    case "$1" in
        no|No|NO|off|Off|OFF|0|false|False|FALSE) return 0 ;;
    esac
    return 1
}

run_ext() {
    r_ext=$1
    case "$r_ext" in
        xymonext|xymonext-send)
            echo "$0: $r_ext is the measurement wrapper, not a test" \
                 "- remove it from TESTS" >&2
            return 1
            ;;
    esac
    r_script="$XYMONHOME/ext/$r_ext.sh"
    if [ ! -x "$r_script" ]; then
        echo "$0: extension not found or not executable: $r_script" >&2
        return 1
    fi
    # Run the extension through the xymonext wrapper when it is
    # installed: the extension itself runs unchanged, and the wrapper
    # adds the "xymonext" column with its runtime, CPU time and the
    # number of bytes it sent.
    r_wrap="$XYMONHOME/ext/xymonext.sh"
    if [ -x "$r_wrap" ] && ! is_off "$XYMONEXT_ENABLE"; then
        set -- "$r_wrap" "$r_ext"
    else
        set -- "$r_script"
    fi
    if [ -n "$DRYRUN" ]; then
        "$@"
    else
        "$@" > "$LOGDIR/$r_ext.log" 2>&1
    fi
}

RC=0
if [ "$1" = "all" ]; then
    if [ -n "$TESTS" ]; then
        # shellcheck disable=SC2086  # TESTS is intentionally word-split
        for ext in $TESTS; do
            run_ext "$ext" || RC=1
        done
    else
        found=""
        for script in "$XYMONHOME"/ext/*.sh; do
            [ -e "$script" ] || continue    # glob did not match anything
            case "$script" in
                # Measurement wrapper and its transport shim: they run
                # extensions, they are not extensions themselves.
                */xymonext.sh|*/xymonext-send.sh) continue ;;
            esac
            found=yes
            ext=$(basename "$script" .sh)
            run_ext "$ext" || RC=1
        done
        if [ -z "$found" ]; then
            echo "$0: no extensions installed in $XYMONHOME/ext" >&2
            RC=1
        fi
    fi
else
    for ext in "$@"; do
        run_ext "$ext" || RC=1
    done
fi
exit "$RC"
