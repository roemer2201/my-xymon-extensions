#!/bin/sh
#
# lxc.sh -- Xymon client extension: LXC container status
#
# Reports every LXC container of a host in one "lxc" column: whether
# it runs, and what it costs. A container that is supposed to run but
# does not is red; one that is stopped and not configured for
# autostart is green ("not autostarted"), because a template or a
# retired container must not alarm anybody.
#
# "Supposed to run" is derived from three sources, in this order:
#   1. LXC_REQUIRED (globs) - an explicit list wins over everything
#   2. the AUTOSTART column of "lxc-ls -f" (i.e. lxc.start.auto)
#      plus the container names in /etc/config/lxc-auto, which is how
#      OpenWrt/TurrisOS starts containers (its lxc-auto init script
#      does not need lxc.start.auto, so the AUTOSTART column alone
#      misses those), plus whatever "lxc-autostart -L" lists
#   3. LXC_OPTIONAL (globs) removes containers from that set again
# Note that "lxc-autostart -L" only lists containers it would START,
# i.e. running ones are filtered out - an empty output is no proof
# that nothing should be running. That is why it is only one of the
# three sources and never the only one.
#
# Per container the metrics are delivered as "<container>_<metric>"
# in a separate "data" message (split-NCV on the Xymon server, see
# server/README.md), so every container and metric gets an RRD file
# of its own and adding or removing a container never touches an
# existing graph:
#   <ct>_ram     resident memory in MiB
#   <ct>_cpu     CPU usage in percent of one core since the last poll
#   <ct>_netin   traffic into the container in kbit/s
#   <ct>_netout  traffic out of the container in kbit/s
# plus the host-wide counts count_total, count_running and count_down.
#
# Where the numbers come from:
#   CPU   cpu.stat (usage_usec) of the container's cgroup, cgroup v2,
#         or cpuacct.usage on cgroup v1 - both cumulative, the
#         extension computes the delta between two polls itself.
#   RAM   memory.current / memory.usage_in_bytes of the same cgroup.
#         On OpenWrt/TurrisOS the memory controller is not enabled for
#         the container cgroups (cgroup.subtree_control is empty), so
#         that file is missing or reads 0 - and "lxc-ls -f -F RAM"
#         reports 0.00MB for the same reason. LXC_RAM="auto" then
#         falls back to summing the RSS of the container's processes
#         from /proc, which counts shared pages more than once and is
#         therefore a slight over-estimate.
#   NET   the TX/RX byte counters of "lxc-info -H", measured on the
#         HOST side of the veth pair - so its "TX" is traffic the host
#         sent INTO the container. The metrics here are named from the
#         container's point of view instead: netin = lxc-info's TX,
#         netout = lxc-info's RX.
#
# Hosts without LXC report "clear".
#
# Configuration: environment variables and/or $XYMONHOME/etc/lxc.cfg
# (see the shipped lxc.cfg; the config file wins over the environment).

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
# Defaults -- every value can be set in the environment or in lxc.cfg
# ----------------------------------------------------------------------
LXC_COLUMN="${LXC_COLUMN:-lxc}"           # Xymon column name
LXC_LS="${LXC_LS:-}"                      # empty: found via command -v
LXC_INFO="${LXC_INFO:-}"                  # empty: found via command -v
LXC_AUTOSTART="${LXC_AUTOSTART:-}"        # empty: found via command -v
LXC_UCI_AUTO="${LXC_UCI_AUTO:-/etc/config/lxc-auto}"  # OpenWrt autostart
LXC_REQUIRED="${LXC_REQUIRED:-}"          # globs: must run (overrides)
LXC_OPTIONAL="${LXC_OPTIONAL:-}"          # globs: may be stopped
LXC_IGNORE="${LXC_IGNORE:-}"              # globs: not monitored at all
LXC_DOWN_COLOR="${LXC_DOWN_COLOR:-red}"   # color for "should run, does not"
LXC_CGROUPFS="${LXC_CGROUPFS:-/sys/fs/cgroup}"
LXC_PROC="${LXC_PROC:-/proc}"
LXC_RAM="${LXC_RAM:-auto}"                # auto|cgroup|proc|off
LXC_METRICS="${LXC_METRICS:-ram cpu net}" # which metrics to graph
LXC_RAM_YELLOW="${LXC_RAM_YELLOW:-}"      # MiB, per container
LXC_RAM_RED="${LXC_RAM_RED:-}"            # MiB, per container
LXC_CPU_YELLOW="${LXC_CPU_YELLOW:-}"      # percent of one core
LXC_CPU_RED="${LXC_CPU_RED:-}"            # percent of one core

CFGFILE="${LXC_CFG:-${XYMONHOME:+${XYMONHOME}/etc/lxc.cfg}}"
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi
COLUMN="$LXC_COLUMN"

case "$LXC_DOWN_COLOR" in
    red|yellow) ;;
    *) LXC_DOWN_COLOR=red ;;
esac

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

# sanitize <text> -> lowercase, [a-z0-9_] only, squeezed and trimmed.
# The result names an RRD file on the server, so it must survive the
# round trip through the FNPATTERN in server/graphs.d/lxc.cfg.
sanitize() {
    # shellcheck disable=SC2018,SC2019  # NOT '[:upper:]'/'[:lower:]': BusyBox
    # tr (TurrisOS 1.36.1) does not recognize the class syntax and instead
    # translates it letter-by-letter as the literal string "[:upper:]" -
    # e.g. "product" silently becomes "wrodlct" because 'p' and 'u' occur
    # in that literal string. A-Z/a-z ranges are the portable form.
    s_out=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '_' | tr -s '_')
    s_out=${s_out#_}
    printf '%s' "${s_out%_}"
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

# in_list <word> <word-list> -> true if the list contains the word
in_list() {
    # shellcheck disable=SC2086  # the list is space-separated on purpose
    for il_w in $2; do
        [ "$il_w" = "$1" ] && return 0
    done
    return 1
}

# state_get <key> -> prints fields 3..NF of the matching state line;
# fails when the state file or the line is missing.
state_get() {
    [ -r "$STATEFILE" ] || return 1
    sg_out=$(awk -v k="$1" '
        $1 == "CT" && $2 == k {
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
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - lxc: ${SUMMARY:-$1}

$(cat "$2")"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            "$XYMON" "$XYMSRV" "data ${MACHINE}.${COLUMN}
$(cat "$3")"
        fi
    else
        # No Xymon environment: print the messages (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - lxc: ${SUMMARY:-$1}"
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

WORKDIR=$(mktemp -d "${XYMONTMP}/lxc.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

DATA="$WORKDIR/data"
STATUS="$WORKDIR/status"
NEWSTATE="$WORKDIR/newstate"
: > "$DATA"
: > "$NEWSTATE"
SUMMARY=""

# Everything written to $STATUS is for humans only - the metrics
# travel in the separate "data" message. xymond_rrd's NCV parser
# treats both ":" and "=" as a name/value separator, so without these
# markers every "state=RUNNING" would become an RRD dataset of its
# own. The markers are HTML comments and stay invisible on the Xymon
# web page.
printf '<!-- ncv_skipstart -->\n' > "$STATUS"

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

# --- the LXC tools must exist ----------------------------------------
[ -n "$LXC_LS" ] || LXC_LS=$(command -v lxc-ls 2>/dev/null)
[ -n "$LXC_INFO" ] || LXC_INFO=$(command -v lxc-info 2>/dev/null)
[ -n "$LXC_AUTOSTART" ] || LXC_AUTOSTART=$(command -v lxc-autostart 2>/dev/null)

if [ -z "$LXC_LS" ] || [ ! -x "$LXC_LS" ]; then
    clear_report "lxc-ls not found - no LXC installation on this host (install the lxc tools, or set LXC_LS in lxc.cfg)"
fi

# --- inventory --------------------------------------------------------
# These four columns are the ones worth parsing: none of their values
# can contain a space, while IPV4/IPV6/INTERFACE hold comma-separated
# lists that would shift the fields. The byte counters come from
# lxc-info below, which is a separate package on OpenWrt and may well
# be missing - everything except the traffic works without it.
"$LXC_LS" -f -F NAME,STATE,PID,AUTOSTART 2>/dev/null \
    | awk '$1 != "NAME" && NF >= 4 { print $1, $2, $3, ($4 == "1" ? 1 : 0) }' \
    > "$WORKDIR/all" 2>/dev/null

if [ ! -s "$WORKDIR/all" ]; then
    # Old lxc-ls without -F, or no containers at all. The plain list
    # still works; state and PID then come from lxc-info, the autostart
    # flag from the other two sources below.
    "$LXC_LS" -1 2>/dev/null | awk 'NF == 1 { print $1, "?", "-", "-" }' \
        > "$WORKDIR/all"
fi

if [ ! -s "$WORKDIR/all" ]; then
    clear_report "no LXC container defined on this host - nothing to monitor"
fi

# --- containers the host is supposed to start -------------------------
: > "$WORKDIR/uci"
: > "$WORKDIR/autostart"
if [ -r "$LXC_UCI_AUTO" ]; then
    # OpenWrt/TurrisOS UCI section:
    #   config container
    #           option name jd
    # Values may be quoted; strip both quote characters via their
    # octal codes, so the awk program itself needs none.
    tr -d '\42\47' < "$LXC_UCI_AUTO" \
        | awk '$1 == "option" && $2 == "name" && NF >= 3 { print $3 }' \
        >> "$WORKDIR/uci"
fi
if [ -n "$LXC_AUTOSTART" ] && [ -x "$LXC_AUTOSTART" ]; then
    # Lists the containers lxc-autostart would start now, i.e. the ones
    # with lxc.start.auto that are NOT running. Never a complete
    # "should run" list on its own - see the header comment.
    "$LXC_AUTOSTART" -L 2>/dev/null | awk 'NF >= 1 { print $1 }' \
        >> "$WORKDIR/autostart"
fi
UCI_AUTO=$(tr '\n' ' ' < "$WORKDIR/uci")
LIST_AUTO=$(tr '\n' ' ' < "$WORKDIR/autostart")

# --- resolve the cgroup of every running container --------------------
# cgmap holds "<name> <kernel cgroup path>" for the /proc scan below.
: > "$WORKDIR/cgmap"

# cgroup_root_of <pid> <name> -> the container's cgroup path as the
# kernel names it (e.g. /lxc.payload.ca). Derived from the container's
# init process, so it works with every layout LXC uses (lxc.payload.*
# on cgroup v2, lxc/<name> on v1, lxc@<name>.service under systemd):
# the first path component that carries the container name is it.
cgroup_root_of() {
    cr_out=""
    if is_uint "${1:-}" && [ -r "$LXC_PROC/$1/cgroup" ]; then
        cr_out=$(awk -v n="$2" '
            substr($0, 1, 3) == "0::" { p = substr($0, 4); next }
            p == "" {
                # cgroup v1 line: "<id>:<subsystems>:<path>"
                i = index($0, ":")
                if (i > 0) {
                    r = substr($0, i + 1)
                    j = index(r, ":")
                    if (j > 0) p = substr(r, j + 1)
                }
            }
            END {
                if (p == "") exit 1
                k = split(p, c, "/")
                out = ""
                for (i = 2; i <= k; i++) {
                    out = out "/" c[i]
                    if (index(c[i], n) > 0) { print out; exit 0 }
                }
                exit 1
            }' "$LXC_PROC/$1/cgroup" 2>/dev/null)
    fi
    if [ -z "$cr_out" ]; then
        # No usable PID (or an unreadable /proc): try the layouts LXC
        # is known to use.
        for cr_c in "lxc.payload.$2" "lxc.payload/$2" "lxc/$2"; do
            if [ -d "$LXC_CGROUPFS/$cr_c" ]; then
                cr_out="/$cr_c"
                break
            fi
        done
    fi
    [ -n "$cr_out" ] || return 1
    printf '%s' "$cr_out"
}

# cpu_usec_of <cgroup path> -> cumulative CPU time in microseconds
cpu_usec_of() {
    cu_f="$LXC_CGROUPFS$1/cpu.stat"
    if [ -r "$cu_f" ]; then
        cu_v=$(awk '$1 == "usage_usec" { print $2; exit }' "$cu_f")
        if is_uint "$cu_v"; then
            printf '%s' "$cu_v"
            return 0
        fi
    fi
    for cu_f in "$LXC_CGROUPFS/cpuacct$1/cpuacct.usage" \
                "$LXC_CGROUPFS$1/cpuacct.usage"; do
        [ -r "$cu_f" ] || continue
        read -r cu_v < "$cu_f" 2>/dev/null || continue
        if is_uint "$cu_v"; then
            printf '%s' "$((cu_v / 1000))"      # ns -> us
            return 0
        fi
    done
    return 1
}

# ram_cgroup_of <cgroup path> -> resident bytes from the memory
# controller. A missing file or a plain 0 both mean "the controller is
# not accounting this cgroup" (OpenWrt: cgroup.subtree_control is
# empty), which is a failure here, not a measurement.
ram_cgroup_of() {
    for rc_f in "$LXC_CGROUPFS$1/memory.current" \
                "$LXC_CGROUPFS/memory$1/memory.usage_in_bytes" \
                "$LXC_CGROUPFS$1/memory.usage_in_bytes"; do
        [ -r "$rc_f" ] || continue
        read -r rc_v < "$rc_f" 2>/dev/null || continue
        if is_uint "$rc_v" && [ "$rc_v" -gt 0 ]; then
            printf '%s' "$rc_v"
            return 0
        fi
    done
    return 1
}

# info_of <name> -> "<state> <pid> <bytes into ct> <bytes out of ct>"
# from a single lxc-info call. -H asks for raw numbers, but old
# versions scale the byte counters anyway, so the units are handled.
info_of() {
    "$LXC_INFO" -n "$1" -H 2>/dev/null | awk '
        function scale(v, u) {
            if (u == "KiB" || u == "KB") return v * 1024
            if (u == "MiB" || u == "MB") return v * 1048576
            if (u == "GiB" || u == "GB") return v * 1073741824
            if (u == "TiB" || u == "TB") return v * 1099511627776
            return v
        }
        $1 == "State:"                 { state = $2 }
        $1 == "PID:"                   { pid = $2 }
        $1 == "TX" && $2 == "bytes:"   { tx += scale($3, $4) }
        $1 == "RX" && $2 == "bytes:"   { rx += scale($3, $4) }
        END {
            printf "%s %s %.0f %.0f\n",
                (state == "" ? "UNKNOWN" : state),
                (pid == "" ? "-" : pid), tx, rx
        }'
}

# --- collect the per-container facts ----------------------------------
NOW=$(date +%s)
STATEFILE="${XYMONTMP}/lxc.${MACHINE}.state"
PAGESIZE=$(getconf PAGESIZE 2>/dev/null)
is_uint "$PAGESIZE" || PAGESIZE=4096

N_TOTAL=0
N_RUNNING=0
N_DOWN=0
WORST=green
DOWNLIST=""

# Every field of the facts file is written with a "-" placeholder when
# it is empty, so that a plain "read" splits them all apart: LXC
# container names carry neither spaces nor tabs, and empty fields would
# collapse against each other.
: > "$WORKDIR/facts"
while read -r name state pid auto <&3; do
    [ -n "$name" ] || continue
    if [ -n "$LXC_IGNORE" ] && match_any "$name" "$LXC_IGNORE"; then
        continue
    fi
    N_TOTAL=$((N_TOTAL + 1))

    tx="-"
    rx="-"
    if [ -n "$LXC_INFO" ] && [ -x "$LXC_INFO" ] \
        && { [ "$state" = RUNNING ] || [ "$state" = "?" ]; }; then
        # shellcheck disable=SC2046  # four space-free fields on purpose
        set -- $(info_of "$name")
        [ "$state" = "?" ] && state=${1:-UNKNOWN}
        [ "$pid" = "-" ] && pid=${2:--}
        tx=${3:--}
        rx=${4:--}
    fi
    [ "$state" = "?" ] && state=UNKNOWN

    cgroot="-"
    if [ "$state" = RUNNING ]; then
        N_RUNNING=$((N_RUNNING + 1))
        cgroot=$(cgroup_root_of "$pid" "$name") || cgroot="-"
        [ "$cgroot" = "-" ] || printf '%s %s\n' "$name" "$cgroot" >> "$WORKDIR/cgmap"
    fi

    printf '%s %s %s %s %s %s %s\n' \
        "$name" "$auto" "$state" "$pid" "$tx" "$rx" "$cgroot" \
        >> "$WORKDIR/facts"
done 3< "$WORKDIR/all"

if [ "$N_TOTAL" -eq 0 ]; then
    clear_report "every container is excluded by LXC_IGNORE=\"$LXC_IGNORE\" - nothing left to monitor"
fi

# --- RAM: one /proc pass for all containers ---------------------------
# Runs a single awk over /proc instead of forking per process: 300
# processes cost about a fifth of a second that way, and roughly a
# second with the obvious shell loop.
: > "$WORKDIR/ram"
if [ -s "$WORKDIR/cgmap" ] && { [ "$LXC_RAM" = auto ] || [ "$LXC_RAM" = proc ]; }; then
    for p in "$LXC_PROC"/[0-9]*; do
        [ -d "$p" ] || continue
        printf '%s\n' "$p"
    done | awk -v map="$WORKDIR/cgmap" -v ps="$PAGESIZE" '
        BEGIN {
            n = 0
            while ((getline line < map) > 0) {
                if (split(line, f, " ") < 2) continue
                n++
                cname[n] = f[1]
                croot[n] = f[2]
            }
            close(map)
        }
        {
            pdir = $0
            cgf = pdir "/cgroup"
            cg = ""
            while ((getline l < cgf) > 0) {
                if (substr(l, 1, 4) == "0::/") { cg = substr(l, 4); break }
                if (cg == "") {
                    i = index(l, ":")
                    if (i > 0) {
                        r = substr(l, i + 1)
                        j = index(r, ":")
                        if (j > 0) cg = substr(r, j + 1)
                    }
                }
            }
            close(cgf)
            if (cg == "") next
            for (i = 1; i <= n; i++) {
                len = length(croot[i])
                if (substr(cg, 1, len) != croot[i]) continue
                if (length(cg) != len && substr(cg, len + 1, 1) != "/") continue
                sf = pdir "/statm"
                if ((getline sl < sf) > 0 && split(sl, sfld, " ") >= 2)
                    rss[cname[i]] += sfld[2]
                close(sf)
                break
            }
        }
        END { for (k in rss) printf "%s %.0f\n", k, rss[k] * ps }
    ' > "$WORKDIR/ram" 2>/dev/null
fi

ram_proc_of() {
    [ -s "$WORKDIR/ram" ] || return 1
    rp_v=$(awk -v n="$1" '$1 == n { print $2; exit }' "$WORKDIR/ram")
    is_uint "$rp_v" || return 1
    printf '%s' "$rp_v"
}

# --- report ------------------------------------------------------------
HAVERATE=no
LAST_TS=""

while read -r name auto state pid tx rx cgroot <&3; do
    [ -n "$name" ] || continue
    sname=$(sanitize "$name")
    [ "$tx" = "-" ] && tx=""
    [ "$rx" = "-" ] && rx=""
    [ "$cgroot" = "-" ] && cgroot=""

    # --- is this container supposed to run? ---------------------------
    why=""
    expected=no
    if [ -n "$LXC_REQUIRED" ]; then
        if match_any "$name" "$LXC_REQUIRED"; then
            expected=yes
            why="required"
        fi
    else
        if [ "$auto" = "1" ]; then
            expected=yes
            why="lxc.start.auto"
        fi
        if in_list "$name" "$UCI_AUTO"; then
            expected=yes
            why="${why:+$why+}${LXC_UCI_AUTO##*/}"
        fi
        if in_list "$name" "$LIST_AUTO"; then
            expected=yes
            why="${why:+$why+}lxc-autostart"
        fi
    fi
    if [ "$expected" = yes ] && [ -n "$LXC_OPTIONAL" ] \
        && match_any "$name" "$LXC_OPTIONAL"; then
        expected=no
        why="optional"
    fi

    # --- color --------------------------------------------------------
    color=green
    note=""
    case "$state" in
        RUNNING)
            ;;
        FROZEN)
            if [ "$expected" = yes ]; then
                color="$LXC_DOWN_COLOR"
            else
                color=yellow
            fi
            note="container is frozen"
            ;;
        STARTING|STOPPING|ABORTING)
            color=yellow
            note="state transition in progress"
            ;;
        STOPPED)
            if [ "$expected" = yes ]; then
                color="$LXC_DOWN_COLOR"
                note="should be running ($why)"
                N_DOWN=$((N_DOWN + 1))
                DOWNLIST="${DOWNLIST:+$DOWNLIST }$name"
            else
                note="not autostarted"
            fi
            ;;
        *)
            color=yellow
            note="lxc-info reports no state for this container"
            ;;
    esac

    # --- metrics ------------------------------------------------------
    ram=""
    rammib=""
    cpupct=""
    kin=""
    kout=""
    if [ "$state" = RUNNING ]; then
        # RAM (gauge, no state needed)
        if [ "$LXC_RAM" != off ] && in_list ram "$LXC_METRICS"; then
            case "$LXC_RAM" in
                cgroup) [ -n "$cgroot" ] && ram=$(ram_cgroup_of "$cgroot") ;;
                proc)   ram=$(ram_proc_of "$name") ;;
                *)
                    [ -n "$cgroot" ] && ram=$(ram_cgroup_of "$cgroot")
                    [ -n "$ram" ] || ram=$(ram_proc_of "$name")
                    ;;
            esac
            if is_uint "$ram"; then
                rammib=$(awk -v b="$ram" 'BEGIN { printf "%.1f", b / 1048576 }')
            fi
        fi

        # CPU and network are counters: remember them and report the
        # difference to the previous poll.
        cpu=""
        [ -n "$cgroot" ] && cpu=$(cpu_usec_of "$cgroot")
        printf 'CT %s %s %s %s %s\n' \
            "$name" "$NOW" "${cpu:--}" "${tx:--}" "${rx:--}" >> "$NEWSTATE"

        if prev=$(state_get "$name"); then
            # shellcheck disable=SC2086  # word splitting is intended
            set -- $prev
            pts=${1:-}
            pcpu=${2:-}
            ptx=${3:-}
            prx=${4:-}
            if is_uint "$pts" && [ "$NOW" -gt "$pts" ]; then
                dt=$((NOW - pts))
                LAST_TS="$pts"
                HAVERATE=yes
                if is_uint "$cpu" && is_uint "$pcpu" && [ "$cpu" -ge "$pcpu" ] \
                    && in_list cpu "$LXC_METRICS"; then
                    cpupct=$(awk -v d="$((cpu - pcpu))" -v t="$dt" \
                        'BEGIN { printf "%.1f", d / 10000 / t }')
                fi
                if in_list net "$LXC_METRICS"; then
                    if is_uint "$tx" && is_uint "$ptx" && [ "$tx" -ge "$ptx" ]; then
                        kin=$(awk -v d="$((tx - ptx))" -v t="$dt" \
                            'BEGIN { printf "%.1f", d * 8 / 1000 / t }')
                    fi
                    if is_uint "$rx" && is_uint "$prx" && [ "$rx" -ge "$prx" ]; then
                        kout=$(awk -v d="$((rx - prx))" -v t="$dt" \
                            'BEGIN { printf "%.1f", d * 8 / 1000 / t }')
                    fi
                fi
            fi
        fi

        # --- resource thresholds --------------------------------------
        limit=""
        if [ -n "$rammib" ]; then
            if is_uint "$LXC_RAM_RED" \
                && awk -v v="$rammib" -v l="$LXC_RAM_RED" 'BEGIN { exit !(v >= l) }'; then
                color=red
                limit="red at >=${LXC_RAM_RED} MiB"
            elif is_uint "$LXC_RAM_YELLOW" \
                && awk -v v="$rammib" -v l="$LXC_RAM_YELLOW" 'BEGIN { exit !(v >= l) }'; then
                [ "$color" = red ] || color=yellow
                limit="yellow at >=${LXC_RAM_YELLOW} MiB"
            fi
        fi
        if [ -n "$cpupct" ]; then
            if is_uint "$LXC_CPU_RED" \
                && awk -v v="$cpupct" -v l="$LXC_CPU_RED" 'BEGIN { exit !(v >= l) }'; then
                color=red
                limit="${limit:+$limit, }red at >=${LXC_CPU_RED}% CPU"
            elif is_uint "$LXC_CPU_YELLOW" \
                && awk -v v="$cpupct" -v l="$LXC_CPU_YELLOW" 'BEGIN { exit !(v >= l) }'; then
                [ "$color" = red ] || color=yellow
                limit="${limit:+$limit, }yellow at >=${LXC_CPU_YELLOW}% CPU"
            fi
        fi
        [ -n "$limit" ] && note="${note:+$note - }[$limit]"

        ncv "${sname}_ram" "$rammib"
        ncv "${sname}_cpu" "$cpupct"
        ncv "${sname}_netin" "$kin"
        ncv "${sname}_netout" "$kout"
    fi

    case "$color" in
        red) WORST=red ;;
        yellow) [ "$WORST" = red ] || WORST=yellow ;;
    esac

    # A stopped container nobody expects to run is not a fault, and it
    # is not healthy either - "clear" says exactly that without
    # touching the column color.
    dispcolor="$color"
    if [ "$color" = green ] && [ "$state" != RUNNING ]; then
        dispcolor=clear
    fi

    {
        printf '&%s %s  state=%s' "$dispcolor" "$name" "$state"
        if [ "$expected" = yes ]; then
            printf '  autostart=yes(%s)' "$why"
        else
            printf '  autostart=no'
        fi
        [ "$pid" != "-" ] && [ -n "$pid" ] && printf '  pid=%s' "$pid"
        [ -n "$rammib" ] && printf '  ram=%sMiB' "$rammib"
        [ -n "$cpupct" ] && printf '  cpu=%s%%' "$cpupct"
        if [ -n "$kin" ] || [ -n "$kout" ]; then
            printf '  net=%s/%s kbit/s' "${kin:-?}" "${kout:-?}"
        fi
        [ -n "$note" ] && printf '  %s' "$note"
        printf '\n'
    } >> "$STATUS"
done 3< "$WORKDIR/facts"

# --- host-wide counts --------------------------------------------------
ncv count_total "$N_TOTAL"
ncv count_running "$N_RUNNING"
ncv count_down "$N_DOWN"

# Remember this run's counters (best effort - a read-only $XYMONTMP
# only disables the rate calculation, it must not kill the report).
if [ -s "$NEWSTATE" ]; then
    if cat "$NEWSTATE" > "${STATEFILE}.$$" 2>/dev/null; then
        mv "${STATEFILE}.$$" "$STATEFILE" 2>/dev/null || rm -f "${STATEFILE}.$$"
    fi
else
    rm -f "$STATEFILE" 2>/dev/null
fi

if [ "$N_DOWN" -gt 0 ]; then
    SUMMARY="${N_DOWN} of ${N_TOTAL} container(s) not running although they should: ${DOWNLIST}"
elif [ "$WORST" = green ]; then
    SUMMARY="${N_RUNNING} of ${N_TOTAL} container(s) running"
else
    SUMMARY="${N_RUNNING} of ${N_TOTAL} container(s) running - see below"
fi

{
    cat "$STATUS"
    printf '\n'
    printf 'A container is expected to run when lxc.start.auto is set, when it is listed in\n'
    printf '%s, or when lxc-autostart -L names it; LXC_REQUIRED/LXC_OPTIONAL\n' "$LXC_UCI_AUTO"
    printf 'in lxc.cfg override that. Anything else may be stopped without alarm.\n'
    if [ "$HAVERATE" = yes ] && is_uint "$LAST_TS" && [ "$NOW" -gt "$LAST_TS" ]; then
        printf 'cpu and net are averages since the previous poll (%s s ago); cpu is percent of\n' \
            "$((NOW - LAST_TS))"
        printf 'ONE core, net is in/out as seen by the container.\n'
    else
        printf 'cpu and net need a previous poll and appear with the next run.\n'
    fi
    if [ -s "$WORKDIR/ram" ]; then
        printf 'ram is the sum of the resident memory of the container processes (/proc): the\n'
        printf 'memory cgroup controller does not account these containers, so shared pages are\n'
        printf 'counted more than once and the value is a slight over-estimate.\n'
    fi
    printf '<!-- ncv_skipend -->\n'
} > "$WORKDIR/final"

send_report "$WORST" "$WORKDIR/final" "$DATA"
exit 0
