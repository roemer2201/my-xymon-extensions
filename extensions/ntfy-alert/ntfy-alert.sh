#!/bin/sh
#
# ntfy-alert.sh -- Xymon alert script: push notifications via ntfy
#
# Sends Xymon alerts as push notifications to an ntfy server
# (https://ntfy.sh/ or self-hosted). Publishing to ntfy is a plain
# HTTP POST, so curl does the job - no ntfy client software needed.
#
# Unlike the other extensions in this repository this is NOT a client
# test: it reports no column and is not started by xymonlaunch.
# xymond_alert on the Xymon SERVER runs it through a SCRIPT rule in
# alerts.cfg, e.g.:
#
#   HOST=*
#       SCRIPT /usr/lib/xymon/client/ext/ntfy-alert.sh xymon COLOR=red,yellow
#
# The recipient (the word after the script path; xymond_alert passes
# it as the first argument and in $RCPT) is the ntfy topic. A full
# URL (https://ntfy.example.org/topic) as recipient overrides
# NTFY_URL from the config, so different rules can target different
# servers. Everything else about the alert arrives in the environment
# variables that xymond_alert(8) documents (BBALPHAMSG, BBHOSTNAME,
# BBSVCNAME, BBCOLORLEVEL, RECOVERED, ...).
#
# Configuration: $XYMONHOME/etc/ntfy-alert.cfg (override the location
# with NTFY_CFG, e.g. in xymonserver.cfg when the server's XYMONHOME
# differs from the directory this package installs into). The ntfy
# server URL and an access token are required; anything missing is an
# error on stderr - xymond_alert captures that in its own log.

set -u

XYMONHOME="${XYMONHOME:-${XYMONCLIENTHOME:-}}"
XYMONTMP="${XYMONTMP:-${TMPDIR:-/tmp}}"

# ----------------------------------------------------------------------
# Defaults -- every value can be overridden in ntfy-alert.cfg
# ----------------------------------------------------------------------
CURL="${CURL:-}"                        # path to curl; empty = search $PATH
NTFY_URL="${NTFY_URL:-}"                # base URL of the ntfy server
NTFY_TOKEN="${NTFY_TOKEN:-}"            # ntfy access token (tk_...)
NTFY_TOKEN_FILE="${NTFY_TOKEN_FILE:-}"  # alternative: token from a file
NTFY_CLICKURL="${NTFY_CLICKURL:-}"      # svcstatus.sh CGI for tap-to-open
NTFY_MAXCHARS="${NTFY_MAXCHARS:-3500}"  # body limit (ntfy default: 4096 bytes)
NTFY_PRIO_RED="${NTFY_PRIO_RED:-high}"
NTFY_PRIO_YELLOW="${NTFY_PRIO_YELLOW:-default}"
NTFY_PRIO_RECOVERED="${NTFY_PRIO_RECOVERED:-low}"
TIMEOUT="${TIMEOUT:-15}"                # seconds for the whole request

CFGFILE="${NTFY_CFG:-${XYMONHOME:+${XYMONHOME}/etc/ntfy-alert.cfg}}"
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi

err() {
    echo "ntfy-alert: $*" >&2
    exit 1
}

# ----------------------------------------------------------------------
# The alert (from xymond_alert's environment and the recipient)
# ----------------------------------------------------------------------
TOPIC="${1:-${RCPT:-}}"
HOST="${BBHOSTNAME:-unknown}"
SVC="${BBSVCNAME:-unknown}"
COLOR="${BBCOLORLEVEL:-unknown}"

if [ -z "$TOPIC" ]; then
    err "no ntfy topic - pass it as the SCRIPT recipient in alerts.cfg"
fi

# Map the alert type to an ntfy priority and tag (= emoji). RECOVERED
# is 1 for recovery messages; newer Xymon versions use 2 when a test
# was disabled.
case "${RECOVERED:-0}" in
    1)
        EVENT="recovered"
        PRIORITY="$NTFY_PRIO_RECOVERED"
        TAGS="white_check_mark"
        ;;
    2)
        EVENT="disabled"
        PRIORITY="$NTFY_PRIO_RECOVERED"
        TAGS="no_bell"
        ;;
    *)
        EVENT="is $(printf '%s' "$COLOR" | tr '[:lower:]' '[:upper:]')"
        case "$COLOR" in
            red)    PRIORITY="$NTFY_PRIO_RED"    TAGS="red_circle" ;;
            yellow) PRIORITY="$NTFY_PRIO_YELLOW" TAGS="yellow_circle" ;;
            purple) PRIORITY="$NTFY_PRIO_YELLOW" TAGS="purple_circle" ;;
            *)      PRIORITY="default"           TAGS="bell" ;;
        esac
        ;;
esac
TITLE="$HOST : $SVC $EVENT"

# ----------------------------------------------------------------------
# Credentials and target URL
# ----------------------------------------------------------------------
if [ -n "$NTFY_TOKEN_FILE" ]; then
    if [ ! -r "$NTFY_TOKEN_FILE" ]; then
        err "cannot read NTFY_TOKEN_FILE ($NTFY_TOKEN_FILE)"
    fi
    NTFY_TOKEN=$(cat "$NTFY_TOKEN_FILE")
fi
if [ -z "$NTFY_TOKEN" ]; then
    err "no ntfy token - set NTFY_TOKEN or NTFY_TOKEN_FILE in ${CFGFILE:-ntfy-alert.cfg}"
fi

case "$TOPIC" in
    http://*|https://*)
        URL=$TOPIC
        ;;
    *)
        if [ -z "$NTFY_URL" ]; then
            err "NTFY_URL is not set in ${CFGFILE:-ntfy-alert.cfg} and the recipient '$TOPIC' is not a full URL"
        fi
        URL="${NTFY_URL%/}/$TOPIC"
        ;;
esac

if [ -z "$CURL" ]; then
    CURL=$(command -v curl || true)
fi
if [ -z "$CURL" ] || [ ! -x "$CURL" ]; then
    err "curl not found - install curl to send ntfy notifications"
fi

# ----------------------------------------------------------------------
# Build and publish the notification
# ----------------------------------------------------------------------
WORKDIR=$(mktemp -d "${XYMONTMP}/ntfy-alert.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

# Body: the full alert text, truncated to the ntfy message size limit.
{
    printf '%s\n' "${BBALPHAMSG:-$TITLE}"
    [ -n "${DOWNSECSMSG:-}" ] && printf '\n%s\n' "$DOWNSECSMSG"
    [ -n "${ACKCODE:-}" ] && printf '\nAcknowledge code: %s\n' "$ACKCODE"
} | awk -v maxc="$NTFY_MAXCHARS" '
    { out = out $0 "\n" }
    END {
        if (length(out) > maxc)
            out = substr(out, 1, maxc) "\n[... truncated ...]\n"
        printf "%s", out
    }' > "$WORKDIR/body"

# The token goes through "curl --config -" on stdin, not the command
# line, so it never shows up in the process list. The optional click
# URL travels the same way.
HTTPCODE=$({
        printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN"
        [ -n "$NTFY_CLICKURL" ] && \
            printf 'header = "X-Click: %s?HOST=%s&SERVICE=%s"\n' \
                "$NTFY_CLICKURL" "$HOST" "$SVC"
    } | "$CURL" --silent --show-error --config - \
        --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
        --output "$WORKDIR/resp" --write-out '%{http_code}' \
        --header "X-Title: $TITLE" \
        --header "X-Priority: $PRIORITY" \
        --header "X-Tags: $TAGS" \
        --data-binary "@$WORKDIR/body" \
        "$URL" 2>"$WORKDIR/curlerr")
rc=$?

if [ "$rc" -ne 0 ]; then
    CURLERR=$(cat "$WORKDIR/curlerr" 2>/dev/null)
    err "cannot reach the ntfy server at $URL - ${CURLERR:-curl exited with $rc}"
fi
case "$HTTPCODE" in
    2??) ;;
    401|403)
        err "the ntfy server at $URL rejected the token (HTTP $HTTPCODE) - check NTFY_TOKEN and the topic's access rights"
        ;;
    *)
        err "ntfy publish to $URL failed (HTTP $HTTPCODE): $(head -n 1 "$WORKDIR/resp" 2>/dev/null)"
        ;;
esac

exit 0
