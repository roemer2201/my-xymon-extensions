#!/bin/sh
#
# claude.sh -- Xymon client extension: Claude Code login status
#
# Reports whether the Claude Code login of one or more accounts on this
# host is still valid, in a single "claude" column.
#
# What is actually checked is the refresh token: Claude Code stores two
# expiry timestamps in $HOME/.claude/.credentials.json, and only one of
# them says how long the login lasts.
#
#   expiresAt             the access token - valid for hours and
#                         renewed automatically whenever Claude runs.
#                         An expired one is normal on an idle host, so
#                         it is reported as information only.
#   refreshTokenExpiresAt THE LOGIN. When this passes, nothing renews
#                         itself any more and somebody has to run
#                         "claude /login" interactively on the host.
#
# That is what makes the check worth having: a long running headless
# session (claude --remote-control in a service, a cron job, an agent)
# dies silently when the refresh token expires, and the repair needs a
# human at a terminal. The default thresholds give ten days' warning.
#
# The credentials file is mode 0600 in a private home directory, so the
# unprivileged Xymon client cannot read it. All reading happens in
# claude-expiry.sh, which is called through sudo and prints timestamps
# only - see sudoers.example. Where no sudo rule exists the column
# reports "clear" with a hint instead of turning red.
#
# usage: claude.sh [-h|--help]
#
# Program flow:
#   1. load the configuration (environment, then claude.cfg)
#   2. decide how the helper is called (root, own account, or sudo)
#   3. for every configured account: run the helper, evaluate the
#      remaining lifetime of the refresh token against the thresholds
#   4. combine the per-account colors into the column color
#   5. send the status message
#
# Configuration: environment variables and/or $XYMONHOME/etc/claude.cfg
# (see the shipped claude.cfg; the config file wins over the
# environment).

set -u

# Every number in a Xymon message must use a decimal point. awk formats
# floating point numbers according to LC_NUMERIC, so under a locale
# like de_DE the metrics would come out as "14,9" - which the server's
# NCV parser silently drops.
LC_ALL=C
export LC_ALL

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
usage: claude.sh [-h|--help]

Xymon client extension: reports the remaining validity of the Claude
Code login (the refresh token in $HOME/.claude/.credentials.json) of
every account listed in CLAUDE_ACCOUNTS, in one "claude" column.
Yellow below CLAUDE_WARN days, red below CLAUDE_CRIT days.

Without a Xymon environment ($XYMON/$XYMSRV) the status message is
printed to stdout instead of being sent - use that to test.
EOF
        exit 0
        ;;
esac

# ----------------------------------------------------------------------
# Xymon environment (xymonlaunch or standalone/xymon-run.sh provide
# these; fallbacks allow running the script manually for testing:
# output then goes to stdout)
# ----------------------------------------------------------------------
XYMONHOME="${XYMONHOME:-${XYMONCLIENTHOME:-}}"
XYMONTMP="${XYMONTMP:-${TMPDIR:-/tmp}}"
MACHINE="${MACHINE:-$(uname -n | tr '.' ',')}"

# ----------------------------------------------------------------------
# Defaults -- every value can be set in the environment or in claude.cfg
# ----------------------------------------------------------------------
CLAUDE_COLUMN="${CLAUDE_COLUMN:-claude}"    # Xymon column name
CLAUDE_ACCOUNTS="${CLAUDE_ACCOUNTS:-root}"  # accounts to check
CLAUDE_WARN="${CLAUDE_WARN:-10}"            # yellow at/below N days left
CLAUDE_CRIT="${CLAUDE_CRIT:-5}"             # red at/below N days left
CLAUDE_HELPER="${CLAUDE_HELPER:-}"          # empty: next to this script
CLAUDE_SUDO="${CLAUDE_SUDO:-auto}"          # auto|yes|no

CFGFILE="${CLAUDE_CFG:-${XYMONHOME:+${XYMONHOME}/etc/claude.cfg}}"
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi
COLUMN="$CLAUDE_COLUMN"

# Non-numeric thresholds would blow up the arithmetic below; fall back
# to the built-in defaults instead.
case "$CLAUDE_WARN" in ''|*[!0-9]*) CLAUDE_WARN=10 ;; esac
case "$CLAUDE_CRIT" in ''|*[!0-9]*) CLAUDE_CRIT=5 ;; esac

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# worst <color1> <color2> -> prints the more severe of the two
worst() {
    for w_c in red yellow green clear; do
        if [ "$1" = "$w_c" ] || [ "$2" = "$w_c" ]; then
            echo "$w_c"
            return
        fi
    done
    echo green
}

# send_report <color> <summary> <body-file>
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - $2

$(cat "$3")"
    else
        # No Xymon environment: print the message (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - $2"
        echo ""
        cat "$3"
    fi
}

# fmt_date <epoch seconds> -> human readable timestamp
#
# GNU and BusyBox date take "-d @epoch", FreeBSD takes "-r epoch", and
# they are tried in that order on purpose: GNU "date -r" means "the
# mtime of this file" and would print today's date for a number.
fmt_date() {
    date -d "@$1" '+%Y-%m-%d %H:%M %Z' 2>/dev/null && return 0
    date -r "$1" '+%Y-%m-%d %H:%M %Z' 2>/dev/null && return 0
    echo "epoch $1"
}

# to_seconds <number> -> epoch seconds (the credentials file stores
# milliseconds; a plain epoch is accepted as well, should that change)
to_seconds() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    if [ "${#1}" -ge 12 ]; then
        echo $(( $1 / 1000 ))
    else
        echo "$1"
    fi
}

# field <key> <helper-output> -> value of that key=value line
field() {
    printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

WORKDIR=$(mktemp -d "${XYMONTMP}/claude.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

clear_report() {
    printf '%s\n' "$1" > "$WORKDIR/status"
    send_report clear "login check not applicable" "$WORKDIR/status"
    exit 0
}

# --- locate the privileged helper ---------------------------------------
if [ -z "$CLAUDE_HELPER" ]; then
    SELFDIR=$(dirname "$0")
    if [ -x "$SELFDIR/claude-expiry.sh" ]; then
        CLAUDE_HELPER="$SELFDIR/claude-expiry.sh"
    elif [ -n "$XYMONHOME" ] && [ -x "$XYMONHOME/ext/claude-expiry.sh" ]; then
        CLAUDE_HELPER="$XYMONHOME/ext/claude-expiry.sh"
    fi
fi
if [ -z "$CLAUDE_HELPER" ] || [ ! -x "$CLAUDE_HELPER" ]; then
    clear_report "claude-expiry.sh not found next to this script or in \$XYMONHOME/ext - the extension is installed incompletely."
fi
# sudo matches the command path literally, so hand it an absolute one.
case "$CLAUDE_HELPER" in
    /*) ;;
    *)  CLAUDE_HELPER="$(pwd)/$CLAUDE_HELPER" ;;
esac

# --- privileges ---------------------------------------------------------
# Reading another account's credentials file needs root. Running as
# root (standalone runner from cron, OpenWrt) needs no sudo at all, and
# neither does an account asking about itself.
MYUID=$(id -u)
MYNAME=$(id -un 2>/dev/null || echo "")
case "$CLAUDE_SUDO" in
    no)  SUDO="" ;;
    yes) SUDO="sudo -n" ;;
    *)   if [ "$MYUID" -eq 0 ]; then SUDO=""; else SUDO="sudo -n"; fi ;;
esac

run_helper() { # run_helper <account> -> key=value lines
    if [ -z "$SUDO" ] || [ "$1" = "$MYNAME" ]; then
        "$CLAUDE_HELPER" "$1" 2>/dev/null
    else
        # shellcheck disable=SC2086  # $SUDO is intentionally word-split
        $SUDO "$CLAUDE_HELPER" "$1" 2>/dev/null
    fi
}

NOW=$(date +%s)
WARNSECS=$(( CLAUDE_WARN * 86400 ))
CRITSECS=$(( CLAUDE_CRIT * 86400 ))

OVERALL=clear          # stays clear while no account has a login at all
SUMMARY=""
SUMMARY_RANK=4         # 0 red, 1 yellow, 2 green, 3 clear, 4 nothing yet
CHECKED=0
: > "$WORKDIR/body"

# summarize <rank> <text> - keeps the most severe account for the
# first line of the status message
summarize() {
    if [ "$1" -lt "$SUMMARY_RANK" ]; then
        SUMMARY_RANK=$1
        SUMMARY=$2
    fi
}

for ACCT in $CLAUDE_ACCOUNTS; do
    CHECKED=$(( CHECKED + 1 ))
    OUT=$(run_helper "$ACCT")
    STATUS=$(field status "$OUT")
    CREDPATH=$(field path "$OUT")

    if [ -z "$STATUS" ]; then
        # No output at all: the helper could not be run. By far the most
        # likely reason is a missing sudo rule, which is a setup step,
        # not a fault of the monitored host - hence clear, not red.
        printf '&clear %s - cannot read the login state\n' "$ACCT" >> "$WORKDIR/body"
        printf '       %s could not be run as root (passwordless sudo missing? see sudoers.example)\n' \
            "$CLAUDE_HELPER" >> "$WORKDIR/body"
        summarize 3 "login state of $ACCT cannot be read"
        continue
    fi

    case "$STATUS" in
        nouser)
            printf '&yellow %s - no such account on this host (check CLAUDE_ACCOUNTS)\n' \
                "$ACCT" >> "$WORKDIR/body"
            OVERALL=$(worst "$OVERALL" yellow)
            summarize 1 "no account named $ACCT"
            continue
            ;;
        nofile)
            printf '&clear %s - no Claude Code login (%s does not exist)\n' \
                "$ACCT" "$CREDPATH" >> "$WORKDIR/body"
            summarize 3 "no Claude Code login on this host"
            continue
            ;;
        noread)
            printf '&clear %s - %s exists but is not readable\n' \
                "$ACCT" "$CREDPATH" >> "$WORKDIR/body"
            summarize 3 "login state of $ACCT cannot be read"
            continue
            ;;
        badfile)
            printf '&yellow %s - %s carries no refreshTokenExpiresAt field\n' \
                "$ACCT" "$CREDPATH" >> "$WORKDIR/body"
            printf '        the login was never completed, or the file was caught mid-rewrite\n' \
                >> "$WORKDIR/body"
            OVERALL=$(worst "$OVERALL" yellow)
            summarize 1 "login state of $ACCT is unclear"
            continue
            ;;
    esac

    REFRESH=$(field refreshexpires "$OUT")
    REFRESH_S=$(to_seconds "$REFRESH") || REFRESH_S=""
    if [ -z "$REFRESH_S" ]; then
        printf '&yellow %s - unusable expiry timestamp in %s\n' \
            "$ACCT" "$CREDPATH" >> "$WORKDIR/body"
        OVERALL=$(worst "$OVERALL" yellow)
        summarize 1 "login state of $ACCT is unclear"
        continue
    fi

    LEFT=$(( REFRESH_S - NOW ))
    DAYS=$(( LEFT / 86400 ))
    WHEN=$(fmt_date "$REFRESH_S")
    SUB=$(field subscription "$OUT")
    [ -n "$SUB" ] && SUB=" [$SUB]"

    if [ "$LEFT" -le 0 ]; then
        COLOR=red
        printf '&red %s - login EXPIRED %d day(s) ago, on %s%s\n' \
            "$ACCT" "$(( -DAYS ))" "$WHEN" "$SUB" >> "$WORKDIR/body"
        summarize 0 "$ACCT: login expired"
    elif [ "$LEFT" -le "$CRITSECS" ]; then
        COLOR=red
        printf '&red %s - login valid for %d more day(s), until %s%s\n' \
            "$ACCT" "$DAYS" "$WHEN" "$SUB" >> "$WORKDIR/body"
        summarize 0 "$ACCT: login expires in $DAYS day(s)"
    elif [ "$LEFT" -le "$WARNSECS" ]; then
        COLOR=yellow
        printf '&yellow %s - login valid for %d more day(s), until %s%s\n' \
            "$ACCT" "$DAYS" "$WHEN" "$SUB" >> "$WORKDIR/body"
        summarize 1 "$ACCT: login expires in $DAYS day(s)"
    else
        COLOR=green
        printf '&green %s - login valid for %d more day(s), until %s%s\n' \
            "$ACCT" "$DAYS" "$WHEN" "$SUB" >> "$WORKDIR/body"
        summarize 2 "$ACCT: login valid for $DAYS day(s)"
    fi
    OVERALL=$(worst "$OVERALL" "$COLOR")

    # The access token is renewed automatically whenever Claude runs, so
    # an expired one says nothing about the login - information only.
    ACCESS=$(field expires "$OUT")
    ACCESS_S=$(to_seconds "$ACCESS") || ACCESS_S=""
    if [ -n "$ACCESS_S" ]; then
        if [ "$ACCESS_S" -le "$NOW" ]; then
            printf '       access token expired %s, renewed at the next Claude run\n' \
                "$(fmt_date "$ACCESS_S")" >> "$WORKDIR/body"
        else
            printf '       access token valid until %s (renewed automatically)\n' \
                "$(fmt_date "$ACCESS_S")" >> "$WORKDIR/body"
        fi
    fi
done

if [ "$CHECKED" -eq 0 ]; then
    clear_report "CLAUDE_ACCOUNTS is empty - nothing to check."
fi

{
    printf '\n'
    printf '&clear Thresholds: yellow at %d day(s) left, red at %d day(s).\n' \
        "$CLAUDE_WARN" "$CLAUDE_CRIT"
    printf '&clear Checked account(s): %s\n' "$CLAUDE_ACCOUNTS"
    if [ "$OVERALL" = red ] || [ "$OVERALL" = yellow ]; then
        printf '&clear A login is renewed by running "claude /login" as that account -\n'
        printf '&clear interactively, it cannot be automated.\n'
    fi
} >> "$WORKDIR/body"

[ -n "$SUMMARY" ] || SUMMARY="login status"
send_report "$OVERALL" "$SUMMARY" "$WORKDIR/body"
exit 0
