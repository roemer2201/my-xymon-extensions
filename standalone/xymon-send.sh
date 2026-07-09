#!/bin/sh
#
# xymon-send.sh - minimal replacement for the xymon(1) client binary.
#
# Speaks just enough of the Xymon protocol to deliver one-shot messages
# (status, data, ...): open a TCP connection to the Xymon server, write
# the message, close. Used as $XYMON by xymon-run.sh on hosts without a
# Xymon client (OpenWrt/TurrisOS routers, appliances, ...).
#
# usage: xymon-send.sh SERVER[:PORT] MESSAGE
#        xymon-send.sh SERVER[:PORT] -          (message on stdin)
#
# SERVER may be a space-separated list; the message goes to each one.
# Default port: $XYMONDPORT or 1984.
# Transport: nc (BusyBox or full), ncat or socat - first one found.
set -u

PORT_DEFAULT="${XYMONDPORT:-1984}"
TIMEOUT="${XYMON_SEND_TIMEOUT:-10}"

if [ $# -lt 2 ]; then
    echo "usage: $0 SERVER[:PORT] MESSAGE|-" >&2
    exit 1
fi

SERVERS=$1
MSG=$2

TMPF=$(mktemp "${TMPDIR:-/tmp}/xymonsend.XXXXXX") || exit 1
trap 'rm -f "$TMPF"' EXIT INT TERM

if [ "$MSG" = "-" ]; then
    cat > "$TMPF"
else
    printf '%s\n' "$MSG" > "$TMPF"
fi

TRANSPORT=""
for t in nc ncat socat; do
    if command -v "$t" >/dev/null 2>&1; then
        TRANSPORT=$t
        break
    fi
done
if [ -z "$TRANSPORT" ]; then
    echo "$0: no usable transport found (need nc, ncat or socat)" >&2
    exit 1
fi

# Does this nc support a connection timeout? (BusyBox nc without -w
# still terminates when the server closes, -w is just a safety net.)
NC_W=""
if [ "$TRANSPORT" = "nc" ]; then
    if nc -h 2>&1 | grep -q -- '-w'; then
        NC_W=yes
    fi
fi

send_one() {
    # $1 = host, $2 = port; message is in $TMPF
    case "$TRANSPORT" in
        nc)
            if [ -n "$NC_W" ]; then
                nc -w "$TIMEOUT" "$1" "$2" < "$TMPF" > /dev/null
            else
                nc "$1" "$2" < "$TMPF" > /dev/null
            fi
            ;;
        ncat)
            ncat -w "$TIMEOUT" "$1" "$2" < "$TMPF" > /dev/null
            ;;
        socat)
            socat -t "$TIMEOUT" -T "$TIMEOUT" - "TCP:$1:$2" < "$TMPF" > /dev/null
            ;;
    esac
}

RC=0
# shellcheck disable=SC2086  # word splitting of the server list is intended
for srv in $SERVERS; do
    host=${srv%%:*}
    port=$PORT_DEFAULT
    case "$srv" in
        *:*) port=${srv##*:} ;;
    esac
    if ! send_one "$host" "$port"; then
        echo "$0: sending to ${host}:${port} failed" >&2
        RC=1
    fi
done
exit "$RC"
