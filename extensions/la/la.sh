#!/bin/sh
#
# la.sh -- Xymon client extension: load average
#
# Reads the 1/5/15 minute load averages (Linux: /proc/loadavg,
# FreeBSD: sysctl vm.loadavg) and reports one "la" status column.
# The thresholds are relative to the number of CPU cores and are
# evaluated on the 5-minute value; all three values are shown and
# fed to the server as "NAME : VALUE" lines (hidden in an HTML
# comment) for NCV graphing - see README.md for the server-side
# setup.
#
# Written for clientless hosts driven by the standalone runner
# (OpenWrt/TurrisOS): a full Xymon client already delivers the same
# information as its "cpu" column, so the shipped launch snippet is
# disabled by default.
#
# Configuration: environment variables and/or $XYMONHOME/etc/la.cfg
# (see the shipped la.cfg; the config file wins over the environment).

set -u

# ----------------------------------------------------------------------
# Xymon environment (xymonlaunch or standalone/xymon-run.sh provide
# these; fallbacks allow running the script manually for testing:
# output then goes to stdout)
# ----------------------------------------------------------------------
XYMONHOME="${XYMONHOME:-${XYMONCLIENTHOME:-}}"
XYMONTMP="${XYMONTMP:-${TMPDIR:-/tmp}}"
MACHINE="${MACHINE:-$(uname -n | tr '.' ',')}"

# ----------------------------------------------------------------------
# Defaults -- every value can be set in the environment or in la.cfg
# ----------------------------------------------------------------------
LA_COLUMN="${LA_COLUMN:-la}"    # Xymon column name
LA_WARN="${LA_WARN:-1.5}"       # yellow at/above, 5-min load PER CORE
LA_CRIT="${LA_CRIT:-3.0}"       # red at/above, 5-min load PER CORE
LA_NCPU="${LA_NCPU:-}"          # CPU count override; empty = detect
LA_LOADAVG="${LA_LOADAVG:-/proc/loadavg}"

CFGFILE="${LA_CFG:-${XYMONHOME:+${XYMONHOME}/etc/la.cfg}}"
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi
COLUMN="$LA_COLUMN"

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# ge <a> <b> -> true if a >= b (values may be fractional; BusyBox sh
# has no float arithmetic, so compare in awk)
ge() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

# color_hi <value> <warn> <crit>  (higher is worse)
color_hi() {
    if ge "$1" "$3"; then echo red
    elif ge "$1" "$2"; then echo yellow
    else echo green
    fi
}

# send_report <color> <body-file>
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - load average is $1

$(cat "$2")"
    else
        # No Xymon environment: print the message (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - load average is $1"
        echo ""
        cat "$2"
    fi
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

WORKDIR=$(mktemp -d "${XYMONTMP}/la.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

clear_report() {
    printf '%s\n' "$1" > "$WORKDIR/status"
    send_report clear "$WORKDIR/status"
    exit 0
}

# --- read the load averages ----------------------------------------------
LA1="" LA5="" LA15=""
if [ -r "$LA_LOADAVG" ]; then
    read -r LA1 LA5 LA15 _ < "$LA_LOADAVG" || true
elif command -v sysctl >/dev/null 2>&1; then
    # FreeBSD: vm.loadavg prints "{ 0.51 0.54 0.57 }"
    # shellcheck disable=SC2046  # word splitting is intended
    set -- $(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')
    LA1=${1:-} LA5=${2:-} LA15=${3:-}
fi
case "$LA5" in
    ''|*[!0-9.]*)
        clear_report "Cannot read the load average on this host (no readable ${LA_LOADAVG} and no sysctl vm.loadavg)."
        ;;
esac

# --- CPU count (for the per-core thresholds) ------------------------------
NCPU="$LA_NCPU"
if [ -z "$NCPU" ]; then
    case "$(uname -s)" in
        Linux)
            if command -v nproc >/dev/null 2>&1; then
                NCPU=$(nproc 2>/dev/null)
            fi
            [ -n "$NCPU" ] || NCPU=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
            ;;
        FreeBSD)
            NCPU=$(sysctl -n hw.ncpu 2>/dev/null)
            ;;
    esac
fi
case "$NCPU" in
    ''|0|*[!0-9]*) NCPU=1 ;;
esac

PERCORE=$(awk -v l="$LA5" -v n="$NCPU" 'BEGIN { printf "%.2f", l / n }')
COLOR=$(color_hi "$PERCORE" "$LA_WARN" "$LA_CRIT")

{
    printf '&%s load average (1/5/15 min)  %s  %s  %s\n' \
        "$COLOR" "$LA1" "$LA5" "$LA15"
    printf '\n%s CPU core(s); the 5-min load per core is %s\n' "$NCPU" "$PERCORE"
    printf 'Thresholds (5-min load per core): yellow >= %s, red >= %s\n' \
        "$LA_WARN" "$LA_CRIT"
    printf '\n<!--\n'
    printf 'la1 : %s\nla5 : %s\nla15 : %s\n' "$LA1" "$LA5" "$LA15"
    printf '%s\n' '-->'
} > "$WORKDIR/final"

send_report "$COLOR" "$WORKDIR/final"
exit 0
