#!/bin/sh
#
# fritzdsl.sh -- Xymon extension: AVM FRITZ!Box DSL line monitoring
#
# Polls a FRITZ!Box over its TR-064 SOAP interface (curl, HTTP digest
# auth) and reports the DSL line as one Xymon column attached to the
# box's own host entry:
#
#   - status color: red when the DSL line is down or the box is
#     unreachable, yellow/red when the noise margin falls below the
#     configured thresholds or the CRC error rate rises,
#   - a "data" message with "NAME : VALUE" lines for RRD graphing
#     (split-NCV on the Xymon server, see server/README.md).
#
# The poller runs on the Xymon server itself (or any host that can
# reach the box) - no software is installed on the FRITZ!Box.
# Configuration: $XYMONHOME/etc/fritzdsl.cfg. Credentials are
# required; without them the extension exits silently, so it is
# harmless when installed but not configured (the shipped launch
# snippet is additionally DISABLED by default).

set -u

# Every number in a Xymon message must use a decimal point. awk formats
# floating point numbers according to LC_NUMERIC, so under a locale
# like de_DE the metrics would come out as "14,9" - which the server's
# NCV parser silently drops.
LC_ALL=C
export LC_ALL

COLUMN="fritzdsl"

# ----------------------------------------------------------------------
# Xymon environment (xymonlaunch provides these; fallbacks allow running
# the script manually for testing: output then goes to stdout)
# ----------------------------------------------------------------------
XYMONHOME="${XYMONHOME:-${XYMONCLIENTHOME:-}}"
XYMONTMP="${XYMONTMP:-${TMPDIR:-/tmp}}"

# ----------------------------------------------------------------------
# Defaults -- every value can be overridden in fritzdsl.cfg
# ----------------------------------------------------------------------
CURL=""                    # path to curl; empty = search $PATH
FRITZ_HOST="fritz.box"     # FRITZ!Box address (name or IP)
FRITZ_PORT="49000"         # TR-064 port
FRITZ_USER=""              # FRITZ!Box user with TR-064 access
FRITZ_PASSWORD=""          # ... and its password
FRITZ_PASSWORD_FILE=""     # alternative: read the password from a file
REPORTHOST=""              # Xymon host to report as; empty = FRITZ_HOST
TIMEOUT=15                 # seconds per SOAP request
WAN_SERVICE="auto"         # WAN uptime source: auto | ppp | ip | off

# Thresholds; setting a value to 0 disables that check.
MARGIN_WARN=6      MARGIN_CRIT=3      # noise margin in dB (below = bad)
CRC_RATE_WARN=30   CRC_RATE_CRIT=300  # CRC errors per minute since last run

CFGFILE="${FRITZDSL_CFG:-${XYMONHOME:+${XYMONHOME}/etc/fritzdsl.cfg}}"
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi

if [ -n "$FRITZ_PASSWORD_FILE" ] && [ -r "$FRITZ_PASSWORD_FILE" ]; then
    FRITZ_PASSWORD=$(cat "$FRITZ_PASSWORD_FILE")
fi

# Not configured: exit silently (stderr hint only) instead of sending a
# clear status - this keeps "xymon-run.sh all" and freshly installed
# packages from creating ghost columns for a box that was never set up.
if [ -z "$FRITZ_HOST" ] || [ -z "$FRITZ_USER" ] || [ -z "$FRITZ_PASSWORD" ]; then
    echo "fritzdsl: not configured - set FRITZ_USER and FRITZ_PASSWORD" \
         "in ${CFGFILE:-fritzdsl.cfg}" >&2
    exit 0
fi

# Xymon encodes dots in hostnames as commas in status messages.
[ -n "$REPORTHOST" ] || REPORTHOST=$(printf '%s' "$FRITZ_HOST" | tr '.' ',')

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

# is_uint <value> -> true if the value is a non-empty decimal integer
is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# db10 <tenth-dB integer> -> prints the value in dB (e.g. 65 -> 6.5);
# prints nothing when the input is not a number
db10() {
    is_uint "${1:-}" || return 0
    awk -v v="$1" 'BEGIN { printf "%.1f", v / 10 }'
}

# fbelow <a> <b> -> true if a < b (floating point)
fbelow() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'
}

# fmt_uptime <seconds> -> "3d 7h 31m"
fmt_uptime() {
    printf '%dd %dh %dm' "$(($1 / 86400))" "$(($1 % 86400 / 3600))" \
        "$(($1 % 3600 / 60))"
}

# send_report <color> <status-body-file> [data-body-file]
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${REPORTHOST}.${COLUMN} $1 $(date) - DSL line: ${SUMMARY:-$1}

$(cat "$2")"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            "$XYMON" "$XYMSRV" "data ${REPORTHOST}.${COLUMN}
$(cat "$3")"
        fi
    else
        # No Xymon environment: print the messages (manual test run)
        echo "status ${REPORTHOST}.${COLUMN} $1 $(date) - DSL line: ${SUMMARY:-$1}"
        echo ""
        cat "$2"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            echo ""
            echo "data ${REPORTHOST}.${COLUMN}"
            cat "$3"
        fi
    fi
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

WORKDIR=$(mktemp -d "${XYMONTMP}/fritzdsl.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

STATUS="$WORKDIR/status"
DATA="$WORKDIR/data"
NOTES="$WORKDIR/notes"
RESP="$WORKDIR/resp.xml"
: > "$STATUS"
: > "$DATA"
: > "$NOTES"

SUMMARY=""

# abort_report <color> <summary> <message>
abort_report() {
    SUMMARY=$2
    printf '%s\n' "$3" > "$STATUS"
    send_report "$1" "$STATUS"
    exit 0
}

# ncv <name> <numeric-value> -- append an RRD line to the data message
ncv() {
    case "${2:-}" in
        ''|*[!0-9.-]*) return 0 ;;
    esac
    printf '%s : %s\n' "$1" "$2" >> "$DATA"
}

# --- locate curl ---------------------------------------------------------
if [ -z "$CURL" ]; then
    CURL=$(command -v curl || true)
fi
if [ -z "$CURL" ] || [ ! -x "$CURL" ]; then
    abort_report clear "not checked" \
        "curl not found - install curl to enable this test"
fi

# --- TR-064 SOAP plumbing -------------------------------------------------
# soap_call <controlURL> <serviceType-suffix> <action>
# Response body lands in $RESP. Sets HTTPCODE and CURLERR.
# Returns 0 = HTTP 200, 1 = transport error, 2 = 401, 3 = 404, 4 = other.
# Credentials go through "curl --config -" on stdin, not the command
# line, so the password never shows up in the process list.
soap_call() {
    sc_urn="urn:dslforum-org:service:$2"
    : > "$RESP"
    HTTPCODE=$(printf 'user = "%s:%s"\n' "$FRITZ_USER" "$FRITZ_PASSWORD" | \
        "$CURL" --silent --show-error --digest --config - \
            --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
            --output "$RESP" --write-out '%{http_code}' \
            --header 'Content-Type: text/xml; charset="utf-8"' \
            --header "SOAPACTION: \"${sc_urn}#${3}\"" \
            --data "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:${3} xmlns:u=\"${sc_urn}\"/></s:Body></s:Envelope>" \
            "http://${FRITZ_HOST}:${FRITZ_PORT}${1}" 2>"$WORKDIR/curlerr")
    sc_rc=$?
    CURLERR=$(cat "$WORKDIR/curlerr" 2>/dev/null)
    [ "$sc_rc" -eq 0 ] || return 1
    case "$HTTPCODE" in
        200) return 0 ;;
        401) return 2 ;;
        404) return 3 ;;
        *)   return 4 ;;
    esac
}

# get_field <TagName> -- prints the tag's text content from $RESP
get_field() {
    sed -n "s|.*<$1>\([^<]*\)</$1>.*|\1|p" "$RESP" | head -n 1
}

# --- WANDSLInterfaceConfig GetInfo: line state, rates, margins ------------
DSLURL="/upnp/control/wandslifconfig1"
DSLSVC="WANDSLInterfaceConfig:1"

soap_call "$DSLURL" "$DSLSVC" GetInfo
case $? in
    0)  ;;
    1)  abort_report red "unreachable" \
            "cannot reach the FRITZ!Box at http://${FRITZ_HOST}:${FRITZ_PORT} - ${CURLERR:-connection failed}" ;;
    2)  abort_report yellow "authentication failed" \
            "TR-064 authentication failed (HTTP 401) - check FRITZ_USER/FRITZ_PASSWORD in fritzdsl.cfg and make sure the user is allowed to access FRITZ!Box settings" ;;
    3)  abort_report clear "no DSL interface" \
            "TR-064 DSL service not found (HTTP 404) - not a DSL FRITZ!Box, or TR-064 is disabled (enable 'Allow access for applications' under Home Network > Network > Network Settings)" ;;
    *)  abort_report red "TR-064 error" \
            "TR-064 GetInfo request failed (HTTP ${HTTPCODE}): $(get_field errorDescription)" ;;
esac

LINESTATUS=$(get_field NewStatus)
if [ -z "$LINESTATUS" ]; then
    abort_report red "unexpected response" \
        "the FRITZ!Box returned an unexpected TR-064 response (no NewStatus field) - firmware too old, or not a DSL box?"
fi

DATAPATH=$(get_field NewDataPath)
RATE_DOWN=$(get_field NewDownstreamCurrRate)
RATE_UP=$(get_field NewUpstreamCurrRate)
MAXRATE_DOWN=$(get_field NewDownstreamMaxRate)
MAXRATE_UP=$(get_field NewUpstreamMaxRate)
# dB values are reported in tenths of a dB
MARGIN_DOWN=$(db10 "$(get_field NewDownstreamNoiseMargin)")
MARGIN_UP=$(db10 "$(get_field NewUpstreamNoiseMargin)")
ATTEN_DOWN=$(db10 "$(get_field NewDownstreamAttenuation)")
ATTEN_UP=$(db10 "$(get_field NewUpstreamAttenuation)")

OVERALL=green
LINECOLOR=green
if [ "$LINESTATUS" != "Up" ]; then
    LINECOLOR=red
    OVERALL=red
    printf '&red DSL line status: %s\n' "$LINESTATUS" >> "$NOTES"
fi

# check_margin <direction> <dB value>  (only meaningful while the line is up)
check_margin() {
    [ -n "${2:-}" ] || return 0
    if [ "$MARGIN_CRIT" != "0" ] && fbelow "$2" "$MARGIN_CRIT"; then
        OVERALL=$(worst "$OVERALL" red)
        printf '&red %s noise margin %s dB is below %s dB\n' \
            "$1" "$2" "$MARGIN_CRIT" >> "$NOTES"
    elif [ "$MARGIN_WARN" != "0" ] && fbelow "$2" "$MARGIN_WARN"; then
        OVERALL=$(worst "$OVERALL" yellow)
        printf '&yellow %s noise margin %s dB is below %s dB\n' \
            "$1" "$2" "$MARGIN_WARN" >> "$NOTES"
    fi
}

if [ "$LINESTATUS" = "Up" ]; then
    check_margin downstream "$MARGIN_DOWN"
    check_margin upstream "$MARGIN_UP"
fi

ncv rate_down "$RATE_DOWN"
ncv rate_up "$RATE_UP"
ncv maxrate_down "$MAXRATE_DOWN"
ncv maxrate_up "$MAXRATE_UP"
ncv margin_down "$MARGIN_DOWN"
ncv margin_up "$MARGIN_UP"
ncv atten_down "$ATTEN_DOWN"
ncv atten_up "$ATTEN_UP"

# --- WANDSLInterfaceConfig GetStatisticsTotal: error counters -------------
# The counters are cumulative since the last resync; stored as DERIVE
# on the server they graph as error *rates*. For the status color a
# per-minute CRC rate is computed against the previous run's counters.
CRC=""; FEC=""; HEC=""; ES=""; SES=""; RETRAIN=""
if soap_call "$DSLURL" "$DSLSVC" GetStatisticsTotal; then
    CRC=$(get_field NewCRCErrors)
    FEC=$(get_field NewFECErrors)
    HEC=$(get_field NewHECErrors)
    ES=$(get_field NewErroredSecs)
    SES=$(get_field NewSeverelyErroredSecs)
    RETRAIN=$(get_field NewLinkRetrain)
    ncv crc "$CRC"
    ncv fec "$FEC"
    ncv hec "$HEC"
    ncv es "$ES"
    ncv ses "$SES"
    ncv retrain "$RETRAIN"
else
    printf '&clear line statistics unavailable (GetStatisticsTotal failed, HTTP %s)\n' \
        "${HTTPCODE:-?}" >> "$NOTES"
fi

# --- WAN connection uptime (PPP or IP client mode) ------------------------
UPTIME=""
CONNSTATUS=""
case "$WAN_SERVICE" in
    off) WANLIST="" ;;
    ppp) WANLIST="wanpppconn1|WANPPPConnection:1" ;;
    ip)  WANLIST="wanipconnection1|WANIPConnection:1" ;;
    *)   WANLIST="wanpppconn1|WANPPPConnection:1 wanipconnection1|WANIPConnection:1" ;;
esac
for wan in $WANLIST; do
    soap_call "/upnp/control/${wan%|*}" "${wan#*|}" GetStatusInfo || continue
    wan_up=$(get_field NewUptime)
    is_uint "$wan_up" || continue
    UPTIME=$wan_up
    CONNSTATUS=$(get_field NewConnectionStatus)
    break
done
if [ -n "$CONNSTATUS" ] && [ "$CONNSTATUS" != "Connected" ]; then
    OVERALL=$(worst "$OVERALL" yellow)
    printf '&yellow WAN connection status: %s\n' "$CONNSTATUS" >> "$NOTES"
fi
ncv uptime "$UPTIME"

# --- CRC error rate and resync detection via the previous run's state ----
STATEFILE="${XYMONTMP}/fritzdsl.${REPORTHOST}.state"
NOW=$(date +%s)
PREV_T=""; PREV_CRC=""; PREV_UPT=""
if [ -r "$STATEFILE" ]; then
    read -r PREV_T PREV_CRC PREV_UPT < "$STATEFILE" || true
fi

CRCRATE=""
if is_uint "$CRC" && is_uint "$PREV_T" && is_uint "$PREV_CRC" \
    && [ "$NOW" -gt "$PREV_T" ] && [ $((NOW - PREV_T)) -ge 60 ] \
    && [ "$CRC" -ge "$PREV_CRC" ]; then
    CRCRATE=$(awk -v d="$((CRC - PREV_CRC))" -v s="$((NOW - PREV_T))" \
        'BEGIN { printf "%.1f", d * 60 / s }')
    if [ "$CRC_RATE_CRIT" != "0" ] && ! fbelow "$CRCRATE" "$CRC_RATE_CRIT"; then
        OVERALL=$(worst "$OVERALL" red)
        printf '&red CRC errors: %s/min since the last poll (limit %s/min)\n' \
            "$CRCRATE" "$CRC_RATE_CRIT" >> "$NOTES"
    elif [ "$CRC_RATE_WARN" != "0" ] && ! fbelow "$CRCRATE" "$CRC_RATE_WARN"; then
        OVERALL=$(worst "$OVERALL" yellow)
        printf '&yellow CRC errors: %s/min since the last poll (limit %s/min)\n' \
            "$CRCRATE" "$CRC_RATE_WARN" >> "$NOTES"
    fi
fi

if is_uint "$UPTIME" && is_uint "$PREV_UPT" && [ "$UPTIME" -lt "$PREV_UPT" ]; then
    printf 'Note: the connection was re-established since the last poll\n' \
        >> "$NOTES"
fi

# Remember this run's counters (best effort - a read-only $XYMONTMP
# only disables the rate/resync checks, it must not kill the report).
if printf '%s %s %s\n' "$NOW" "${CRC:-0}" "${UPTIME:-0}" \
    > "${STATEFILE}.$$" 2>/dev/null; then
    mv "${STATEFILE}.$$" "$STATEFILE" 2>/dev/null || rm -f "${STATEFILE}.$$"
fi

# --- assemble and send the report ----------------------------------------
if [ "$LINESTATUS" = "Up" ] && is_uint "$RATE_DOWN" && is_uint "$RATE_UP"; then
    SUMMARY="Up at ${RATE_DOWN}/${RATE_UP} kbit/s"
else
    SUMMARY=$LINESTATUS
fi

{
    if [ -s "$NOTES" ]; then
        cat "$NOTES"
    else
        printf 'DSL line is healthy\n'
    fi
    printf '\n'
    printf '&%s DSL line status: %s%s\n' "$LINECOLOR" "$LINESTATUS" \
        "${DATAPATH:+ (path: $DATAPATH)}"
    printf '\n'
    [ -n "$RATE_DOWN$RATE_UP" ] && \
        printf '    sync rate        down=%s up=%s kbit/s\n' \
            "${RATE_DOWN:-?}" "${RATE_UP:-?}"
    [ -n "$MAXRATE_DOWN$MAXRATE_UP" ] && \
        printf '    attainable rate  down=%s up=%s kbit/s\n' \
            "${MAXRATE_DOWN:-?}" "${MAXRATE_UP:-?}"
    [ -n "$MARGIN_DOWN$MARGIN_UP" ] && \
        printf '    noise margin     down=%s up=%s dB\n' \
            "${MARGIN_DOWN:-?}" "${MARGIN_UP:-?}"
    [ -n "$ATTEN_DOWN$ATTEN_UP" ] && \
        printf '    attenuation      down=%s up=%s dB\n' \
            "${ATTEN_DOWN:-?}" "${ATTEN_UP:-?}"
    [ -n "$CRC$FEC$HEC" ] && \
        printf '    errors (total)   crc=%s%s fec=%s hec=%s es=%s ses=%s retrains=%s\n' \
            "${CRC:-?}" "${CRCRATE:+ (${CRCRATE}/min)}" "${FEC:-?}" \
            "${HEC:-?}" "${ES:-?}" "${SES:-?}" "${RETRAIN:-?}"
    if is_uint "$UPTIME"; then
        printf '    connection       %s, up %s\n' \
            "${CONNSTATUS:-?}" "$(fmt_uptime "$UPTIME")"
    fi
    printf '\n'
    printf 'Polled via TR-064 from http://%s:%s\n' "$FRITZ_HOST" "$FRITZ_PORT"
} > "$WORKDIR/final"

send_report "$OVERALL" "$WORKDIR/final" "$DATA"
exit 0
