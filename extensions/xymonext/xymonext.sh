#!/bin/sh
#
# xymonext.sh -- Xymon client extension: cost of the client extensions
#
# Wraps another extension of this repository: runs it unchanged and
# measures what the test costs the host - wall clock time, CPU time
# (user+sys of the whole process tree) and the number of bytes the
# test sent to the Xymon server. Reports one "xymonext" status column
# plus a data message for RRD graphing (split-NCV, see server/).
#
# usage: xymonext.sh [-h|--help] EXTENSION [ARGS...]
#
# Program flow:
#   1. parse arguments, load the configuration
#   2. resolve the extension script to run
#   3. instrumentation disabled -> exec the extension and stop here
#   4. build the measurement environment (work dir, $XYMON shim)
#   5. take the clock/CPU baseline, run the extension, take it again
#   6. store the result in the state directory (one file per extension)
#   7. send status (table of all measured extensions) + data message
#   8. exit with the extension's own exit code
#
# The status message always carries the full table, not just the test
# that has run: every extension writes into the same column, so a
# report holding only the current test would make the column flip
# between tests scheduled at different intervals.
#
# Configuration: environment variables and/or $XYMONHOME/etc/xymonext.cfg
# (see the shipped xymonext.cfg; the config file wins over the
# environment).

set -u

BASEDIR=$(cd "$(dirname "$0")" && pwd) || exit 1

# ----------------------------------------------------------------------
# Xymon environment (xymonlaunch or standalone/xymon-run.sh provide
# these; fallbacks allow running the script manually for testing:
# output then goes to stdout)
# ----------------------------------------------------------------------
XYMONHOME="${XYMONHOME:-${XYMONCLIENTHOME:-}}"
XYMONTMP="${XYMONTMP:-${TMPDIR:-/tmp}}"
MACHINE="${MACHINE:-$(uname -n | tr '.' ',')}"

# ----------------------------------------------------------------------
# Usage
# ----------------------------------------------------------------------
usage() {
    printf '%s\n' \
"usage: $0 [-h|--help] EXTENSION [ARGS...]" \
"" \
"Runs EXTENSION (\$XYMONHOME/ext/EXTENSION.sh) and reports its wall" \
"clock time, CPU time and the bytes it sent, in the \"xymonext\"" \
"column. ARGS are passed on to the extension unchanged; the exit" \
"code of the extension is passed back to the caller." \
"" \
"Options:" \
"  -h, --help   show this help and exit" \
"" \
"Settings (environment variable, or same name in the config file" \
"\$XYMONHOME/etc/xymonext.cfg, which wins over the environment):" \
"  XYMONEXT_COLUMN       Xymon column name (default: xymonext)" \
"  XYMONEXT_ENABLE       no = run the extension without measuring" \
"  XYMONEXT_COUNT_BYTES  no = do not count the bytes sent" \
"  XYMONEXT_WALL_WARN    yellow at/above this wall time in seconds" \
"  XYMONEXT_WALL_CRIT    red at/above this wall time in seconds" \
"  XYMONEXT_RC_WARN      no = a non-zero exit code does not turn yellow" \
"  XYMONEXT_MAXAGE       drop table entries older than this (seconds)" \
"  XYMONEXT_STATEDIR     state directory (default: \$XYMONTMP/xymonext.d)" \
"  XYMONEXT_WALLSRC      wall clock source: auto (default), proc, time, date" \
"" \
"Example:" \
"  xymonext.sh smart"
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    '')
        usage >&2
        exit 2
        ;;
    -*)
        echo "$0: unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
esac

EXT=$1
shift

# The name becomes a file name in the state directory and a metric
# name on the server, so keep it to harmless characters.
case "$EXT" in
    *[!A-Za-z0-9_-]*)
        echo "$0: invalid extension name: $EXT" >&2
        exit 2
        ;;
esac

# ----------------------------------------------------------------------
# Defaults -- every value can be set in the environment or in
# xymonext.cfg
# ----------------------------------------------------------------------
XYMONEXT_COLUMN="${XYMONEXT_COLUMN:-xymonext}"
XYMONEXT_ENABLE="${XYMONEXT_ENABLE:-yes}"
XYMONEXT_COUNT_BYTES="${XYMONEXT_COUNT_BYTES:-yes}"
XYMONEXT_WALL_WARN="${XYMONEXT_WALL_WARN:-30}"
XYMONEXT_WALL_CRIT="${XYMONEXT_WALL_CRIT:-60}"
XYMONEXT_RC_WARN="${XYMONEXT_RC_WARN:-yes}"
XYMONEXT_MAXAGE="${XYMONEXT_MAXAGE:-7200}"
XYMONEXT_STATEDIR="${XYMONEXT_STATEDIR:-}"
XYMONEXT_WALLSRC="${XYMONEXT_WALLSRC:-auto}"

CFGFILE="${XYMONEXT_CFG:-${XYMONHOME:+${XYMONHOME}/etc/xymonext.cfg}}"
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi
COLUMN="$XYMONEXT_COLUMN"
STATEDIR="${XYMONEXT_STATEDIR:-$XYMONTMP/xymonext.d}"

# is_off <value> -- true for the usual spellings of "switched off", so
# that a setting can be disabled as no/off/0/false in any case mix.
is_off() {
    case "$1" in
        no|No|NO|off|Off|OFF|0|false|False|FALSE) return 0 ;;
    esac
    return 1
}

# ----------------------------------------------------------------------
# Resolve the extension to run: the installed location first, then the
# directory of this script and the repository layout (so the wrapper
# also works on a checkout, without a Xymon installation).
# ----------------------------------------------------------------------
SCRIPT=""
for cand in "${XYMONHOME:+$XYMONHOME/ext/$EXT.sh}" \
            "$BASEDIR/$EXT.sh" \
            "$BASEDIR/../$EXT/$EXT.sh"; do
    [ -n "$cand" ] || continue
    if [ -x "$cand" ]; then
        SCRIPT=$cand
        break
    fi
done
if [ -z "$SCRIPT" ]; then
    echo "$0: extension not found or not executable: $EXT" >&2
    exit 2
fi

# Switched off: hand over to the extension without any measurement.
# exec replaces this shell, so the only cost left is the fork the
# caller did anyway.
if is_off "$XYMONEXT_ENABLE"; then
    exec "$SCRIPT" "$@"
fi

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# send_report <color> <summary> <status-body-file> <data-file>
# Always sends through the real xymon binary, never through the byte
# counting shim: the cost of the instrumentation is not the cost of
# the measured extension.
send_report() {
    if [ -n "$REAL_XYMON" ] && [ -n "${XYMSRV:-}" ]; then
        "$REAL_XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - xymonext: $2

$(cat "$3")"
        if [ -s "$4" ]; then
            "$REAL_XYMON" "$XYMSRV" "data ${MACHINE}.${COLUMN}
$(cat "$4")"
        fi
    else
        # No Xymon environment: print the messages (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - xymonext: $2"
        echo ""
        cat "$3"
        if [ -s "$4" ]; then
            echo ""
            echo "data ${MACHINE}.${COLUMN}"
            cat "$4"
        fi
    fi
}

# ----------------------------------------------------------------------
# Measurement environment
# ----------------------------------------------------------------------
WORKDIR=$(mktemp -d "${XYMONTMP}/xymonext.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

REAL_XYMON="${XYMON:-}"
BYTEFILE="$WORKDIR/bytes"
SHIM="$BASEDIR/xymonext-send.sh"
COUNTING=""

# Count the traffic by pushing a shim in front of $XYMON. Not in dry
# run/manual mode (empty $XYMON or $XYMSRV): the extensions print
# their report to stdout there and never call $XYMON at all.
if ! is_off "$XYMONEXT_COUNT_BYTES" &&
   [ -n "$REAL_XYMON" ] && [ -n "${XYMSRV:-}" ] && [ -x "$SHIM" ]; then
    COUNTING=yes
    : > "$BYTEFILE"
    XYMONEXT_XYMON="$REAL_XYMON"
    XYMONEXT_BYTES="$BYTEFILE"
    XYMONEXT_WORKDIR="$WORKDIR"
    XYMON="$SHIM"
    export XYMONEXT_XYMON XYMONEXT_BYTES XYMONEXT_WORKDIR XYMON
fi

# Wall clock source, best first:
#   proc - /proc/uptime, 10 ms and no fork at all (Linux, OpenWrt)
#   time - /usr/bin/time -p, 10 ms (FreeBSD base system)
#   date - date +%s, 1 s resolution (last resort)
WALLSRC="proc"
if [ ! -r /proc/uptime ]; then
    if [ -x /usr/bin/time ]; then
        WALLSRC="time"
    else
        WALLSRC="date"
    fi
fi
# An explicit choice wins - but only when that source exists here, so
# a stale setting can never stop the measurement.
case "$XYMONEXT_WALLSRC" in
    proc) [ -r /proc/uptime ] && WALLSRC="proc" ;;
    time) [ -x /usr/bin/time ] && WALLSRC="time" ;;
    date) WALLSRC="date" ;;
esac

# cpu_delta <baseline-file> <end-file>
# Both files hold the output of the "times" builtin, whose second line
# carries the user and system time of the reaped children as
# "0m0.00s 0m0.00s" (the number of decimals differs between shells).
# Prints the delta of user+sys in seconds.
cpu_delta() {
    awk '
        function secs(s,   m, r) {
            m = s; sub(/m.*/, "", m)
            r = s; sub(/^[0-9]*m/, "", r); sub(/s$/, "", r)
            return m * 60 + r
        }
        FNR == 1 { f++ }
        FNR == 2 { c[f] = secs($1) + secs($2) }
        END {
            d = c[2] - c[1]
            if (d < 0) d = 0
            printf "%.2f", d
        }
    ' "$1" "$2"
}

# ----------------------------------------------------------------------
# Run the extension under measurement
# ----------------------------------------------------------------------
# Note on ordering: every command substitution forks, and a reaped
# fork adds its CPU time to this shell's children counters. The
# "times" baseline is therefore taken as the very last step before the
# extension starts, and read back as the very first step after it -
# and "times" itself is written with a redirection, never through
# $(...): a subshell starts with its children counters reset to zero,
# so command substitution would always report 0.
RC=0
WALL=0
CPU=0
case "$WALLSRC" in
    proc)
        read -r T0 _ < /proc/uptime
        times > "$WORKDIR/c0"
        "$SCRIPT" "$@" || RC=$?
        times > "$WORKDIR/c1"
        read -r T1 _ < /proc/uptime
        WALL=$(awk -v a="$T0" -v b="$T1" \
            'BEGIN { d = b - a; if (d < 0) d = 0; printf "%.2f", d }')
        CPU=$(cpu_delta "$WORKDIR/c0" "$WORKDIR/c1")
        ;;
    time)
        # /usr/bin/time writes its report to stderr, so the extension's
        # own stderr is routed around it through fd 3.
        exec 3>&2
        # shellcheck disable=SC2016  # $0/$@ must be expanded by the
        # inner shell, not here: they are the extension and its
        # arguments, handed over as parameters below.
        /usr/bin/time -p /bin/sh -c 'exec "$0" "$@" 2>&3' \
            "$SCRIPT" "$@" 2>"$WORKDIR/time" || RC=$?
        exec 3>&-
        WALL=$(awk '$1 == "real" { printf "%.2f", $2 }' "$WORKDIR/time")
        CPU=$(awk '$1 == "user" { u = $2 } $1 == "sys" { s = $2 }
                   END { printf "%.2f", u + s }' "$WORKDIR/time")
        ;;
    date)
        T0=$(date +%s)
        times > "$WORKDIR/c0"
        "$SCRIPT" "$@" || RC=$?
        times > "$WORKDIR/c1"
        T1=$(date +%s)
        WALL=$(awk -v a="$T0" -v b="$T1" \
            'BEGIN { d = b - a; if (d < 0) d = 0; printf "%.2f", d }')
        CPU=$(cpu_delta "$WORKDIR/c0" "$WORKDIR/c1")
        ;;
esac
[ -n "$WALL" ] || WALL=0
[ -n "$CPU" ] || CPU=0

# --- traffic ----------------------------------------------------------
MSGS=0
BYTES=0
if [ -n "$COUNTING" ] && [ -s "$BYTEFILE" ]; then
    COUNTS=$(awk '{ n++; b += $1 } END { printf "%d %d", n, b }' "$BYTEFILE")
    MSGS=${COUNTS%% *}
    BYTES=${COUNTS##* }
fi

# ----------------------------------------------------------------------
# Record the result and build the report
# ----------------------------------------------------------------------
NOW=$(date +%s)

# Without the state directory there is nothing to report from - but
# the extension has already run, so its exit code is what the caller
# must see, not a failure of the instrumentation.
if ! mkdir -p "$STATEDIR"; then
    echo "$0: cannot create the state directory: $STATEDIR" >&2
    exit "$RC"
fi
printf '%s %s %s %s %s %s\n' "$NOW" "$RC" "$WALL" "$CPU" "$MSGS" "$BYTES" \
    > "$STATEDIR/$EXT"

case "$WALLSRC" in
    proc) SRCTXT="/proc/uptime (10 ms resolution)" ;;
    time) SRCTXT="/usr/bin/time -p (10 ms resolution)" ;;
    date) SRCTXT="date +%s (1 s resolution only)" ;;
esac
if [ -n "$COUNTING" ]; then
    BYTETXT="counted at the Xymon transport"
else
    BYTETXT="not counted (disabled, or no server configured)"
fi
if is_off "$XYMONEXT_RC_WARN"; then
    RCWARN=no
else
    RCWARN=yes
fi

# One awk pass over the state directory: it prints the worst color on
# stdout and writes the table to the body file. The whole human
# readable part is fenced off with the NCV markers - the numbers reach
# the server through the data message below, and without the fence
# the server's NCV parser would turn table text into RRD datasets of
# its own.
: > "$WORKDIR/body"
COLOR=$(awk -v now="$NOW" -v maxage="$XYMONEXT_MAXAGE" \
            -v warn="$XYMONEXT_WALL_WARN" -v crit="$XYMONEXT_WALL_CRIT" \
            -v rcwarn="$RCWARN" -v body="$WORKDIR/body" \
            -v srctxt="$SRCTXT" -v bytetxt="$BYTETXT" '
    function rank(c) { return (c == "red") ? 2 : ((c == "yellow") ? 1 : 0) }
    function age_str(a) {
        if (a < 120) return sprintf("%ds", a)
        if (a < 7200) return sprintf("%dm", int(a / 60))
        return sprintf("%dh", int(a / 3600))
    }
    BEGIN {
        worst = "green"
        printf "<!-- ncv_skipstart -->\n" > body
    }
    # NF == 6 skips a state file that another extension is writing
    # right now: the entry is simply missing from this one report.
    FNR == 1 && NF == 6 {
        name = FILENAME
        sub(/.*\//, "", name)
        age = now - $1
        if (maxage + 0 > 0 && age > maxage + 0) next
        if (age < 0) age = 0
        rc = $2; wall = $3 + 0; cpu = $4 + 0; msgs = $5 + 0; bytes = $6 + 0

        color = "green"
        if (crit + 0 > 0 && wall >= crit + 0) color = "red"
        else if (warn + 0 > 0 && wall >= warn + 0) color = "yellow"
        if (rc + 0 != 0 && rcwarn == "yes" && color == "green") color = "yellow"
        if (rank(color) > rank(worst)) worst = color

        n++
        totcpu += cpu
        totbytes += bytes
        note = (rc + 0 != 0) ? sprintf("  exit %d", rc) : ""
        printf "&%s %-10s wall %6.2fs  cpu %6.2fs  msgs %3d  bytes %7d  (%s ago)%s\n", \
            color, name, wall, cpu, msgs, bytes, age_str(age), note > body
    }
    END {
        if (n == 0)
            printf "No measurements recorded yet.\n" > body
        else
            printf "\n%d extension(s) measured; totals of the runs above: cpu %.2fs, %.1f kB sent.\n", \
                n, totcpu, totbytes / 1024 > body
        printf "Wall clock source on this host is %s.\n", srctxt > body
        printf "Bytes sent to the Xymon server are %s.\n", bytetxt > body
        printf "Thresholds per run (wall clock): yellow at/above %ss, red at/above %ss.\n", \
            warn, crit > body
        printf "<!-- ncv_skipend -->\n" > body
        close(body)
        printf "%s", worst
    }
' "$STATEDIR"/*)
# The glob always matches: the run above has just written its own
# state file. An unreadable leftover file is reported by awk on stderr
# (it lands in the extension's log) instead of being hidden.
[ -n "$COLOR" ] || COLOR=green

# --- data message: only the extension that has just run, so each RRD
# --- is updated at the interval of its own test
{
    printf 'wall_%s : %s\n' "$EXT" "$WALL"
    printf 'cpu_%s : %s\n' "$EXT" "$CPU"
    if [ -n "$COUNTING" ]; then
        printf 'bytes_%s : %s\n' "$EXT" "$BYTES"
    fi
} > "$WORKDIR/data"

SUMMARY="$EXT took ${WALL}s wall, ${CPU}s cpu"
if [ -n "$COUNTING" ]; then
    SUMMARY="$SUMMARY, sent $BYTES bytes"
fi
if [ "$RC" -ne 0 ]; then
    SUMMARY="$SUMMARY, exit $RC"
fi

send_report "$COLOR" "$SUMMARY" "$WORKDIR/body" "$WORKDIR/data"

# The caller (xymonlaunch, cron, the standalone runner) must still see
# how the measured extension itself ended.
exit "$RC"
