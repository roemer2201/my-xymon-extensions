#!/bin/sh
#
# procs.sh -- Xymon client extension: process checks ("procs" column)
#
# Collects the process list with ps - in exactly the format a full
# Xymon client uses where the host's ps allows it - and lets it be
# checked in one of two ways:
#
#   PROCS_MODE="server" (default)
#       Sends a minimal client message ("client HOST.OSTYPE" with the
#       [date] and [ps] sections) to the Xymon server. The server's
#       xymond_client evaluates the PROC rules of analysis.cfg against
#       it and builds the "procs" column itself - the same column, the
#       same rules, the same TRACK graphs as for a full client.
#
#   PROCS_MODE="local"
#       Evaluates PROC-style rules from procs.cfg (PROCS_RULES) on the
#       host and reports the "procs" column as a normal status
#       message, in the format xymond_client uses. For hosts whose
#       rules should not live in the server's analysis.cfg.
#
# The server finds the command in every ps line by the column offset
# of "CMD" (Linux) or "COMMAND" (FreeBSD) in the FIRST line, so the
# listing must be column-aligned. Linux procps-ng (also on TurrisOS)
# and FreeBSD ps deliver that with the full client's own command.
# BusyBox ps (stock OpenWrt) cannot run that command and does not
# align its command column, so its output is reformatted into fixed
# columns with a "CMD" header.
#
# Written for clientless hosts driven by the standalone runner
# (OpenWrt/TurrisOS): a full Xymon client already sends the process
# list with its own client message, so the shipped launch snippet is
# disabled by default - never enable both on one host.
#
# Configuration: environment variables and/or
# $XYMONHOME/etc/my-xymon-extensions/procs.cfg (see the shipped
# procs.cfg; the config file wins over the environment).

set -u

# Every number in a Xymon message must use a decimal point, and the
# awk character handling below must not depend on the locale.
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
# Defaults -- every value can be set in the environment or in procs.cfg
# ----------------------------------------------------------------------
PROCS_MODE="${PROCS_MODE:-server}"      # server | local
PROCS_COLUMN="${PROCS_COLUMN:-procs}"   # column of local mode and errors
PROCS_OSTYPE="${PROCS_OSTYPE:-}"        # server mode; empty = from ps
PROCS_CLASS="${PROCS_CLASS:-}"          # server mode client class
PROCS_RULES="${PROCS_RULES:-}"          # local mode PROC rules
PROCS_PSLIST="${PROCS_PSLIST:-yes}"     # local mode: append ps listing
PROCS_PSFORMAT="${PROCS_PSFORMAT:-auto}"    # see procs.cfg
PROCS_PS="${PROCS_PS:-ps}"              # the ps command

# Own subdirectory ($XYMONHOME/etc is shared with the Xymon server and
# hobbit-plugins); the old place of the other extensions' files is the
# fallback, as everywhere in this repository.
CFGFILE="${PROCS_CFG:-}"
if [ -z "$CFGFILE" ] && [ -n "$XYMONHOME" ]; then
    CFGFILE="$XYMONHOME/etc/my-xymon-extensions/procs.cfg"
    [ -f "$CFGFILE" ] || CFGFILE="$XYMONHOME/etc/procs.cfg"
fi
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi

# The full client's ps commands (client/xymonclient-linux.sh and
# client/xymonclient-freebsd.sh of Xymon 4.3.30).
PS_LINUX_COLS="pid,ppid,user,start,state,pri,pcpu,time:12,pmem,rsz:10,vsz:10,cmd"
PS_FREEBSD_COLS="pid,ppid,user,start,state,pri,pcpu,cputime,pmem,rss,vsz,command"

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# is_off <value> -- true for the usual spellings of "switched off"
is_off() {
    case "$1" in
        no|No|NO|off|Off|OFF|0|false|False|FALSE) return 0 ;;
    esac
    return 1
}

# send_status <color> <summary> <body-file>
send_status() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${PROCS_COLUMN} $1 $(date) - $2
$(cat "$3")"
    else
        # No Xymon environment: print the message (manual test run)
        echo "status ${MACHINE}.${PROCS_COLUMN} $1 $(date) - $2"
        cat "$3"
    fi
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

WORKDIR=$(mktemp -d "${XYMONTMP}/procs.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

# clear_report <text> - report "clear" in the procs column and stop.
clear_report() {
    printf '&clear %s\n' "$1" > "$WORKDIR/status"
    send_status clear "Processes not checked" "$WORKDIR/status"
    exit 0
}

case "$PROCS_MODE" in
    server|local) ;;
    *) clear_report "Unknown PROCS_MODE \"${PROCS_MODE}\" (use \"server\" or \"local\")." ;;
esac

if ! command -v "$PROCS_PS" >/dev/null 2>&1; then
    clear_report "ps not found on this host (looked for \"${PROCS_PS}\")."
fi

# --- collect the process list --------------------------------------------
#
# try_ps ARGS... -- run ps into ps.raw; true if it exited with 0 and
# printed a header line plus at least one process.
try_ps() {
    "$PROCS_PS" "$@" > "$WORKDIR/ps.raw" 2>/dev/null || return 1
    [ "$(sed -n '$=' "$WORKDIR/ps.raw")" -ge 2 ] 2>/dev/null
}

# header_is <ERE> -- true if the first line of ps.raw matches
header_is() {
    head -n 1 "$WORKDIR/ps.raw" | grep -Eq "$1"
}

# normalize <bb-o|bb-w> -- rewrite BusyBox ps output (ps.raw) into
# fixed columns with a "CMD" header (ps).
#
# The layouts are taken from procps/ps.c of BusyBox 1.36.1:
#  bb-o  "ps -o stat,pid,ppid,user,vsz,rss,args" (CONFIG_DESKTOP):
#        every column is padded to its width but grows past it, so the
#        command column wanders. STAT is always exactly three
#        characters and may contain blanks ("S  ", "S <", "SWN"), which
#        is why it is asked for first: it is cut off by position, the
#        rest is split on whitespace.
#  bb-w  plain "ps"/"ps ww" (no CONFIG_DESKTOP, the OpenWrt default):
#        printf("%5u %-8.8s %s %s  ") with VSZ in 5 and STAT in 3
#        characters, then the command - the PID can be wider than 5
#        characters, everything after it is fixed.
# Every field is cut to its column width, so the command starts at the
# same offset in every line, and the header's "CMD" sits right there.
normalize() {
    awk -v mode="$1" '
        function fit(s, w) { return substr(s, 1, w) }
        BEGIN {
            fmt = "%7s %7s %-8s %-4s %10s %10s %s\n"
            printf fmt, "PID", "PPID", "USER", "STAT", "VSZ", "RSS", "CMD"
        }
        NR == 1 { next }
        {
            if (mode == "bb-o") {
                st = substr($0, 1, 3)
                rest = substr($0, 4)
                if (!match(rest, /^ *[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/)) next
                cmd = substr(rest, RSTART + RLENGTH)
                split(substr(rest, 1, RLENGTH), f, " ")
                pid = f[1]; ppid = f[2]; user = f[3]; vsz = f[4]; rss = f[5]
            } else {
                if (!match($0, /^ *[0-9]+ /)) next
                pid = substr($0, 1, RLENGTH - 1)
                rest = substr($0, RLENGTH + 1)
                user = substr(rest, 1, 8)
                vsz = substr(rest, 10, 5)
                st = substr(rest, 16, 3)
                cmd = substr(rest, 21)
                ppid = "-"; rss = "-"
            }
            gsub(/ /, "", pid); gsub(/ /, "", user)
            gsub(/ /, "", vsz); gsub(/ /, "", st)
            if (pid !~ /^[0-9]+$/) next
            if (user == "") user = "-"
            if (st == "") st = "-"
            printf fmt, fit(pid, 7), fit(ppid, 7), fit(user, 8), \
                fit(st, 4), fit(vsz, 10), fit(rss, 10), cmd
        }
    ' "$WORKDIR/ps.raw" > "$WORKDIR/ps"
}

FORMAT="$PROCS_PSFORMAT"
if [ "$FORMAT" = "auto" ]; then
    case "$(uname -s)" in
        FreeBSD) FORMAT="freebsd" ;;
        *)       FORMAT="linux" ;;
    esac
fi

PSOS=""         # the client OS type the listing is formatted for
PSNOTE=""       # remark about the listing, shown in local mode
case "$FORMAT" in
    linux|procps|busybox|busybox-desktop)
        PSOS=linux
        PSFOUND=""
        case "$FORMAT" in linux|procps)
            # procps-ng: exactly the full client's command - first with
            # the process forest, then without it for a ps that lacks
            # the BSD-style "f".
            if try_ps -Aww f -o "$PS_LINUX_COLS" && header_is ' CMD *$'; then
                cp "$WORKDIR/ps.raw" "$WORKDIR/ps"
                PSFOUND=procps
            elif try_ps -Aww -o "$PS_LINUX_COLS" && header_is ' CMD *$'; then
                cp "$WORKDIR/ps.raw" "$WORKDIR/ps"
                PSFOUND=procps
            fi
            ;;
        esac
        case "$PSFOUND:$FORMAT" in :linux|:busybox-desktop)
            if try_ps -o stat,pid,ppid,user,vsz,rss,args &&
               header_is '^STAT +PID +PPID +USER +VSZ +RSS +COMMAND'; then
                normalize bb-o
                PSFOUND=busybox-desktop
            fi
            ;;
        esac
        case "$PSFOUND:$FORMAT" in :linux|:busybox)
            # "ww": unlimited width (FEATURE_PS_WIDE, on in OpenWrt);
            # without that feature ps accepts no options and cuts the
            # command line at 79 characters.
            if try_ps ww && header_is '^ *PID +USER +VSZ +STAT +COMMAND'; then
                normalize bb-w
                PSFOUND=busybox
            elif try_ps && header_is '^ *PID +USER +VSZ +STAT +COMMAND'; then
                normalize bb-w
                PSFOUND=busybox
                PSNOTE="This ps has no wide output - command lines are cut after about 79 characters."
            fi
            # A BusyBox ps without any options ignores "ww" and still
            # cuts every line at 79 characters.
            if [ "$PSFOUND" = busybox ] && [ -z "$PSNOTE" ] &&
               awk 'length($0) == 79 { f = 1 } END { exit !f }' "$WORKDIR/ps.raw"; then
                PSNOTE="Some ps lines end at exactly 79 characters - this ps may cut command lines (BusyBox without FEATURE_PS_WIDE)."
            fi
            ;;
        esac
        if [ -z "$PSFOUND" ]; then
            clear_report "\"${PROCS_PS}\" delivered no usable process list (format ${PROCS_PSFORMAT})."
        fi
        CMDHDR="CMD"
        ;;
    freebsd)
        PSOS=freebsd
        if try_ps -axd -ww -o "$PS_FREEBSD_COLS" && header_is ' COMMAND *$'; then
            cp "$WORKDIR/ps.raw" "$WORKDIR/ps"
        else
            clear_report "\"${PROCS_PS}\" delivered no usable process list (format freebsd)."
        fi
        CMDHDR="COMMAND"
        ;;
    *)
        clear_report "Unknown PROCS_PSFORMAT \"${PROCS_PSFORMAT}\"."
        ;;
esac

# --- server mode: hand the list to xymond_client ---------------------------
if [ "$PROCS_MODE" = "server" ]; then
    OSTYPE="${PROCS_OSTYPE:-$PSOS}"
    # Header line as written by the full client's xymonclient.sh:
    # "client HOST.OSTYPE [CLASS]". Hostname with commas, the server
    # splits the OS type off at the last dot.
    MSG="client ${MACHINE}.${OSTYPE}${PROCS_CLASS:+ $PROCS_CLASS}
[date]
$(date)
[ps]
$(cat "$WORKDIR/ps")"
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        # The server answers a client message with the host's section
        # of client-local.cfg; nothing here uses it.
        if ! "$XYMON" "$XYMSRV" "$MSG" > /dev/null; then
            echo "$0: sending the client message failed" >&2
            exit 1
        fi
    else
        printf '%s\n' "$MSG"
    fi
    exit 0
fi

# --- local mode: evaluate the PROC rules here ------------------------------
#
# Mirrors unix_procs_report() (xymond/xymond_client.c) and the PROC
# rule parser (xymond/client_config.c) of Xymon 4.3.30:
#  - the command of every ps line - the header included, as on the
#    server - starts at the offset of CMDHDR in the header line;
#  - a plain NAME counts the lines whose command contains it, a
#    "%REGEX" (here: POSIX ERE, not PCRE) is matched after leading
#    blanks, "|", "\" and "_" of a process forest are skipped;
#  - "NAME [MIN [MAX [COLOR]]]", "min=", "max=", "color=", "TEXT=";
#    defaults MIN 1, MAX unlimited, COLOR red; an explicit max= lower
#    than the minimum lowers the minimum; MAX 0 with a MIN > 0 means
#    unlimited;
#  - a rule is in its color if fewer than MIN (MIN > 0) or more than
#    MAX (MAX set) processes match; the column takes the worst color.
#
# With phase=check the program only parses the rules and prints the
# regular expressions, one per line; with phase=eval it reads the ps
# listing as well and prints the check lines (the color goes to
# colorfile).
# shellcheck disable=SC2016  # an awk program, not shell expansions
PROCS_AWK='
    function rank(c) {
        return (c == "red") ? 5 : (c == "yellow") ? 4 : (c == "clear") ? 1 : 0
    }
    # tokens(line) -- split like wstok() of lib/misc.c: blanks separate
    # tokens, a double-quoted part may contain blanks, one leading and
    # one trailing quote are stripped. Fills tok[1..n], returns n.
    function tokens(line,    n, i, c, t, inq) {
        n = 0; t = ""; inq = 0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (c == "\"") { inq = !inq; t = t c; continue }
            if (!inq && (c == " " || c == "\t")) {
                if (t != "") { tok[++n] = t; t = "" }
                continue
            }
            t = t c
        }
        if (t != "") tok[++n] = t
        for (i = 1; i <= n; i++) {
            sub(/^"/, "", tok[i]); sub(/"$/, "", tok[i])
        }
        return n
    }
    FILENAME == rulesfile {
        if ($0 ~ /^[ \t]*(#|$)/) next
        n = tokens($0)
        r = ++nrules
        name[r] = tok[1]; pmin[r] = 1; pmax[r] = -1; col[r] = "red"
        text[r] = ""; cnt[r] = 0
        idx = 0; qual = 0
        for (i = 2; i <= n; i++) {
            t = tok[i]; lt = tolower(t)
            if (lt ~ /^text=/) { text[r] = substr(t, 6); qual = 1; continue }
            if (lt ~ /^(host|exhost|page|expage|dgroup|exdgroup|class|exclass|group|time|extime)=/) {
                qual = 1; continue
            }
            if (qual) continue
            if (lt ~ /^min=/) pmin[r] = substr(t, 5) + 0
            else if (lt ~ /^max=/) {
                pmax[r] = substr(t, 5) + 0
                if (pmax[r] < pmin[r]) pmin[r] = pmax[r]
            }
            else if (lt ~ /^color=/) col[r] = tolower(substr(t, 7))
            else if (lt ~ /^track/) continue
            else if (idx == 0) { pmin[r] = t + 0; idx++ }
            else if (idx == 1) { pmax[r] = t + 0; idx++ }
            else if (idx == 2) { col[r] = lt; idx++ }
        }
        if (col[r] !~ /^(green|yellow|red|clear)$/) col[r] = "red"
        if (pmin[r] && pmax[r] == 0) pmax[r] = -1
        if (phase == "check" && substr(name[r], 1, 1) == "%")
            print substr(name[r], 2)
        next
    }
    FNR == 1 {
        cmdofs = index($0, cmdhdr) - 1
        if (cmdofs < 0) { nohdr = 1; exit }
    }
    length($0) > cmdofs {
        pname = substr($0, cmdofs + 1)
        stripped = pname
        sub(/^[ |\\_]+/, "", stripped)
        for (r = 1; r <= nrules; r++) {
            if (substr(name[r], 1, 1) == "%") {
                if (stripped ~ substr(name[r], 2)) cnt[r]++
            } else if (index(pname, name[r]) > 0) {
                cnt[r]++
            }
        }
    }
    END {
        if (phase == "check") exit
        color = "green"
        if (nohdr) {
            color = "yellow"
            printf "&yellow Expected string %s not found in ps output header\n", cmdhdr
        } else if (nrules == 0) {
            color = "clear"
            print "&clear No process checks defined"
        } else {
            for (r = 1; r <= nrules; r++) {
                if (pmax[r] == -1) {
                    lim = (pmin[r] > 0) ? pmin[r] " or more" : "none"
                } else {
                    lim = (pmin[r] > 0) ? "between " pmin[r] " and " pmax[r] \
                                        : "at most " pmax[r]
                }
                c = "green"
                if (pmin[r] != 0 && cnt[r] < pmin[r]) c = col[r]
                if (pmax[r] != -1 && cnt[r] > pmax[r]) c = col[r]
                if (rank(c) > rank(color)) color = c
                printf "&%s %s (found %d, req. %s)\n", c, \
                    (text[r] != "") ? text[r] : name[r], cnt[r], lim
            }
        }
        print color > colorfile
    }
'

printf '%s\n' "$PROCS_RULES" > "$WORKDIR/rules"

# An invalid regular expression stops mawk and BWK awk with an error,
# while BusyBox awk silently matches nothing. Check every one with
# grep -E first (exit code 2 = invalid, the same with GNU, BSD and
# BusyBox grep), so the result does not depend on the awk at hand.
if ! awk -v phase=check -v rulesfile="$WORKDIR/rules" "$PROCS_AWK" \
        "$WORKDIR/rules" > "$WORKDIR/regexes" 2> "$WORKDIR/awk.err"; then
    clear_report "The PROC rules in PROCS_RULES could not be read: $(tr '\n' ' ' < "$WORKDIR/awk.err")"
fi
while IFS= read -r re; do
    printf 'x\n' | grep -E -e "$re" >/dev/null 2>&1
    if [ $? -eq 2 ]; then
        clear_report "The PROC rules in PROCS_RULES could not be evaluated: invalid regular expression \"%${re}\" (POSIX ERE)."
    fi
done < "$WORKDIR/regexes"

if ! awk -v phase=eval -v rulesfile="$WORKDIR/rules" -v cmdhdr="$CMDHDR" \
        -v colorfile="$WORKDIR/color" "$PROCS_AWK" \
        "$WORKDIR/rules" "$WORKDIR/ps" > "$WORKDIR/checks" 2> "$WORKDIR/awk.err"; then
    clear_report "The PROC rules in PROCS_RULES could not be evaluated: $(tr '\n' ' ' < "$WORKDIR/awk.err")"
fi
COLOR=$(cat "$WORKDIR/color" 2>/dev/null)
case "$COLOR" in
    green|yellow|red|clear) ;;
    *) clear_report "The PROC rules in PROCS_RULES could not be evaluated." ;;
esac

{
    cat "$WORKDIR/checks"
    printf '\n'
    if ! is_off "$PROCS_PSLIST"; then
        # The listing as the server quotes it (prehtmlquoted()).
        sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$WORKDIR/ps"
    fi
    [ -n "$PSNOTE" ] && printf '\n%s\n' "$PSNOTE"
} > "$WORKDIR/final"

case "$COLOR" in
    red|yellow) SUMMARY="Processes NOT ok" ;;
    *)          SUMMARY="Processes ok" ;;
esac
send_status "$COLOR" "$SUMMARY" "$WORKDIR/final"
exit 0
