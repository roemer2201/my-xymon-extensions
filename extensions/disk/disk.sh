#!/bin/sh
#
# disk.sh -- Xymon client extension: filesystem usage via df
#
# Runs "df -P -k" (POSIX output format - works with GNU coreutils,
# BusyBox and FreeBSD df alike), hides uninteresting mount points
# (/dev and /rom by default) and reports the used capacity of every
# remaining filesystem in one status column - "disk" by default, the
# standard Xymon column name. The status body ends with a df-style
# table that the Xymon server's built-in "disk" RRD handler parses
# as-is, so the stock per-filesystem disk graphs work without any
# server-side configuration.
#
# Written for clientless hosts driven by the standalone runner
# (OpenWrt/TurrisOS): a full Xymon client already builds the "disk"
# column from its own df report, so the shipped launch snippet is
# disabled by default - never enable both on one host.
#
# Configuration: environment variables and/or $XYMONHOME/etc/disk.cfg
# (see the shipped disk.cfg; the config file wins over the
# environment).

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
# Defaults -- every value can be set in the environment or in disk.cfg
# ----------------------------------------------------------------------
DISK_COLUMN="${DISK_COLUMN:-disk}"  # Xymon column name (the standard one)
DISK_WARN="${DISK_WARN:-90}"        # yellow at/above, percent used
DISK_CRIT="${DISK_CRIT:-95}"        # red at/above, percent used
DISK_THRESHOLDS="${DISK_THRESHOLDS:-}"      # per-mount "PATTERN:WARN:CRIT"
DISK_EXCLUDE="${DISK_EXCLUDE:-/dev /rom}"   # globs, mount point or device
DISK_DF="${DISK_DF:-df}"            # invoked as "$DISK_DF -P -k"

CFGFILE="${DISK_CFG:-${XYMONHOME:+${XYMONHOME}/etc/disk.cfg}}"
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi
COLUMN="$DISK_COLUMN"

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# ge <a> <b> -> true if a >= b (thresholds may be fractional; BusyBox
# sh has no float arithmetic, so compare in awk)
ge() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

# kb2h <kB> -> human-readable size (512K, 15.8M, 4.3G, ...)
kb2h() {
    awk -v k="$1" 'BEGIN {
        if      (k >= 1073741824) printf "%.1fT", k / 1073741824
        else if (k >= 1048576)    printf "%.1fG", k / 1048576
        else if (k >= 1024)       printf "%.1fM", k / 1024
        else                      printf "%dK",  k
    }'
}

# join_c <space-separated list> -> the words joined with commas.
# Used for the footer notes: it keeps a pattern list on one line (any
# newline or tab in the value collapses into a comma) and makes it a
# single whitespace-separated field, which keeps such a note short and
# out of the shape of a df line. See "Server-side parser" below for
# why that alone is not enough.
join_c() {
    j_out=""
    set -f
    # shellcheck disable=SC2086  # word splitting is intended
    for j_w in $1; do
        j_out="${j_out}${j_out:+,}${j_w}"
    done
    set +f
    printf '%s' "$j_out"
}

# send_report <color> <body-file>
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - disk is $1

$(cat "$2")"
    else
        # No Xymon environment: print the message (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - disk is $1"
        echo ""
        cat "$2"
    fi
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

WORKDIR=$(mktemp -d "${XYMONTMP}/disk.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

# clear_report <text> - report "clear" and stop. The text quotes
# $DISK_DF, which may well be an absolute path, so it is prefixed with
# "&clear" like every other line that can contain a "/" (see the
# parser notes further down).
clear_report() {
    printf '&clear %s\n' "$1" > "$WORKDIR/status"
    send_report clear "$WORKDIR/status"
    exit 0
}

if ! command -v "$DISK_DF" >/dev/null 2>&1; then
    clear_report "df not found on this host (looked for \"${DISK_DF}\")."
fi

"$DISK_DF" -P -k > "$WORKDIR/df.out" 2>/dev/null
DFRC=$?

COLOR=green
COUNT=0
HIDDEN=0
: > "$WORKDIR/details"
: > "$WORKDIR/table"

while read -r d_fs d_total d_used d_avail d_pct d_mnt; do
    # Keep only real df data lines: absolute mount point, numeric "NN%"
    # in the capacity column (skips the header and pseudo entries).
    case "$d_mnt" in /*) ;; *) continue ;; esac
    case "$d_pct" in *%) ;; *) continue ;; esac
    d_pct=${d_pct%\%}
    case "$d_pct" in ''|*[!0-9]*) continue ;; esac

    # Exclusion globs match the mount point and the device column.
    # set -f: patterns like tmp* must not match files in $PWD.
    d_skip=""
    set -f
    # shellcheck disable=SC2086  # word splitting is intended
    for d_pat in $DISK_EXCLUDE; do
        # shellcheck disable=SC2254  # unquoted on purpose: glob match
        case "$d_mnt" in $d_pat) d_skip=yes; break ;; esac
        # shellcheck disable=SC2254  # unquoted on purpose: glob match
        case "$d_fs" in $d_pat) d_skip=yes; break ;; esac
    done
    set +f
    if [ -n "$d_skip" ]; then
        HIDDEN=$((HIDDEN + 1))
        continue
    fi

    # Thresholds: the first DISK_THRESHOLDS entry whose pattern matches
    # the mount point wins; malformed entries are ignored.
    d_warn="$DISK_WARN"
    d_crit="$DISK_CRIT"
    set -f
    # shellcheck disable=SC2086  # word splitting is intended
    for d_spec in $DISK_THRESHOLDS; do
        d_c=${d_spec##*:}
        d_rest=${d_spec%:*}
        d_w=${d_rest##*:}
        d_p=${d_rest%:*}
        case "$d_w" in ''|*[!0-9.]*) continue ;; esac
        case "$d_c" in ''|*[!0-9.]*) continue ;; esac
        # shellcheck disable=SC2254  # unquoted on purpose: glob match
        case "$d_mnt" in
            $d_p) d_warn=$d_w; d_crit=$d_c; break ;;
        esac
    done
    set +f

    COUNT=$((COUNT + 1))
    d_note=""
    if ge "$d_pct" "$d_crit"; then
        d_color=red
        d_note=" - reached the red threshold (${d_crit}%)"
    elif ge "$d_pct" "$d_warn"; then
        d_color=yellow
        d_note=" - reached the yellow threshold (${d_warn}%)"
    else
        d_color=green
    fi
    case "$d_color" in
        red) COLOR=red ;;
        yellow) [ "$COLOR" = red ] || COLOR=yellow ;;
    esac

    printf '&%s %s %s%% used (%s of %s, %s free)%s\n' \
        "$d_color" "$d_mnt" "$d_pct" \
        "$(kb2h "$d_used")" "$(kb2h "$d_total")" "$(kb2h "$d_avail")" \
        "$d_note" >> "$WORKDIR/details"
    printf '%-20s %11s %9s %9s %5s %s\n' \
        "$d_fs" "$d_total" "$d_used" "$d_avail" "${d_pct}%" "$d_mnt" \
        >> "$WORKDIR/table"
done < "$WORKDIR/df.out"

if [ "$COUNT" -eq 0 ]; then
    clear_report "\"${DISK_DF} -P -k\" produced no usable filesystem lines (exit code ${DFRC})."
fi

# ----------------------------------------------------------------------
# Server-side parser (xymond_rrd, do_disk.c) - read before touching
# the wording of anything below!
#
# The handler walks the status message line by line, skipping only
#   1. the very first line (the "status host.disk COLOR date ..." one),
#   2. every line without a "/",
#   3. every line starting with "&",
#   4. every line containing " red " or " yellow ".
# EVERY other line is treated as a df line: the 6th whitespace-
# separated field becomes the filesystem name ("/" -> ",", a bare "/"
# -> ",root") and an RRD "disk<name>.rrd" is created and updated. A
# line with fewer than six fields yields an EMPTY name, i.e. a bogus
# "disk.rrd" - so keeping notes short does not help. The invariant is
# therefore:
#
#   every line except the df table rows must either contain no "/"
#   at all, or start with "&".
#
# Which column holds the mount point depends on a format guess made
# from the whole message: the word "Filesystem" anywhere in it selects
# the Windows format, where the RRD is named after the DEVICE column
# instead. The handler only falls back to the Unix format once it sees
# a line whose device column contains a "/" - so on a host whose first
# df row is a "tmpfs" or another slash-less device, the mount point is
# ignored and RRDs like "disk,tmpfs.rrd" appear. The table header here
# therefore says "Device", not "Filesystem": with no such word in the
# message the Unix format is the default and every row is named after
# its mount point. For the same reason the message must not contain
# "DASD", "NetAPP", "NetWare Volumes", "Summary", " xfs ", " efs " or
# " cxfs " - each of them selects yet another format.
#
# Finally, avoid ": <number>" anywhere, or the NCV parser picks up a
# bogus dataset as well.
# ----------------------------------------------------------------------
{
    cat "$WORKDIR/details"
    # df-style table - the Xymon server's disk RRD handler parses this
    # for the stock per-filesystem graphs.
    printf '\n'
    printf '%-20s %11s %9s %9s %5s %s\n' \
        Device 1024-blocks Used Available 'Use%' 'Mounted on'
    cat "$WORKDIR/table"
    # Footer notes. Anything echoing a configured pattern contains a
    # "/" and must be prefixed with "&clear" to stay out of the RRD
    # parser (see above); Xymon renders that as an informational icon.
    printf '\nThresholds (percent used): yellow >= %s, red >= %s\n' \
        "$DISK_WARN" "$DISK_CRIT"
    if [ -n "$DISK_THRESHOLDS" ]; then
        printf '&clear Per-mount thresholds apply (DISK_THRESHOLDS=%s)\n' \
            "$(join_c "$DISK_THRESHOLDS")"
    fi
    if [ "$HIDDEN" -gt 0 ]; then
        printf '&clear %s filesystem(s) hidden (DISK_EXCLUDE=%s)\n' \
            "$HIDDEN" "$(join_c "$DISK_EXCLUDE")"
    fi
} > "$WORKDIR/final"

send_report "$COLOR" "$WORKDIR/final"
exit 0
