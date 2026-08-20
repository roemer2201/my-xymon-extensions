#!/bin/sh
#
# memory.sh -- Xymon client extension: memory utilization
#
# Reads MemTotal and MemAvailable from /proc/meminfo, computes the
# used share in percent ((MemTotal - MemAvailable) / MemTotal * 100)
# and reports one status column, "mem" by default. The status text
# carries a "used : <percent>" line (hidden in an HTML comment) for
# NCV graphing - see README.md for the server-side setup.
#
# Written for clientless hosts driven by the standalone runner
# (OpenWrt/TurrisOS): a full Xymon client already delivers a "memory"
# column of its own, so the default column name here is "mem" - this
# avoids a collision on any server that also has full clients, and
# the shipped launch snippet is disabled by default anyway, since
# running both would be redundant.
#
# Needs a Linux /proc/meminfo; other platforms report "clear".
#
# Configuration: environment variables and/or $XYMONHOME/etc/memory.cfg
# (see the shipped memory.cfg; the config file wins over the
# environment).

set -u

# Every number in a Xymon message must use a decimal point. awk formats
# floating point numbers according to LC_NUMERIC, so under a locale
# like de_DE the metrics would come out as "14,9" - which the server's
# NCV parser silently drops.
LC_ALL=C
export LC_ALL

# ----------------------------------------------------------------------
# Xymon environment (xymonlaunch or standalone/xymon-run.sh provide
# these; fallbacks allow running the script manually for testing:
# output then goes to stdout)
# ----------------------------------------------------------------------
XYMONHOME="${XYMONHOME:-${XYMONCLIENTHOME:-}}"
XYMONTMP="${XYMONTMP:-${TMPDIR:-/tmp}}"
MACHINE="${MACHINE:-$(uname -n | tr '.' ',')}"

# ----------------------------------------------------------------------
# Defaults -- every value can be set in the environment or in memory.cfg
# ----------------------------------------------------------------------
MEM_COLUMN="${MEM_COLUMN:-mem}"      # Xymon column name
MEM_WARN="${MEM_WARN:-80}"          # yellow at/above, percent used
MEM_CRIT="${MEM_CRIT:-90}"          # red at/above, percent used
MEM_MEMINFO="${MEM_MEMINFO:-/proc/meminfo}"

CFGFILE="${MEM_CFG:-${XYMONHOME:+${XYMONHOME}/etc/memory.cfg}}"
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi
COLUMN="$MEM_COLUMN"

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

# kb2mb <kB> -> whole megabytes
kb2mb() {
    awk -v k="$1" 'BEGIN { printf "%.0f", k / 1024 }'
}

# send_report <color> <body-file>
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - memory is $1

$(cat "$2")"
    else
        # No Xymon environment: print the message (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - memory is $1"
        echo ""
        cat "$2"
    fi
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

WORKDIR=$(mktemp -d "${XYMONTMP}/memory.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

clear_report() {
    printf '%s\n' "$1" > "$WORKDIR/status"
    send_report clear "$WORKDIR/status"
    exit 0
}

if [ ! -r "$MEM_MEMINFO" ]; then
    clear_report "No readable ${MEM_MEMINFO} on this host - this test needs a Linux /proc filesystem."
fi

# MemAvailable exists since Linux 3.14; on older kernels fall back to
# the classic MemFree + Buffers + Cached approximation.
# shellcheck disable=SC2046  # word splitting is intended
set -- $(awk '
    /^MemTotal:/     { t = $2 }
    /^MemAvailable:/ { a = $2; have = 1 }
    /^MemFree:/      { f = $2 }
    /^Buffers:/      { b = $2 }
    /^Cached:/       { c = $2 }
    END {
        if (!have) a = f + b + c
        print t + 0, a + 0, have + 0
    }' "$MEM_MEMINFO")
TOTAL_KB=${1:-0}
AVAIL_KB=${2:-0}
HAVE_AVAIL=${3:-0}

if [ "$TOTAL_KB" -eq 0 ] 2>/dev/null; then
    clear_report "Cannot parse MemTotal from ${MEM_MEMINFO}."
fi

USEDPCT=$(awk -v t="$TOTAL_KB" -v a="$AVAIL_KB" \
    'BEGIN { printf "%.1f", (t - a) * 100 / t }')
COLOR=$(color_hi "$USEDPCT" "$MEM_WARN" "$MEM_CRIT")

TOTAL_MB=$(kb2mb "$TOTAL_KB")
AVAIL_MB=$(kb2mb "$AVAIL_KB")
USED_MB=$(kb2mb "$((TOTAL_KB - AVAIL_KB))")

{
    printf '&%s memory used %s%% (%s MB of %s MB, %s MB available)\n' \
        "$COLOR" "$USEDPCT" "$USED_MB" "$TOTAL_MB" "$AVAIL_MB"
    if [ "$HAVE_AVAIL" -eq 0 ]; then
        printf '\nThis kernel provides no MemAvailable - the available memory is estimated as MemFree + Buffers + Cached.\n'
    fi
    printf '\nThresholds (percent used): yellow >= %s, red >= %s\n' \
        "$MEM_WARN" "$MEM_CRIT"
    printf '\n<!--\n'
    printf 'used : %s\n' "$USEDPCT"
    printf '%s\n' '-->'
} > "$WORKDIR/final"

send_report "$COLOR" "$WORKDIR/final"
exit 0
