#!/bin/sh
#
# systemd.sh -- Xymon client extension: systemd service manager health
#
# Reports the state of a host's systemd service manager in one
# "systemd" column:
#
#   * the overall system state ("systemctl is-system-running"),
#   * every failed unit of any type (service, mount, timer, socket, ...),
#   * optional "required" units that must be active (SYSD_REQUIRED),
#   * automatic restarts of services (Restart=), detected through the
#     per-service NRestarts counter. A service in a restart loop is
#     "active" most of the time and never "failed" without a start
#     limit - the counter is the only place that loop shows up.
#
# A detected restart colors the column for SYSD_RESTART_HOLD seconds
# (default 1800 = 30 min) after the last restart seen, so a single
# crash does not vanish at the next poll.
# The hold survives a unit being unloaded or a failed counter query;
# query errors warn without discarding the last successful snapshot.
#
# Program flow:
#   1. defaults -> config file -> SYSD_ENABLE ("no": report clear)
#   2. not booted with systemd (FreeBSD, OpenRC, a container without
#      systemd as PID 1) or no systemctl -> report clear
#   3. systemctl is-system-running        -> system state color
#   4. systemctl list-units --all          -> failed units, minus
#      SYSD_IGNORE (not counted) and SYSD_WARN (yellow only)
#   5. systemctl show per SYSD_REQUIRED unit -> required units down
#   6. systemctl show -p NRestarts for every loaded service, compared
#      with the previous poll's state file   -> restarts per poll,
#      color held for SYSD_RESTART_HOLD seconds
#   7. status message (worst color wins) plus a "data" message with
#      the two graphed values "failed" and "restarts" (plain NCV on
#      the server, see server/README.md)
#
# Why NRestarts can be trusted between polls: systemd resets it on
# every start that is not an automatic restart (manual start/restart,
# also "systemctl reset-failed") - src/core/service.c, "This is not an
# automatic restart? Flush the restart counter then." A counter that
# went DOWN therefore means "reset in between", and every restart it
# shows now happened after that reset, i.e. since the previous poll.
# NRestarts exists since systemd 235 (Rocky 8 ships 239, Ubuntu 20.04
# 245); older versions only lose the restart part of this test.
#
# Everything is read through unprivileged D-Bus queries; no root or
# sudo is needed.
#
# Configuration: environment variables and/or
# $XYMONHOME/etc/my-xymon-extensions/systemd.cfg (see the shipped
# systemd.cfg; the config file wins over the environment).
#
# The variables use the prefix SYSD_ and not SYSTEMD_: systemd itself
# reads a long list of SYSTEMD_* environment variables (docs/
# ENVIRONMENT.md in the systemd sources, e.g. SYSTEMD_BUS_TIMEOUT), and
# one of ours that ends up exported must never change what systemctl
# does.

set -u

# No pathname expansion anywhere: the unit lists and glob pattern lists
# (SYSD_IGNORE="*", "slurm*") are split unquoted on purpose, and a
# pattern must reach the case statement in match_any() as it is - not
# expanded against the files in the current directory first.
set -f

# Every number in a Xymon message must use a decimal point, and
# systemctl's output must not depend on the locale either.
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
# systemd.cfg
# ----------------------------------------------------------------------
SYSD_ENABLE="${SYSD_ENABLE:-yes}"                 # "no": clear column
SYSD_COLUMN="${SYSD_COLUMN:-systemd}"             # Xymon column name
SYSD_FAILED_COLOR="${SYSD_FAILED_COLOR:-red}"     # failed unit
SYSD_IGNORE="${SYSD_IGNORE:-}"                    # globs: failed, no alarm
SYSD_WARN="${SYSD_WARN:-}"                        # globs: failed -> yellow
SYSD_REQUIRED="${SYSD_REQUIRED:-}"                # units that must be active
SYSD_DOWN_COLOR="${SYSD_DOWN_COLOR:-red}"         # required unit not active
SYSD_TRANSITION_COLOR="${SYSD_TRANSITION_COLOR:-yellow}"  # boot/shutdown
SYSD_RESTART_COLOR="${SYSD_RESTART_COLOR:-yellow}"  # service restarted
SYSD_RESTART_HOLD="${SYSD_RESTART_HOLD:-1800}"    # seconds to keep it
SYSD_RESTART_IGNORE="${SYSD_RESTART_IGNORE:-}"    # globs: restarts ignored
SYSD_SYSTEMCTL="${SYSD_SYSTEMCTL:-}"              # empty: command -v
SYSD_RUNDIR="${SYSD_RUNDIR:-/run/systemd/system}" # sd_booted(3) marker

# Own subdirectory since 0.20.0 ($XYMONHOME/etc is shared with the
# Xymon server and hobbit-plugins); the old place is the fallback.
CFGFILE="${SYSD_CFG:-}"
if [ -z "$CFGFILE" ] && [ -n "$XYMONHOME" ]; then
    CFGFILE="$XYMONHOME/etc/my-xymon-extensions/systemd.cfg"
    [ -f "$CFGFILE" ] || CFGFILE="$XYMONHOME/etc/systemd.cfg"
fi
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi
COLUMN="$SYSD_COLUMN"

# Invalid colors fall back to the default instead of producing a
# status message the Xymon server rejects.
case "$SYSD_FAILED_COLOR" in red|yellow) ;; *) SYSD_FAILED_COLOR=red ;; esac
case "$SYSD_DOWN_COLOR" in red|yellow) ;; *) SYSD_DOWN_COLOR=red ;; esac
case "$SYSD_TRANSITION_COLOR" in
    red|yellow|green) ;;
    *) SYSD_TRANSITION_COLOR=yellow ;;
esac
case "$SYSD_RESTART_COLOR" in
    red|yellow|green) ;;
    *) SYSD_RESTART_COLOR=yellow ;;
esac
case "$SYSD_RESTART_HOLD" in
    ''|*[!0-9]*) SYSD_RESTART_HOLD=1800 ;;
esac

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# is_yes <value> -> true for the usual affirmative config spellings
is_yes() {
    case "${1:-}" in
        1|y|Y|yes|Yes|YES|true|True|TRUE|on|On|ON) return 0 ;;
    esac
    return 1
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

# raise <color> -- make <color> the column color if it is worse
raise() {
    case "$1" in
        red) WORST=red ;;
        yellow) [ "$WORST" = red ] || WORST=yellow ;;
    esac
}

# unit_name <name> -> the name with ".service" appended when it has no
# unit type suffix - the same default systemctl applies itself
unit_name() {
    case "$1" in
        *.*) printf '%s' "$1" ;;
        *)   printf '%s.service' "$1" ;;
    esac
}

# send_report <color> <status-body-file> [data-body-file]
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - systemd: ${SUMMARY:-$1}

$(cat "$2")"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            "$XYMON" "$XYMSRV" "data ${MACHINE}.${COLUMN}
$(cat "$3")"
        fi
    else
        # No Xymon environment: print the messages (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - systemd: ${SUMMARY:-$1}"
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

WORKDIR=$(mktemp -d "${XYMONTMP}/systemd.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

STATUS="$WORKDIR/status"
DATA="$WORKDIR/data"
ERR="$WORKDIR/err"
: > "$DATA"
SUMMARY=""

# short_report <color> <summary> <text> -- a report without metrics,
# for "not applicable" and "cannot query" cases. The text is wrapped in
# the NCV skip markers like every status here (see below).
short_report() {
    SUMMARY="$2"
    {
        printf '<!-- ncv_skipstart -->\n'
        printf '%s\n' "$3"
        printf '<!-- ncv_skipend -->\n'
    } > "$WORKDIR/short"
    send_report "$1" "$WORKDIR/short"
    exit 0
}

# err_text -> what systemctl printed on stderr, indented for the status
# page. Its own message says more than anything this script could.
err_text() {
    if [ -s "$ERR" ]; then
        sed 's/^/    /' "$ERR"
    else
        printf '    (no error message)\n'
    fi
}

# --- switched off in the config ---------------------------------------
if ! is_yes "$SYSD_ENABLE"; then
    short_report clear "disabled" \
"This test is switched off: SYSD_ENABLE=\"${SYSD_ENABLE}\" in systemd.cfg.
Set SYSD_ENABLE=\"yes\" to monitor systemd again, or comment out the task in
clientlaunch.d/systemd.cfg to remove this column for good."
fi

# --- is this host managed by systemd at all? --------------------------
# sd_booted(3): the system was booted with systemd if and only if
# /run/systemd/system exists. Checking for systemctl alone is not
# enough - it is installed in many containers without systemd as PID 1.
if [ -z "$SYSD_SYSTEMCTL" ]; then
    SYSD_SYSTEMCTL=$(command -v systemctl 2>/dev/null) || SYSD_SYSTEMCTL=""
fi
if [ ! -d "$SYSD_RUNDIR" ]; then
    short_report clear "not applicable" \
"This host is not managed by systemd ($(uname -s): no $SYSD_RUNDIR) - test not applicable."
fi
if [ -z "$SYSD_SYSTEMCTL" ] || [ ! -x "$SYSD_SYSTEMCTL" ]; then
    short_report clear "not applicable" \
"systemd is running, but systemctl was not found (set SYSD_SYSTEMCTL in systemd.cfg) - test not applicable."
fi

# sctl <args> -- systemctl, never through a pager (list-units adds
# --no-legend and --plain: no header/footer, no bullet before a unit)
sctl() {
    "$SYSD_SYSTEMCTL" --no-pager "$@"
}

# --- 1. overall system state ------------------------------------------
# is-system-running exits non-zero for every state but "running", so
# only its output counts. An empty output means the query itself failed.
SYSSTATE=$(sctl is-system-running 2>"$ERR")
SYSSTATE=$(printf '%s' "$SYSSTATE" | head -1)
case "$SYSSTATE" in
    offline)
        # The manager is not running as PID 1 - another init system is.
        short_report clear "not applicable" \
"systemctl reports \"offline\": systemd is not the service manager of this host - test not applicable."
        ;;
    "")
        short_report yellow "cannot query systemd" \
"&yellow systemctl is-system-running returned nothing:
$(err_text)"
        ;;
esac

WORST=green
case "$SYSSTATE" in
    running|degraded) STATECOLOR=green ;;   # degraded: see failed units
    initializing|starting|stopping) STATECOLOR="$SYSD_TRANSITION_COLOR" ;;
    maintenance) STATECOLOR=red ;;
    *) STATECOLOR=yellow ;;                  # "unknown" or anything new
esac
raise "$STATECOLOR"

# --- 2. all units, failed ones and the loaded services -----------------
# One call for everything: the failed units of every type, and the
# names of the loaded services for the restart check below.
# Columns with --plain: UNIT LOAD ACTIVE SUB DESCRIPTION...
if ! sctl list-units --all --no-legend --plain > "$WORKDIR/units" 2>"$ERR"; then
    # A query error must not downgrade a known maintenance state.
    raise yellow
    short_report "${WORST}" "cannot query systemd" \
"&${STATECOLOR} System state: ${SYSSTATE}

&yellow systemctl list-units failed:
$(err_text)"
fi

awk '$3 == "failed" { print }' "$WORKDIR/units" > "$WORKDIR/failed"
awk '$2 == "loaded" && $1 ~ /\.service$/ { print $1 }' "$WORKDIR/units" \
    > "$WORKDIR/services"

NFAILED=0          # failed units that count (graphed)
NIGNORED=0
FAILCOLOR=green    # worst color among them
{
    printf '\n'
    if [ -s "$WORKDIR/failed" ]; then
        printf 'Failed units:\n'
    else
        printf 'Failed units: none\n'
    fi
} > "$WORKDIR/failedtxt"
while read -r unit _load _active sub desc; do
    [ -n "$unit" ] || continue
    if [ -n "$SYSD_IGNORE" ] && match_any "$unit" "$SYSD_IGNORE"; then
        NIGNORED=$((NIGNORED + 1))
        printf '&clear %s  %s - ignored (SYSD_IGNORE)  %s\n' \
            "$unit" "$sub" "$desc" >> "$WORKDIR/failedtxt"
        continue
    fi
    NFAILED=$((NFAILED + 1))
    ucolor="$SYSD_FAILED_COLOR"
    if [ -n "$SYSD_WARN" ] && match_any "$unit" "$SYSD_WARN"; then
        ucolor=yellow
    fi
    raise "$ucolor"
    case "$ucolor" in
        red) FAILCOLOR=red ;;
        yellow) [ "$FAILCOLOR" = red ] || FAILCOLOR=yellow ;;
    esac
    printf '&%s %s  %s  %s\n' "$ucolor" "$unit" "$sub" "$desc" \
        >> "$WORKDIR/failedtxt"
done < "$WORKDIR/failed"

# --- 3. required units ---------------------------------------------------
# One systemctl call per unit: the list is short, and a single bad name
# then cannot take the result for all the others with it.
NDOWN=0
: > "$WORKDIR/reqtxt"
if [ -n "$SYSD_REQUIRED" ]; then
    printf '\nRequired units (SYSD_REQUIRED):\n' >> "$WORKDIR/reqtxt"
    # shellcheck disable=SC2086  # space-separated list on purpose
    for req in $SYSD_REQUIRED; do
        name=$(unit_name "$req")
        if ! sctl show -p Id -p LoadState -p ActiveState -p SubState \
                -p Description -- "$name" > "$WORKDIR/req" 2>"$ERR"; then
            NDOWN=$((NDOWN + 1))
            raise "$SYSD_DOWN_COLOR"
            printf '&%s %s  cannot be queried:\n%s\n' \
                "$SYSD_DOWN_COLOR" "$name" "$(err_text)" >> "$WORKDIR/reqtxt"
            continue
        fi
        # KEY=VALUE lines; the value may contain "=" itself.
        id=$(sed -n 's/^Id=//p' "$WORKDIR/req" | head -1)
        load=$(sed -n 's/^LoadState=//p' "$WORKDIR/req" | head -1)
        active=$(sed -n 's/^ActiveState=//p' "$WORKDIR/req" | head -1)
        sub=$(sed -n 's/^SubState=//p' "$WORKDIR/req" | head -1)
        desc=$(sed -n 's/^Description=//p' "$WORKDIR/req" | head -1)

        # An alias (Debian's ssh.service declares Alias=sshd.service)
        # resolves to the real unit; show both names then.
        shown="$name"
        [ -n "$id" ] && [ "$id" != "$name" ] && shown="$name (= $id)"

        if [ "$load" = "not-found" ]; then
            rcolor="$SYSD_DOWN_COLOR"
            state="not found - no such unit on this host"
            desc=""
        else
            state="${active:-?} (${sub:-?})"
            case "$active" in
                active|reloading|refreshing) rcolor=green ;;
                # Waiting for its next automatic restart is not "on the
                # way up" - the service is down.
                activating)
                    if [ "$sub" = "auto-restart" ]; then
                        rcolor="$SYSD_DOWN_COLOR"
                    else
                        rcolor=yellow
                    fi
                    ;;
                *) rcolor="$SYSD_DOWN_COLOR" ;;
            esac
        fi
        if [ "$rcolor" != green ]; then
            NDOWN=$((NDOWN + 1))
            raise "$rcolor"
        fi
        printf '&%s %s  %s%s\n' "$rcolor" "$shown" "$state" "${desc:+  $desc}" \
            >> "$WORKDIR/reqtxt"
    done
fi

# --- 4. automatic restarts ----------------------------------------------
STATEFILE="${XYMONTMP}/systemd.${MACHINE}.state"
NOW=$(date +%s)
HAVESTATE=no
PREV_TS=""
if [ -r "$STATEFILE" ]; then
    PREV_TS=$(awk '$1 == "T" { print $2; exit }' "$STATEFILE")
    case "$PREV_TS" in
        ''|*[!0-9]*) PREV_TS="" ;;
        *) HAVESTATE=yes ;;
    esac
fi

# NRestarts of every loaded service in one call. Output: one block of
# KEY=VALUE lines per unit, blocks separated by an empty line, the
# properties in systemctl's own order - so pair Id and NRestarts per
# block instead of relying on their order.
RESTARTS_OK=no
RESTARTS_QUERY_FAILED=no
: > "$WORKDIR/nrestarts"
if [ -s "$WORKDIR/services" ]; then
    # shellcheck disable=SC2046  # one argument per unit name on purpose;
    # unit names cannot contain white space or glob characters
    if sctl show -p Id -p NRestarts -- $(cat "$WORKDIR/services") \
            > "$WORKDIR/show" 2>"$ERR"; then
        awk -F= '
            function flush() {
                if (id != "" && nr ~ /^[0-9]+$/) print id, nr
                id = ""; nr = ""
            }
            /^$/            { flush(); next }
            $1 == "Id"        { id = substr($0, 4) }
            $1 == "NRestarts" { nr = substr($0, 11) }
            END             { flush() }' "$WORKDIR/show" > "$WORKDIR/nrestarts"
        # No NRestarts line at all: systemd older than 235.
        [ -s "$WORKDIR/nrestarts" ] && RESTARTS_OK=yes
    else
        RESTARTS_QUERY_FAILED=yes
        raise yellow
    fi
else
    # An empty, successfully queried unit list is a valid snapshot.
    RESTARTS_OK=yes
fi

# Compare with the previous poll. State file lines:
#   T <timestamp of the poll>
#   R <unit> <NRestarts> <time of the last restart seen> <restarts
#     counted since the hold window started>
#   H <unit> <last known NRestarts> <last restart time> <held count>
# H retains an unloaded unit's warning, but not its counter baseline:
# a newly loaded instance starts a new NRestarts counter.
# Event lines (written to "events"): every unit that restarted in this
# poll or is still inside its hold window:
#   <unit> <NRestarts> <delta this poll> <time of last restart> <count>
NEWSTATE="$WORKDIR/newstate"
printf 'T %s\n' "$NOW" > "$NEWSTATE"
: > "$WORKDIR/events"
# Run even after a query failure so earlier events remain visible.
# The resulting snapshot is committed only after a successful query.
awk -v sf="$STATEFILE" -v have="$HAVESTATE" -v now="$NOW" \
    -v hold="$SYSD_RESTART_HOLD" -v ns="$NEWSTATE" '
    BEGIN {
        if (have == "yes")
            while ((getline line < sf) > 0) {
                n = split(line, f, " ")
                if ((f[1] == "R" || f[1] == "H") && n >= 5) {
                    if (f[1] == "R") pn[f[2]] = f[3]
                    pc[f[2]] = f[3]; pts[f[2]] = f[4]; pacc[f[2]] = f[5]
                }
            }
    }
    {
        u = $1; c = $2 + 0; d = 0
        seen[u] = 1
        if (u in pn) {
            # Lower than before: reset in between (manual start,
            # reset-failed, reboot) - all of c happened after it.
            d = (c >= pn[u]) ? c - pn[u] : c
        } else if (have == "yes") {
            d = c           # unit is new since the previous poll
        }
        last = (u in pts) ? pts[u] + 0 : 0
        acc = (u in pacc) ? pacc[u] + 0 : 0
        if (d > 0) {
            if (last > 0 && now - last < hold) acc += d
            else acc = d
            last = now
        }
        print "R", u, c, last, acc >> ns
        if (d > 0 || (last > 0 && now - last < hold))
            print u, c, d, last, acc
    }
    END {
        # systemd may unload a stopped/transient unit. Keep its
        # already detected event until the hold expires, without
        # counting it again in the graph or retaining its baseline.
        for (u in pts)
            if (!(u in seen) && pts[u] > 0 && now - pts[u] < hold) {
                print "H", u, pc[u], pts[u], pacc[u] >> ns
                print u, pc[u], 0, pts[u], pacc[u]
            }
    }' "$WORKDIR/nrestarts" > "$WORKDIR/events"

NRESTARTS=0        # restarts since the previous poll (graphed)
NRESTARTED=0       # services shown in the restart list
: > "$WORKDIR/restarttxt"
if [ "$RESTARTS_OK" != yes ]; then
    # No property is expected on old systemd; a failed D-Bus call is
    # instead an incomplete check and has already raised the color.
    if [ "$RESTARTS_QUERY_FAILED" = yes ]; then
        printf '\n&yellow Automatic restarts: cannot query counters:\n' \
            >> "$WORKDIR/restarttxt"
        err_text >> "$WORKDIR/restarttxt"
    else
        printf '\nAutomatic restarts: not available - systemctl show -p NRestarts gave no counter (systemd older than 235)\n' \
            >> "$WORKDIR/restarttxt"
    fi
fi
if [ "$RESTARTS_OK" = yes ] || [ -s "$WORKDIR/events" ]; then
    HOLDMIN=$((SYSD_RESTART_HOLD / 60))
    printf '\nAutomatic restarts (Restart=), last %s min:\n' "$HOLDMIN" \
        >> "$WORKDIR/restarttxt"
    while read -r unit cnt delta last acc; do
        [ -n "$unit" ] || continue
        if [ -n "$SYSD_RESTART_IGNORE" ] && match_any "$unit" "$SYSD_RESTART_IGNORE"; then
            printf '&clear %s  %s restart(s) - ignored (SYSD_RESTART_IGNORE)\n' \
                "$unit" "$acc" >> "$WORKDIR/restarttxt"
            continue
        fi
        NRESTARTS=$((NRESTARTS + delta))
        NRESTARTED=$((NRESTARTED + 1))
        raise "$SYSD_RESTART_COLOR"
        age=$(( (NOW - last) / 60 ))
        printf '&%s %s  %s restart(s), the last one %s min ago (NRestarts=%s)\n' \
            "$SYSD_RESTART_COLOR" "$unit" "$acc" "$age" "$cnt" \
            >> "$WORKDIR/restarttxt"
    done < "$WORKDIR/events"
    [ "$NRESTARTED" -gt 0 ] || [ -s "$WORKDIR/events" ] ||
        printf 'none\n' >> "$WORKDIR/restarttxt"
    if [ "$HAVESTATE" = no ] && [ "$RESTARTS_OK" = yes ]; then
        printf '(first poll: the restart counters are recorded now, restarts show from the next poll on)\n' \
            >> "$WORKDIR/restarttxt"
    fi
fi

# Remember this run's counters (best effort - a read-only $XYMONTMP
# only disables the restart detection, it must not kill the report).
if [ "$RESTARTS_OK" = yes ]; then
    if cat "$NEWSTATE" > "${STATEFILE}.$$" 2>/dev/null; then
        mv "${STATEFILE}.$$" "$STATEFILE" 2>/dev/null || rm -f "${STATEFILE}.$$"
    fi
fi

# --- 5. report -------------------------------------------------------------
SUMMARY="${SYSSTATE}, ${NFAILED} failed unit(s)"
[ "$NIGNORED" -gt 0 ] && SUMMARY="${SUMMARY} (+${NIGNORED} ignored)"
[ -n "$SYSD_REQUIRED" ] && SUMMARY="${SUMMARY}, ${NDOWN} required unit(s) down"
[ "$NRESTARTED" -gt 0 ] && SUMMARY="${SUMMARY}, ${NRESTARTED} service(s) restarted"

# The whole status is for humans only - the metrics travel in the
# separate "data" message. xymond_rrd's NCV parser treats both ":" and
# "=" as a name/value separator, so without these markers a line like
# "Failed units: none" or "NRestarts=3" would end up in an RRD.
{
    printf '<!-- ncv_skipstart -->\n'
    # "degraded" itself is green above; show it in the color the
    # failed units gave the column instead.
    [ "$SYSSTATE" = degraded ] && STATECOLOR="$FAILCOLOR"
    printf '&%s System state: %s\n' "$STATECOLOR" "$SYSSTATE"
    case "$SYSSTATE" in
        degraded)
            [ "$NFAILED" -eq 0 ] &&
                printf '(degraded only because of ignored units - see SYSD_IGNORE)\n'
            ;;
        initializing|starting) printf '(the system is still booting)\n' ;;
        stopping) printf '(the system is shutting down)\n' ;;
        maintenance) printf '(rescue or emergency target active)\n' ;;
    esac
    cat "$WORKDIR/failedtxt" "$WORKDIR/reqtxt" "$WORKDIR/restarttxt"
    printf '<!-- ncv_skipend -->\n'
} > "$STATUS"

# Both values or none: plain NCV creates the RRD file with the datasets
# of the FIRST message it sees, so a message with "failed" only would
# leave the file without "restarts" for good. Restarts are only known
# from the second poll on.
if [ "$RESTARTS_OK" = yes ] && [ "$HAVESTATE" = yes ]; then
    printf 'failed : %s\nrestarts : %s\n' "$NFAILED" "$NRESTARTS" > "$DATA"
fi

send_report "$WORST" "$STATUS" "$DATA"
exit 0
