#!/bin/sh
#
# wifi.sh -- Xymon client extension: Wi-Fi access point metadata
#
# Collects Wi-Fi metadata from a Linux access point via nl80211 (iw)
# and, where available, the OpenWrt ubus/hostapd and iwinfo interfaces,
# and reports one "wifi" status column:
#
#   - number of authorized clients per AP interface (and in total),
#   - channel utilization (busy/rx/tx percent of the channel active
#     time) and noise floor per radio (phy),
#   - interface throughput, summed client airtime and TX retries /
#     failures as average rates since the previous poll.
#
# The extension is purely informational: the column is green whenever
# at least one AP-mode interface exists and "clear" otherwise - no
# yellow/red thresholds. Rates are computed from a state file in
# $XYMONTMP between two runs; no background process is involved, and
# the RRDs only ever see plain GAUGE values.
#
# Graph data is delivered as a separate "data" message with
# "NAME : VALUE" lines (split-NCV on the Xymon server, see
# server/README.md). Metric names are keyed by the sanitized
# interface / phy name, e.g. clients_phy0_ap0 or busy_phy0.
#
# Written for OpenWrt/TurrisOS access points driven by the standalone
# runner, but works on any Linux with iw(8). Platforms without iw or
# without AP interfaces report "clear".
#
# Configuration: environment variables and/or $XYMONHOME/etc/wifi.cfg
# (see the shipped wifi.cfg; the config file wins over the
# environment).

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
# Defaults -- every value can be set in the environment or in wifi.cfg
# ----------------------------------------------------------------------
WIFI_COLUMN="${WIFI_COLUMN:-wifi}"  # Xymon column name
WIFI_IW="${WIFI_IW:-}"              # path to iw; empty = search $PATH
WIFI_UBUS="${WIFI_UBUS:-}"          # path to ubus; empty = search $PATH
WIFI_IWINFO="${WIFI_IWINFO:-}"      # path to iwinfo; empty = search $PATH
WIFI_SYSNET="${WIFI_SYSNET:-/sys/class/net}"
WIFI_INTERFACES="${WIFI_INTERFACES:-}"  # optional interface whitelist

CFGFILE="${WIFI_CFG:-${XYMONHOME:+${XYMONHOME}/etc/wifi.cfg}}"
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi
COLUMN="$WIFI_COLUMN"

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

# sanitize <text> -> lowercase, [a-z0-9_] only, squeezed and trimmed
sanitize() {
    # shellcheck disable=SC2018,SC2019  # NOT '[:upper:]'/'[:lower:]': BusyBox
    # tr does not recognize the class syntax and translates it letter-by-
    # letter as the literal string "[:upper:]" instead, silently corrupting
    # names that contain 'p' or 'u'. A-Z/a-z ranges are the portable form.
    s_out=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '_' | tr -s '_')
    s_out=${s_out#_}
    printf '%s' "${s_out%_}"
}

# rate <current> <previous> <elapsed-s> <scale> <printf-format>
# Prints (current - previous) * scale / elapsed. Fails when either
# counter is not a plain number or the delta is negative - that means
# a counter reset (reboot, interface restart) or, for counters summed
# over the connected clients, a client that disconnected and took its
# share with it. The caller then skips the metric for this round
# instead of reporting garbage.
rate() {
    if ! is_uint "${1:-}" || ! is_uint "${2:-}"; then
        return 1
    fi
    awk -v c="$1" -v p="$2" -v e="$3" -v s="$4" -v f="$5" 'BEGIN {
        d = c - p
        if (d < 0 || e <= 0) exit 1
        printf f, d * s / e
    }'
}

# survey_pct <act> <busy> <rx> <tx> <prev-act> <prev-busy> <prev-rx> <prev-tx>
# Prints "busy% rx% tx%" relative to the channel active time delta.
# Only the deltas are judged, never the absolute counters: some
# firmware (seen on a Zyxel NWA50AX Pro, mt798x) reports busy/rx/tx
# with a huge constant garbage offset while the deltas are correct.
# Exit 1: counter reset or 32-bit wrap (negative delta) - the caller
# skips the metric for one poll, like rate(). Exit 2: a delta grew
# faster than the active time - garbage even as deltas. awk computes
# in doubles; beyond 2^53 (the garbage offsets get there) a delta can
# be off by a few ms, hence the slack in the exit-2 test and the cap
# at 100% for a saturated channel.
survey_pct() {
    awk -v a="$1" -v b="$2" -v r="$3" -v t="$4" \
        -v pa="$5" -v pb="$6" -v pr="$7" -v pt="$8" 'BEGIN {
        da = a - pa; db = b - pb; dr = r - pr; dt = t - pt
        if (da <= 0 || db < 0 || dr < 0 || dt < 0) exit 1
        if (db > da + 10 || dr > da + 10 || dt > da + 10) exit 2
        if (db > da) db = da
        if (dr > da) dr = da
        if (dt > da) dt = da
        printf "%.1f %.1f %.1f", db * 100 / da, dr * 100 / da, dt * 100 / da
    }'
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
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - wifi: ${SUMMARY:-$1}

$(cat "$2")"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            "$XYMON" "$XYMSRV" "data ${MACHINE}.${COLUMN}
$(cat "$3")"
        fi
    else
        # No Xymon environment: print the messages (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - wifi: ${SUMMARY:-$1}"
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

WORKDIR=$(mktemp -d "${XYMONTMP}/wifi.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

STATUS="$WORKDIR/status"
DATA="$WORKDIR/data"
NEWSTATE="$WORKDIR/newstate"
: > "$STATUS"
: > "$DATA"
: > "$NEWSTATE"

SUMMARY=""

clear_report() {
    SUMMARY="not applicable"
    printf '%s\n' "$1" > "$WORKDIR/clear"
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

# --- locate the tools -----------------------------------------------------
if [ -z "$WIFI_IW" ]; then
    WIFI_IW=$(command -v iw || true)
fi
if [ -z "$WIFI_IW" ] || [ ! -x "$WIFI_IW" ]; then
    case "$(uname -s)" in
        Linux) clear_report "iw not found - install the iw package to enable this test" ;;
        *)     clear_report "iw (nl80211) exists on Linux only - test not applicable here" ;;
    esac
fi
if [ -z "$WIFI_UBUS" ]; then
    WIFI_UBUS=$(command -v ubus || true)
fi
if [ -n "$WIFI_UBUS" ] && [ ! -x "$WIFI_UBUS" ]; then
    WIFI_UBUS=""
fi
if [ -z "$WIFI_IWINFO" ]; then
    WIFI_IWINFO=$(command -v iwinfo || true)
fi
if [ -n "$WIFI_IWINFO" ] && [ ! -x "$WIFI_IWINFO" ]; then
    WIFI_IWINFO=""
fi

# --- discover the AP interfaces -------------------------------------------
# "iw dev" groups interfaces under their radio ("phy#N" lines). Only
# type AP interfaces are monitored. Every field except the interface
# name and type is optional (iw output varies between versions).
# The SSID goes last in the |-separated record: it may contain spaces;
# a "|" in the SSID would corrupt the record, so it is mapped to "_"
# (display only - metrics are keyed by interface name).
"$WIFI_IW" dev 2>/dev/null | awk '
    function flush() {
        if (ifn != "" && type == "AP")
            print ifn "|phy" phy "|" chan "|" freq "|" width "|" txp "|" ssid
        ifn = ""; type = ""; ssid = ""; chan = ""; freq = ""; width = ""; txp = ""
    }
    /^phy#/             { flush(); phy = substr($1, 5) }
    /^[ \t]*Interface / { flush(); ifn = $2 }
    /^[ \t]*type /      { type = $2 }
    /^[ \t]*ssid /      {
        s = $0
        sub(/^[ \t]*ssid /, "", s)
        gsub(/\|/, "_", s)
        ssid = s
    }
    /^[ \t]*channel /   {
        chan = $2
        if (match($0, /\([0-9]+ MHz\)/))
            freq = substr($0, RSTART + 1, RLENGTH - 6)
        if (match($0, /width: [0-9]+ MHz/))
            width = substr($0, RSTART + 7, RLENGTH - 11)
    }
    /^[ \t]*txpower /   { txp = $2 }
    END { flush() }
' > "$WORKDIR/ifs"

if [ ! -s "$WORKDIR/ifs" ]; then
    clear_report "no AP-mode wireless interfaces found (iw dev lists none) - nothing to monitor on this host"
fi

STATEFILE="${XYMONTMP}/wifi.${MACHINE}.state"
NOW=$(date +%s)

NIF=0
TOTAL=""
SEEN_PHYS=" "

# The loop reads the interface list from fd 3: the tools called inside
# must not be able to eat the list from stdin.
while IFS='|' read -r ifn phyname chan freq width txp ssid <&3; do
    [ -n "$ifn" ] || continue
    if [ -n "$WIFI_INTERFACES" ]; then
        case " $WIFI_INTERFACES " in
            *" $ifn "*) ;;
            *) continue ;;
        esac
    fi
    NIF=$((NIF + 1))
    sif=$(sanitize "$ifn")

    # --- per-radio data, once per phy (first AP interface wins) ------
    case "$SEEN_PHYS" in
        *" $phyname "*) ;;
        *)
            SEEN_PHYS="$SEEN_PHYS$phyname "
            sphy=$(sanitize "$phyname")
            ncv "channel_$sphy" "$chan"

            # Survey of the channel in use: cumulative ms counters.
            # shellcheck disable=SC2046  # word splitting is intended
            set -- $("$WIFI_IW" dev "$ifn" survey dump 2>/dev/null | awk '
                BEGIN { noise = "-"; act = "-"; busy = "-"; rxt = "-"; txt = "-" }
                /frequency:/ { inuse = index($0, "[in use]") > 0 }
                inuse && /noise:/                 { noise = $2 }
                inuse && /channel active time:/   { act  = $4 }
                inuse && /channel busy time:/     { busy = $4 }
                inuse && /channel receive time:/  { rxt  = $4 }
                inuse && /channel transmit time:/ { txt  = $4 }
                END { print noise, act, busy, rxt, txt }
            ')
            S_NOISE=${1:--}; S_ACT=${2:--}; S_BUSY=${3:--}; S_RXT=${4:--}; S_TXT=${5:--}

            BUSYPCT=""; RXPCT=""; TXPCT=""
            PPT=""; PACT=""; PBUSY=""; PRXT=""; PTXT=""
            if prev=$(state_get PHY "$phyname"); then
                # shellcheck disable=SC2086  # word splitting is intended
                set -- $prev
                PPT=${1:-}; PACT=${2:-}; PBUSY=${3:-}; PRXT=${4:-}; PTXT=${5:-}
            fi
            if is_uint "$S_ACT" && is_uint "$S_BUSY" \
                && is_uint "$S_RXT" && is_uint "$S_TXT" \
                && is_uint "$PPT" \
                && [ "$NOW" -gt "$PPT" ] && [ $((NOW - PPT)) -ge 60 ] \
                && is_uint "$PACT" && is_uint "$PBUSY" \
                && is_uint "$PRXT" && is_uint "$PTXT"; then
                pct=$(survey_pct "$S_ACT" "$S_BUSY" "$S_RXT" "$S_TXT" \
                    "$PACT" "$PBUSY" "$PRXT" "$PTXT")
                case $? in
                    0)
                        # shellcheck disable=SC2086  # splitting intended
                        set -- $pct
                        BUSYPCT=$1; RXPCT=$2; TXPCT=$3
                        ;;
                    2)
                        printf '&clear %s survey counter deltas implausible (busy/rx/tx grew faster than the active time) - channel utilization not reported\n' \
                            "$phyname" >> "$STATUS"
                        ;;
                esac
            fi

            ncv "busy_$sphy" "$BUSYPCT"
            ncv "rxpct_$sphy" "$RXPCT"
            ncv "txpct_$sphy" "$TXPCT"
            case "$S_NOISE" in
                -*[0-9]*) ncv "noise_$sphy" "$S_NOISE" ;;
            esac

            printf 'PHY %s %s %s %s %s %s\n' "$phyname" "$NOW" \
                "$S_ACT" "$S_BUSY" "$S_RXT" "$S_TXT" >> "$NEWSTATE"

            {
                printf '%s  channel=%s%s%s' "$phyname" "${chan:-?}" \
                    "${freq:+ (${freq} MHz)}" "${width:+  width=${width} MHz}"
                if [ -n "$BUSYPCT" ]; then
                    printf '  busy=%s%% rx=%s%% tx=%s%%' \
                        "$BUSYPCT" "$RXPCT" "$TXPCT"
                fi
                case "$S_NOISE" in
                    -*[0-9]*) printf '  noise=%s dBm' "$S_NOISE" ;;
                esac
                printf '\n'
            } >> "$STATUS"
            ;;
    esac

    # --- clients and airtime ------------------------------------------
    # Preferred source: hostapd via ubus (client count plus cumulative
    # per-client airtime in microseconds); fallback: iwinfo assoclist
    # (count only - it lists associated, not authorized, stations).
    NCLIENTS=""; ARX=""; ATX=""; CSRC=""
    if [ -n "$WIFI_UBUS" ] \
        && "$WIFI_UBUS" call "hostapd.$ifn" get_clients \
            > "$WORKDIR/clients.json" 2>/dev/null \
        && [ -s "$WORKDIR/clients.json" ]; then
        # ubus pretty-prints its JSON (one key or brace per line), so
        # brace counting tracks the nesting depth: "rx"/"tx" may only
        # be summed directly inside an "airtime" object - the keys
        # also exist in the bytes/packets/rate/mcs_map objects.
        # shellcheck disable=SC2046  # word splitting is intended
        set -- $(awk '
            {
                if (index($0, "\"airtime\"") && index($0, "{"))
                    inair = depth + 1
                depth += gsub(/\{/, "{")
            }
            /"authorized"[: \t]*true/ { n++ }
            inair && depth == inair && /"rx"/ {
                v = $2; gsub(/[^0-9]/, "", v); arx += v
            }
            inair && depth == inair && /"tx"/ {
                v = $2; gsub(/[^0-9]/, "", v); atx += v
            }
            {
                depth -= gsub(/\}/, "}")
                if (inair && depth < inair) inair = 0
            }
            END { printf "%d %.0f %.0f\n", n + 0, arx + 0, atx + 0 }
        ' "$WORKDIR/clients.json")
        NCLIENTS=${1:-}; ARX=${2:-}; ATX=${3:-}
        CSRC="hostapd"
    elif [ -n "$WIFI_IWINFO" ] \
        && "$WIFI_IWINFO" "$ifn" assoclist > "$WORKDIR/assoc" 2>/dev/null; then
        NCLIENTS=$(grep -Ec '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}[[:space:]]' \
            "$WORKDIR/assoc" || true)
        is_uint "$NCLIENTS" || NCLIENTS=""
        CSRC="iwinfo"
    fi

    # --- interface byte counters (stable, monotonic) -------------------
    RXB=$(cat "$WIFI_SYSNET/$ifn/statistics/rx_bytes" 2>/dev/null || true)
    TXB=$(cat "$WIFI_SYSNET/$ifn/statistics/tx_bytes" 2>/dev/null || true)
    is_uint "$RXB" || RXB=""
    is_uint "$TXB" || TXB=""

    # --- TX retries / failures, summed over the stations ---------------
    # Best effort: some drivers intermittently return an empty station
    # dump even with clients associated - then the metric is simply
    # omitted for this round.
    RET=""; FAILED=""
    "$WIFI_IW" dev "$ifn" station dump > "$WORKDIR/stations" 2>/dev/null \
        || : > "$WORKDIR/stations"
    if [ -s "$WORKDIR/stations" ]; then
        # shellcheck disable=SC2046  # word splitting is intended
        set -- $(awk '
            /^Station /   { n++ }
            /tx retries:/ { r += $3 }
            /tx failed:/  { f += $3 }
            END { if (n) print r + 0, f + 0 }
        ' "$WORKDIR/stations")
        RET=${1:-}; FAILED=${2:-}
    fi

    # --- rates from the previous poll -----------------------------------
    RXKBPS=""; TXKBPS=""; AIRRX=""; AIRTX=""; RETPS=""; FAILPS=""
    PT=""; PRX=""; PTX=""; PARX=""; PATX=""; PRET=""; PFAIL=""
    if prev=$(state_get IF "$ifn"); then
        # shellcheck disable=SC2086  # word splitting is intended
        set -- $prev
        PT=${1:-}; PRX=${2:-}; PTX=${3:-}; PARX=${4:-}; PATX=${5:-}
        PRET=${6:-}; PFAIL=${7:-}
    fi
    if is_uint "$PT" && [ "$NOW" -gt "$PT" ] && [ $((NOW - PT)) -ge 60 ]; then
        ELAPSED=$((NOW - PT))
        RXKBPS=$(rate "$RXB" "$PRX" "$ELAPSED" 0.008 '%.1f') || RXKBPS=""
        TXKBPS=$(rate "$TXB" "$PTX" "$ELAPSED" 0.008 '%.1f') || TXKBPS=""
        # airtime: microseconds per second of wall clock = percent/1e4
        AIRRX=$(rate "$ARX" "$PARX" "$ELAPSED" 0.0001 '%.1f') || AIRRX=""
        AIRTX=$(rate "$ATX" "$PATX" "$ELAPSED" 0.0001 '%.1f') || AIRTX=""
        RETPS=$(rate "$RET" "$PRET" "$ELAPSED" 1 '%.2f') || RETPS=""
        FAILPS=$(rate "$FAILED" "$PFAIL" "$ELAPSED" 1 '%.2f') || FAILPS=""
    fi

    printf 'IF %s %s %s %s %s %s %s %s\n' "$ifn" "$NOW" \
        "${RXB:--}" "${TXB:--}" "${ARX:--}" "${ATX:--}" \
        "${RET:--}" "${FAILED:--}" >> "$NEWSTATE"

    if [ -n "$NCLIENTS" ]; then
        ncv "clients_$sif" "$NCLIENTS"
        TOTAL=$((${TOTAL:-0} + NCLIENTS))
    fi
    ncv "rxkbps_$sif" "$RXKBPS"
    ncv "txkbps_$sif" "$TXKBPS"
    ncv "airrx_$sif" "$AIRRX"
    ncv "airtx_$sif" "$AIRTX"
    ncv "retries_$sif" "$RETPS"
    ncv "failed_$sif" "$FAILPS"

    # --- status display (key=value on purpose: "name : value" lines
    # would be picked up by the server's NCV parser) --------------------
    {
        printf '  &green %s  ssid="%s"  clients=%s%s%s\n' \
            "$ifn" "${ssid:-?}" "${NCLIENTS:-?}" \
            "${CSRC:+ [$CSRC]}" "${txp:+  txpower=${txp} dBm}"
        detail=""
        if [ -n "$RXKBPS" ] && [ -n "$TXKBPS" ]; then
            detail="rx=${RXKBPS} tx=${TXKBPS} kbit/s"
        elif [ -n "$RXB" ]; then
            detail="rates appear with the next poll"
        fi
        if [ -n "$AIRRX" ] && [ -n "$AIRTX" ]; then
            detail="${detail}${detail:+  }airtime rx=${AIRRX}% tx=${AIRTX}%"
        fi
        if [ -n "$RETPS" ]; then
            detail="${detail}${detail:+  }retries=${RETPS}/s failed=${FAILPS:-?}/s"
        fi
        if [ -n "$detail" ]; then
            printf '         %s\n' "$detail"
        fi
    } >> "$STATUS"
done 3< "$WORKDIR/ifs"

if [ "$NIF" -eq 0 ]; then
    clear_report "no AP-mode wireless interface matches WIFI_INTERFACES=\"${WIFI_INTERFACES}\""
fi

ncv clients_total "$TOTAL"

# Remember this run's counters (best effort - a read-only $XYMONTMP
# only disables the rate calculation, it must not kill the report).
if [ -s "$NEWSTATE" ]; then
    if cat "$NEWSTATE" > "${STATEFILE}.$$" 2>/dev/null; then
        mv "${STATEFILE}.$$" "$STATEFILE" 2>/dev/null || rm -f "${STATEFILE}.$$"
    fi
fi

SUMMARY="${TOTAL:-?} client(s) on $NIF AP interface(s)"

{
    cat "$STATUS"
    printf '\nRates are averages since the previous poll; the first poll only primes the state file.\n'
} > "$WORKDIR/final"

send_report green "$WORKDIR/final" "$DATA"
exit 0
