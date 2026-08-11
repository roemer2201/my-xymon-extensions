#!/bin/sh
#
# fritzwan.sh -- Xymon extension: AVM FRITZ!Box WAN throughput monitoring
#
# Polls a FRITZ!Box for its WAN interface traffic and link state and
# reports one Xymon column attached to the box's own host entry:
#
#   - status color: red when the physical WAN link is down or the box
#     is unreachable, yellow/red (optional) when the link utilization
#     exceeds the configured thresholds,
#   - a "data" message with "NAME : VALUE" lines for RRD graphing
#     (split-NCV on the Xymon server, see server/README.md).
#
# Traffic counters are read from the box's UPnP/IGD endpoint when
# possible (64-bit counters, no login required) and fall back to the
# authenticated TR-064 counters (32 bit, with single-wrap correction).
# The throughput is computed as the average rate since the previous
# poll from a state file, so the RRDs only ever see plain GAUGE
# values - no COUNTER/DERIVE wrap headaches.
#
# The poller runs on the Xymon server itself (or any host that can
# reach the box) - no software is installed on the FRITZ!Box.
# Configuration: $XYMONHOME/etc/fritzwan.cfg. Without configuration
# the extension exits silently (the shipped launch snippet is
# additionally DISABLED by default).

set -u

COLUMN="fritzwan"

# ----------------------------------------------------------------------
# Xymon environment (xymonlaunch provides these; fallbacks allow running
# the script manually for testing: output then goes to stdout)
# ----------------------------------------------------------------------
XYMONHOME="${XYMONHOME:-${XYMONCLIENTHOME:-}}"
XYMONTMP="${XYMONTMP:-${TMPDIR:-/tmp}}"

# ----------------------------------------------------------------------
# Defaults -- every value can be overridden in fritzwan.cfg
# ----------------------------------------------------------------------
CURL=""                    # path to curl; empty = search $PATH
FRITZ_HOST="fritz.box"     # FRITZ!Box address (name or IP)
FRITZ_PORT="49000"         # TR-064/UPnP port
FRITZ_USER=""              # FRITZ!Box user (TR-064; not needed for MODE=igd)
FRITZ_PASSWORD=""          # ... and its password
FRITZ_PASSWORD_FILE=""     # alternative: read the password from a file
REPORTHOST=""              # Xymon host to report as; empty = FRITZ_HOST
TIMEOUT=15                 # seconds per SOAP request
MODE="auto"                # auto | igd | tr064 (see fritzwan.cfg)

# Thresholds; setting a value to 0 disables that check.
UTIL_WARN=0        UTIL_CRIT=0        # link utilization in percent

CFGFILE="${FRITZWAN_CFG:-${XYMONHOME:+${XYMONHOME}/etc/fritzwan.cfg}}"
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
# MODE=igd is an explicit opt-in and needs no credentials.
if [ -z "$FRITZ_HOST" ] || { [ "$MODE" != "igd" ] && \
    { [ -z "$FRITZ_USER" ] || [ -z "$FRITZ_PASSWORD" ]; }; }; then
    echo "fritzwan: not configured - set FRITZ_USER and FRITZ_PASSWORD" \
         "(or MODE=igd) in ${CFGFILE:-fritzwan.cfg}" >&2
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

# fbelow <a> <b> -> true if a < b (floating point)
fbelow() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'
}

# mbit <bit/s> -> prints the value in Mbit/s with one decimal
mbit() {
    is_uint "${1:-}" || return 0
    awk -v v="$1" 'BEGIN { printf "%.1f", v / 1000000 }'
}

# gib <bytes> -> prints the value in GiB with one decimal
gib() {
    is_uint "${1:-}" || return 0
    awk -v v="$1" 'BEGIN { printf "%.1f", v / 1073741824 }'
}

# counter_delta <current> <previous> <width>
# Prints current - previous; a negative delta is corrected once for
# 32-bit counter wrap, anything still negative (counter reset after a
# reboot) fails so the caller skips this round.
counter_delta() {
    awk -v c="$1" -v p="$2" -v w="$3" 'BEGIN {
        d = c - p
        if (d < 0 && w == 32) d += 4294967296
        if (d < 0) exit 1
        printf "%.0f", d
    }'
}

# send_report <color> <status-body-file> [data-body-file]
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${REPORTHOST}.${COLUMN} $1 $(date) - WAN: ${SUMMARY:-$1}

$(cat "$2")"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            "$XYMON" "$XYMSRV" "data ${REPORTHOST}.${COLUMN}
$(cat "$3")"
        fi
    else
        # No Xymon environment: print the messages (manual test run)
        echo "status ${REPORTHOST}.${COLUMN} $1 $(date) - WAN: ${SUMMARY:-$1}"
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

WORKDIR=$(mktemp -d "${XYMONTMP}/fritzwan.XXXXXX") || exit 1
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

# --- SOAP plumbing --------------------------------------------------------
# soap_call <auth|noauth> <controlURL> <full-service-urn> <action>
# Response body lands in $RESP. Sets HTTPCODE and CURLERR.
# Returns 0 = HTTP 200, 1 = transport error, 2 = 401, 3 = 404, 4 = other.
# Credentials go through "curl --config -" on stdin, not the command
# line, so the password never shows up in the process list; for
# unauthenticated (UPnP/IGD) calls the config on stdin is empty.
soap_call() {
    sc_urn=$3
    : > "$RESP"
    HTTPCODE=$({ if [ "$1" = "auth" ]; then
            printf 'digest\nuser = "%s:%s"\n' "$FRITZ_USER" "$FRITZ_PASSWORD"
        fi; } | \
        "$CURL" --silent --show-error --config - \
            --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
            --output "$RESP" --write-out '%{http_code}' \
            --header 'Content-Type: text/xml; charset="utf-8"' \
            --header "SOAPACTION: \"${sc_urn}#${4}\"" \
            --data "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:${4} xmlns:u=\"${sc_urn}\"/></s:Body></s:Envelope>" \
            "http://${FRITZ_HOST}:${FRITZ_PORT}${2}" 2>"$WORKDIR/curlerr")
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

# TR-064 (authenticated) and UPnP/IGD (unauthenticated) endpoints of
# the WANCommonInterfaceConfig service.
TRURL="/upnp/control/wancommonifconfig1"
TRSVC="urn:dslforum-org:service:WANCommonInterfaceConfig:1"
IGDURL="/igdupnp/control/WANCommonIFC1"
IGDSVC="urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1"

# --- link properties: physical status, access type, capacity -------------
if [ "$MODE" = "igd" ]; then
    soap_call noauth "$IGDURL" "$IGDSVC" GetCommonLinkProperties
else
    soap_call auth "$TRURL" "$TRSVC" GetCommonLinkProperties
fi
case $? in
    0)  ;;
    1)  abort_report red "unreachable" \
            "cannot reach the FRITZ!Box at http://${FRITZ_HOST}:${FRITZ_PORT} - ${CURLERR:-connection failed}" ;;
    2)  abort_report yellow "authentication failed" \
            "TR-064 authentication failed (HTTP 401) - check FRITZ_USER/FRITZ_PASSWORD in fritzwan.cfg and make sure the user is allowed to access FRITZ!Box settings" ;;
    3)  if [ "$MODE" = "igd" ]; then
            abort_report clear "UPnP status info disabled" \
                "UPnP status information is not available (HTTP 404) - enable 'Transmit status information over UPnP' under Home Network > Network > Network Settings, or use MODE=auto with TR-064 credentials"
        else
            abort_report clear "no WAN service" \
                "TR-064 WAN service not found (HTTP 404) - TR-064 disabled? (enable 'Allow access for applications' under Home Network > Network > Network Settings)"
        fi ;;
    *)  abort_report red "TR-064 error" \
            "GetCommonLinkProperties request failed (HTTP ${HTTPCODE}): $(get_field errorDescription)" ;;
esac

LINKSTATUS=$(get_field NewPhysicalLinkStatus)
if [ -z "$LINKSTATUS" ]; then
    abort_report red "unexpected response" \
        "the FRITZ!Box returned an unexpected response (no NewPhysicalLinkStatus field)"
fi

ACCESSTYPE=$(get_field NewWANAccessType)
MAXBPS_DOWN=$(get_field NewLayer1DownstreamMaxBitRate)
MAXBPS_UP=$(get_field NewLayer1UpstreamMaxBitRate)

OVERALL=green
LINKCOLOR=green
if [ "$LINKSTATUS" != "Up" ]; then
    LINKCOLOR=red
    OVERALL=red
    printf '&red WAN link status: %s\n' "$LINKSTATUS" >> "$NOTES"
fi

ncv maxbps_down "$MAXBPS_DOWN"
ncv maxbps_up "$MAXBPS_UP"

# --- traffic counters ------------------------------------------------------
# Preferred source: UPnP/IGD GetAddonInfos with AVM's 64-bit counters
# (wrap-free); fallback: 32-bit counters (from the same response, or
# via authenticated TR-064 when UPnP status info is disabled). 32-bit
# counters wrap every 4 GiB - a single wrap per interval is corrected,
# more than that (fast lines, long intervals) cannot be detected.
RX=""; TX=""; WIDTH=""; CNTSRC=""
if [ "$MODE" != "tr064" ]; then
    if soap_call noauth "$IGDURL" "$IGDSVC" GetAddonInfos; then
        cnt_rx=$(get_field NewX_AVM_DE_TotalBytesReceived64)
        cnt_tx=$(get_field NewX_AVM_DE_TotalBytesSent64)
        if is_uint "$cnt_rx" && is_uint "$cnt_tx"; then
            RX=$cnt_rx; TX=$cnt_tx; WIDTH=64; CNTSRC="UPnP 64-bit"
        else
            cnt_rx=$(get_field NewTotalBytesReceived)
            cnt_tx=$(get_field NewTotalBytesSent)
            if is_uint "$cnt_rx" && is_uint "$cnt_tx"; then
                RX=$cnt_rx; TX=$cnt_tx; WIDTH=32; CNTSRC="UPnP 32-bit"
            fi
        fi
    fi
fi
if [ -z "$RX" ] && [ "$MODE" != "igd" ]; then
    if soap_call auth "$TRURL" "$TRSVC" GetTotalBytesReceived; then
        cnt_rx=$(get_field NewTotalBytesReceived)
        if soap_call auth "$TRURL" "$TRSVC" GetTotalBytesSent; then
            cnt_tx=$(get_field NewTotalBytesSent)
            if is_uint "$cnt_rx" && is_uint "$cnt_tx"; then
                RX=$cnt_rx; TX=$cnt_tx; WIDTH=32; CNTSRC="TR-064 32-bit"
            fi
        fi
    fi
fi
if [ -z "$RX" ]; then
    printf '&clear traffic counters unavailable - enable UPnP status information (Home Network > Network > Network Settings) for 64-bit counters\n' \
        >> "$NOTES"
fi

# --- throughput as average rate since the previous poll -------------------
STATEFILE="${XYMONTMP}/fritzwan.${REPORTHOST}.state"
NOW=$(date +%s)
PREV_T=""; PREV_RX=""; PREV_TX=""; PREV_W=""
if [ -r "$STATEFILE" ]; then
    read -r PREV_T PREV_RX PREV_TX PREV_W < "$STATEFILE" || true
fi

BPS_DOWN=""; BPS_UP=""
if [ -n "$RX" ] && is_uint "$PREV_T" && is_uint "$PREV_RX" \
    && is_uint "$PREV_TX" && [ "$PREV_W" = "$WIDTH" ] \
    && [ "$NOW" -gt "$PREV_T" ] && [ $((NOW - PREV_T)) -ge 60 ]; then
    ELAPSED=$((NOW - PREV_T))
    if drx=$(counter_delta "$RX" "$PREV_RX" "$WIDTH") \
        && dtx=$(counter_delta "$TX" "$PREV_TX" "$WIDTH"); then
        BPS_DOWN=$(awk -v d="$drx" -v s="$ELAPSED" \
            'BEGIN { printf "%.0f", d * 8 / s }')
        BPS_UP=$(awk -v d="$dtx" -v s="$ELAPSED" \
            'BEGIN { printf "%.0f", d * 8 / s }')
    fi
fi

# Remember this run's counters (best effort - a read-only $XYMONTMP
# only disables the rate calculation, it must not kill the report).
if [ -n "$RX" ]; then
    if printf '%s %s %s %s\n' "$NOW" "$RX" "$TX" "$WIDTH" \
        > "${STATEFILE}.$$" 2>/dev/null; then
        mv "${STATEFILE}.$$" "$STATEFILE" 2>/dev/null || rm -f "${STATEFILE}.$$"
    fi
fi

# --- utilization ------------------------------------------------------------
UTIL_DOWN=""; UTIL_UP=""
if is_uint "$BPS_DOWN" && is_uint "$MAXBPS_DOWN" && [ "$MAXBPS_DOWN" -gt 0 ]; then
    UTIL_DOWN=$(awk -v b="$BPS_DOWN" -v m="$MAXBPS_DOWN" \
        'BEGIN { printf "%.1f", b * 100 / m }')
fi
if is_uint "$BPS_UP" && is_uint "$MAXBPS_UP" && [ "$MAXBPS_UP" -gt 0 ]; then
    UTIL_UP=$(awk -v b="$BPS_UP" -v m="$MAXBPS_UP" \
        'BEGIN { printf "%.1f", b * 100 / m }')
fi

# check_util <direction> <percent>
check_util() {
    [ -n "${2:-}" ] || return 0
    if [ "$UTIL_CRIT" != "0" ] && ! fbelow "$2" "$UTIL_CRIT"; then
        OVERALL=$(worst "$OVERALL" red)
        printf '&red %s utilization %s%% is above %s%%\n' \
            "$1" "$2" "$UTIL_CRIT" >> "$NOTES"
    elif [ "$UTIL_WARN" != "0" ] && ! fbelow "$2" "$UTIL_WARN"; then
        OVERALL=$(worst "$OVERALL" yellow)
        printf '&yellow %s utilization %s%% is above %s%%\n' \
            "$1" "$2" "$UTIL_WARN" >> "$NOTES"
    fi
}
check_util downstream "$UTIL_DOWN"
check_util upstream "$UTIL_UP"

ncv bps_down "$BPS_DOWN"
ncv bps_up "$BPS_UP"
ncv util_down "$UTIL_DOWN"
ncv util_up "$UTIL_UP"

# --- assemble and send the report ----------------------------------------
if [ "$LINKSTATUS" = "Up" ]; then
    if [ -n "$BPS_DOWN" ]; then
        SUMMARY="Up, $(mbit "$BPS_DOWN")/$(mbit "$BPS_UP") Mbit/s (down/up)"
    else
        SUMMARY="Up"
    fi
else
    SUMMARY=$LINKSTATUS
fi

{
    if [ -s "$NOTES" ]; then
        cat "$NOTES"
    else
        printf 'WAN link is healthy\n'
    fi
    printf '\n'
    printf '&%s WAN link status: %s%s\n' "$LINKCOLOR" "$LINKSTATUS" \
        "${ACCESSTYPE:+ ($ACCESSTYPE)}"
    printf '\n'
    if [ -n "$BPS_DOWN" ]; then
        printf '    throughput       down=%s up=%s Mbit/s (average since the last poll)\n' \
            "$(mbit "$BPS_DOWN")" "$(mbit "$BPS_UP")"
    elif [ -n "$RX" ]; then
        printf '    throughput       not yet available (rates appear with the next poll)\n'
    fi
    if is_uint "$MAXBPS_DOWN" && is_uint "$MAXBPS_UP"; then
        printf '    link capacity    down=%s up=%s Mbit/s\n' \
            "$(mbit "$MAXBPS_DOWN")" "$(mbit "$MAXBPS_UP")"
    fi
    if [ -n "$UTIL_DOWN$UTIL_UP" ]; then
        printf '    utilization      down=%s%% up=%s%%\n' \
            "${UTIL_DOWN:-?}" "${UTIL_UP:-?}"
    fi
    if [ -n "$RX" ]; then
        printf '    traffic total    received=%s GiB sent=%s GiB [%s counters]\n' \
            "$(gib "$RX")" "$(gib "$TX")" "$CNTSRC"
    fi
    printf '\n'
    printf 'Polled from http://%s:%s\n' "$FRITZ_HOST" "$FRITZ_PORT"
} > "$WORKDIR/final"

send_report "$OVERALL" "$WORKDIR/final" "$DATA"
exit 0
