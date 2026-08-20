#!/bin/sh
#
# if_link.sh -- Xymon client extension: network interface link changes
#
# Counts the link state transitions of a host's network interfaces and
# reports them in one "if_link" column. A short cable outage - link
# down followed by link up - counts as two changes.
#
# The numbers come from the kernel's own counters in
# /sys/class/net/<if>/carrier_changes (fallback: the sum of
# carrier_up_count and carrier_down_count). Because the kernel counts
# every transition itself, even flaps that start and end between two
# polls are seen - comparing the current link state between polls
# would silently miss them.
#
# Per interface the number of changes since the previous poll is
# delivered as "changes_<if>" in a separate "data" message
# (split-NCV on the Xymon server, see server/README.md). The
# cumulative counter and the current link state are shown in the
# status text only. Metric names are keyed by the sanitized interface
# name, e.g. changes_lan4 or changes_phy0_ap0.
#
# The column is green regardless of how much an interface flaps: what
# counts as "too much" depends on the port. Set IF_LINK_YELLOW /
# IF_LINK_RED (globally) or IF_LINK_THRESHOLDS (per interface) to make
# it turn yellow/red.
#
# Interfaces are discovered dynamically: by default every physical
# Ethernet port - including DSA switch ports such as lan0..lan4 on a
# Turris Omnia - but no wireless, bridge, veth, tunnel or loopback
# device. IF_LINK_INTERFACES / IF_LINK_EXCLUDE (glob patterns) and
# IF_LINK_WIRELESS / IF_LINK_VIRTUAL adjust that.
#
# Linux only: no other platform supported by this repository keeps a
# kernel-side link change counter, and a poll-based substitute would
# quietly miss short flaps. FreeBSD reports "clear".
#
# Configuration: environment variables and/or
# $XYMONHOME/etc/if_link.cfg (see the shipped if_link.cfg; the config
# file wins over the environment).

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
# Defaults -- every value can be set in the environment or in
# if_link.cfg
# ----------------------------------------------------------------------
IF_LINK_COLUMN="${IF_LINK_COLUMN:-if_link}"   # Xymon column name
IF_LINK_SYSNET="${IF_LINK_SYSNET:-/sys/class/net}"
IF_LINK_INTERFACES="${IF_LINK_INTERFACES:-}"  # explicit list (globs)
IF_LINK_EXCLUDE="${IF_LINK_EXCLUDE:-}"        # excluded names (globs)
IF_LINK_WIRELESS="${IF_LINK_WIRELESS:-no}"    # include wlan netdevs
IF_LINK_VIRTUAL="${IF_LINK_VIRTUAL:-no}"      # include virtual netdevs
IF_LINK_YELLOW="${IF_LINK_YELLOW:-}"          # global yellow threshold
IF_LINK_RED="${IF_LINK_RED:-}"                # global red threshold
IF_LINK_THRESHOLDS="${IF_LINK_THRESHOLDS:-}"  # per-interface overrides

CFGFILE="${IF_LINK_CFG:-${XYMONHOME:+${XYMONHOME}/etc/if_link.cfg}}"
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi
COLUMN="$IF_LINK_COLUMN"

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# is_uint <value> -> true if the value is a non-empty decimal integer
is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# is_yes <value> -> true for the usual affirmative config spellings
is_yes() {
    case "${1:-}" in
        1|y|Y|yes|Yes|YES|true|True|TRUE|on|On|ON) return 0 ;;
    esac
    return 1
}

# sanitize <text> -> lowercase, [a-z0-9_] only, squeezed and trimmed
sanitize() {
    s_out=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | tr -s '_')
    s_out=${s_out#_}
    printf '%s' "${s_out%_}"
}

# attr <dir> <name> -> first line of the sysfs attribute, empty when
# it does not exist or cannot be read. Reading "carrier" fails with
# EINVAL while the interface is administratively down - an empty
# result there means exactly that.
attr() {
    a_val=""
    if [ -f "$1/$2" ] && [ -r "$1/$2" ]; then
        read -r a_val < "$1/$2" 2>/dev/null || a_val=""
    fi
    printf '%s' "$a_val"
}

# match_any <name> <pattern-list> -> true if one space-separated glob
# pattern of the list matches the name
match_any() {
    ma_name=$1
    # shellcheck disable=SC2086  # the list is a pattern list on purpose
    for ma_p in $2; do
        # shellcheck disable=SC2254  # glob matching is the point here
        case "$ma_name" in
            $ma_p) return 0 ;;
        esac
    done
    return 1
}

# thresholds_for <interface> -- sets TH_Y and TH_R to the thresholds
# in effect for that interface. IF_LINK_THRESHOLDS holds entries of
# the form "<glob>:<yellow>:<red>"; the first matching entry wins and
# replaces the global IF_LINK_YELLOW/IF_LINK_RED. An empty or
# non-numeric field means "no threshold".
thresholds_for() {
    TH_Y="$IF_LINK_YELLOW"
    TH_R="$IF_LINK_RED"
    # shellcheck disable=SC2086  # entries are space-separated
    for tf_e in $IF_LINK_THRESHOLDS; do
        tf_rest=${tf_e#*:}
        [ "$tf_rest" != "$tf_e" ] || continue      # no colon: malformed
        tf_pat=${tf_e%%:*}
        tf_y=${tf_rest%%:*}
        tf_r=${tf_rest#*:}
        [ "$tf_r" != "$tf_rest" ] || tf_r=""       # only two fields
        # shellcheck disable=SC2254  # glob matching is the point here
        case "$1" in
            $tf_pat)
                TH_Y=$tf_y
                TH_R=$tf_r
                return 0
                ;;
        esac
    done
    return 0
}

# state_get <TYPE> <key> -> prints fields 3..NF of the matching state
# line; fails when the state file or the line is missing.
state_get() {
    [ -r "$STATEFILE" ] || return 1
    sg_out=$(awk -v t="$1" -v k="$2" '
        $1 == t && $2 == k {
            for (i = 3; i <= NF; i++)
                printf "%s%s", $i, (i < NF ? " " : "")
            exit
        }' "$STATEFILE")
    [ -n "$sg_out" ] || return 1
    printf '%s\n' "$sg_out"
}

# send_report <color> <status-body-file> [data-body-file]
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - if_link: ${SUMMARY:-$1}

$(cat "$2")"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            "$XYMON" "$XYMSRV" "data ${MACHINE}.${COLUMN}
$(cat "$3")"
        fi
    else
        # No Xymon environment: print the messages (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - if_link: ${SUMMARY:-$1}"
        echo ""
        cat "$2"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            echo ""
            echo "data ${MACHINE}.${COLUMN}"
            cat "$3"
        fi
    fi
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

WORKDIR=$(mktemp -d "${XYMONTMP}/if_link.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

STATUS="$WORKDIR/status"
DATA="$WORKDIR/data"
NEWSTATE="$WORKDIR/newstate"
: > "$DATA"
: > "$NEWSTATE"

# Everything written to $STATUS is for humans only - the metrics
# travel in the separate "data" message. xymond_rrd's NCV parser
# treats both ":" and "=" as a name/value separator, so without these
# markers every "link=up" or "changes=+2" would become an RRD dataset
# of its own. The markers are HTML comments and stay invisible on the
# Xymon web page.
printf '<!-- ncv_skipstart -->\n' > "$STATUS"

SUMMARY=""

clear_report() {
    SUMMARY="not applicable"
    {
        printf '<!-- ncv_skipstart -->\n'
        printf '%s\n' "$1"
        printf '<!-- ncv_skipend -->\n'
    } > "$WORKDIR/clear"
    send_report clear "$WORKDIR/clear"
    exit 0
}

# ncv <name> <numeric-value> -- append an RRD line to the data message
ncv() {
    case "${2:-}" in
        ''|*[!0-9.-]*) return 0 ;;
        *[0-9]*) ;;
        *) return 0 ;;              # "-" or "." alone is not a number
    esac
    printf '%s : %s\n' "$1" "$2" >> "$DATA"
}

# --- the kernel counters must exist ---------------------------------
if [ ! -d "$IF_LINK_SYSNET" ]; then
    case "$(uname -s)" in
        Linux) clear_report "$IF_LINK_SYSNET not found - this kernel exposes no network interfaces in sysfs" ;;
        *)     clear_report "link change counters ($IF_LINK_SYSNET/<if>/carrier_changes) exist on Linux only - test not applicable here" ;;
    esac
fi

# --- discover the interfaces ----------------------------------------
# Auto-detection keeps the physical Ethernet ports: ARPHRD_ETHER
# (type 1) devices that have a "device" link in sysfs. That covers
# plain NICs as well as DSA switch ports (lan0..lan4), and leaves out
# bridges, veth pairs (docker), tunnels and the loopback - all of
# which carry a carrier_changes counter too, but no cable.
for d in "$IF_LINK_SYSNET"/*; do
    [ -d "$d" ] || continue
    ifn=${d##*/}
    [ -n "$ifn" ] || continue

    if [ -n "$IF_LINK_INTERFACES" ]; then
        # An explicit list overrides the whole classification below -
        # including the counter check, so that a named interface
        # without a counter is reported instead of silently dropped.
        match_any "$ifn" "$IF_LINK_INTERFACES" || continue
    else
        # A link change counter is the whole point of this test
        if [ ! -r "$d/carrier_changes" ] \
            && { [ ! -r "$d/carrier_up_count" ] || [ ! -r "$d/carrier_down_count" ]; }; then
            continue
        fi
        [ "$(attr "$d" type)" = "1" ] || continue
        if [ -e "$d/phy80211" ] || [ -d "$d/wireless" ]; then
            is_yes "$IF_LINK_WIRELESS" || continue
        elif [ ! -e "$d/device" ]; then
            is_yes "$IF_LINK_VIRTUAL" || continue
        fi
    fi

    if [ -n "$IF_LINK_EXCLUDE" ] && match_any "$ifn" "$IF_LINK_EXCLUDE"; then
        continue
    fi

    printf '%s\n' "$ifn" >> "$WORKDIR/ifs"
done

if [ ! -s "$WORKDIR/ifs" ]; then
    if [ -n "$IF_LINK_INTERFACES" ]; then
        clear_report "no interface matches IF_LINK_INTERFACES=\"${IF_LINK_INTERFACES}\" - nothing to monitor on this host"
    fi
    clear_report "no physical Ethernet interface found in $IF_LINK_SYSNET - set IF_LINK_INTERFACES, IF_LINK_WIRELESS or IF_LINK_VIRTUAL to monitor other kinds of interfaces"
fi

STATEFILE="${XYMONTMP}/if_link.${MACHINE}.state"
NOW=$(date +%s)

WORST=green
NIF=0
NFLAP=0
TOTALDELTA=0
HAVEDELTA=no
LAST_TS=""

# The loop reads the interface list from fd 3 so that nothing called
# inside can eat it from stdin.
while IFS= read -r ifn <&3; do
    [ -n "$ifn" ] || continue
    d="$IF_LINK_SYSNET/$ifn"
    sif=$(sanitize "$ifn")

    # --- the cumulative change counter -------------------------------
    changes=$(attr "$d" carrier_changes)
    if ! is_uint "$changes"; then
        upc=$(attr "$d" carrier_up_count)
        downc=$(attr "$d" carrier_down_count)
        if is_uint "$upc" && is_uint "$downc"; then
            changes=$((upc + downc))
        else
            printf '&clear %s  no link change counter in this kernel - not monitored\n' \
                "$ifn" >> "$STATUS"
            continue
        fi
    fi
    NIF=$((NIF + 1))

    # --- current link state ------------------------------------------
    carrier=$(attr "$d" carrier)
    operstate=$(attr "$d" operstate)
    case "$carrier" in
        1) link="up" ;;
        0) link="down" ;;
        *) link="admin-down" ;;     # carrier is unreadable while !IFF_UP
    esac

    # --- changes since the previous poll ------------------------------
    delta=""
    note=""
    if prev=$(state_get IF "$ifn"); then
        # shellcheck disable=SC2086  # word splitting is intended
        set -- $prev
        pts=${1:-}
        pchanges=${2:-}
        if is_uint "$pchanges" && [ "$changes" -ge "$pchanges" ]; then
            delta=$((changes - pchanges))
            is_uint "$pts" && LAST_TS="$pts"
        elif is_uint "$pchanges"; then
            # Counter went backwards: reboot or interface re-created.
            # Skip this round instead of reporting a negative delta.
            note="counter reset"
        fi
    else
        note="first poll"
    fi

    printf 'IF %s %s %s\n' "$ifn" "$NOW" "$changes" >> "$NEWSTATE"

    # --- color --------------------------------------------------------
    thresholds_for "$ifn"
    ifcolor=green
    limit=""
    if [ -n "$delta" ]; then
        HAVEDELTA=yes
        TOTALDELTA=$((TOTALDELTA + delta))
        [ "$delta" -gt 0 ] && NFLAP=$((NFLAP + 1))
        if is_uint "$TH_R" && [ "$delta" -ge "$TH_R" ]; then
            ifcolor=red
            limit="red at >=${TH_R}"
        elif is_uint "$TH_Y" && [ "$delta" -ge "$TH_Y" ]; then
            ifcolor=yellow
            limit="yellow at >=${TH_Y}"
        fi
    fi
    case "$ifcolor" in
        red) WORST=red ;;
        yellow) [ "$WORST" = red ] || WORST=yellow ;;
    esac

    # An interface that is administratively down cannot flap; mark it
    # as such in the display without touching the column color.
    dispcolor="$ifcolor"
    if [ "$ifcolor" = green ] && [ "$link" = admin-down ]; then
        dispcolor=clear
    fi

    # --- metric and status line ----------------------------------------
    ncv "changes_$sif" "$delta"

    detail=""
    if [ "$link" = up ]; then
        speed=$(attr "$d" speed)
        duplex=$(attr "$d" duplex)
        if is_uint "$speed" && [ "$speed" -gt 0 ]; then
            detail="speed=${speed}Mb"
            case "$duplex" in
                full|half) detail="${detail}/${duplex}" ;;
            esac
        fi
    elif [ -n "$operstate" ]; then
        detail="operstate=${operstate}"
    fi
    if [ -L "$d/master" ]; then
        master=$(readlink "$d/master" 2>/dev/null)
        master=${master##*/}
        [ -n "$master" ] && detail="${detail}${detail:+  }master=${master}"
    fi

    {
        printf '&%s %s  link=%s' "$dispcolor" "$ifn" "$link"
        [ -n "$detail" ] && printf '  %s' "$detail"
        if [ -n "$delta" ]; then
            printf '  changes=+%s' "$delta"
        else
            printf '  changes=n/a(%s)' "${note:-no previous data}"
        fi
        printf '  total=%s' "$changes"
        [ -n "$limit" ] && printf '  [%s]' "$limit"
        printf '\n'
    } >> "$STATUS"
done 3< "$WORKDIR/ifs"

# Remember this run's counters (best effort - a read-only $XYMONTMP
# only disables the delta calculation, it must not kill the report).
if [ -s "$NEWSTATE" ]; then
    if cat "$NEWSTATE" > "${STATEFILE}.$$" 2>/dev/null; then
        mv "${STATEFILE}.$$" "$STATEFILE" 2>/dev/null || rm -f "${STATEFILE}.$$"
    fi
fi

if [ "$HAVEDELTA" = yes ]; then
    SUMMARY="${TOTALDELTA} link change(s) on ${NFLAP} of ${NIF} interface(s) since the previous poll"
else
    SUMMARY="${NIF} interface(s) monitored - link changes appear with the next poll"
fi

{
    cat "$STATUS"
    printf '\n'
    printf 'Counted by the kernel (carrier_changes), so short flaps between two polls are included:\n'
    printf 'one link down plus the following link up are two changes. "total" is the cumulative\n'
    printf 'counter since boot, "changes" the difference to the previous poll'
    if is_uint "$LAST_TS" && [ "$NOW" -gt "$LAST_TS" ]; then
        printf ' (%s s ago)' "$((NOW - LAST_TS))"
    fi
    printf '.\n'
    if [ -z "$IF_LINK_YELLOW" ] && [ -z "$IF_LINK_RED" ] && [ -z "$IF_LINK_THRESHOLDS" ]; then
        printf 'No thresholds configured: this column stays green. Set IF_LINK_YELLOW/IF_LINK_RED\n'
        printf 'or IF_LINK_THRESHOLDS in if_link.cfg to alert on flapping ports.\n'
    fi
    printf '<!-- ncv_skipend -->\n'
} > "$WORKDIR/final"

send_report "$WORST" "$WORKDIR/final" "$DATA"
exit 0
