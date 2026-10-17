#!/bin/sh
# Exercise Powerline parser, collector and state using fake tools only.
# Program flow: configure sandbox, replay snapshots/transitions, assert
# protocol messages, then check failure isolation and privileged argv guards.
# Usage: sh tests/powerline/run.sh [--help]
# Env: TESTSH selects shell under test (e.g. "busybox sh").
set -u
case "${1:-}" in -h|--help) printf '%s\n' 'Usage: run.sh; TESTSH selects the collector shell. No PLC access.'; exit 0 ;; esac
HERE=$(CDPATH='' cd -- "$(dirname -- "${0}")" && pwd) || exit 1
REPO=$(CDPATH='' cd -- "${HERE}/../.." && pwd) || exit 1
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "${TMP}"' 0
trap 'exit 1' 1 2 15
TESTSH=${TESTSH:-sh}
FAIL=0
PATH="${HERE}/bin:${PATH}"
PL_FIXTURES=${HERE} PL_MESSAGES=${TMP}/messages
POWERLINE_CONFIG=/dev/null POWERLINE_HELPER=${HERE}/bin/fixture-helper POWERLINE_SUDO=''
POWERLINE_IP=${HERE}/bin/fixture-ip POWERLINE_STATE_DIR=${TMP}/state
POWERLINE_HOSTS=${HERE}/hosts POWERLINE_MAPPING='' POWERLINE_XYMONCFG=/nonexistent
POWERLINE_COLLECTOR_HOST=xymon.lan POWERLINE_ENABLED=1 POWERLINE_SILENT=1
POWERLINE_TX_PHY_WARN=off POWERLINE_TX_PHY_CRIT=off POWERLINE_RX_PHY_WARN=off POWERLINE_RX_PHY_CRIT=off
POWERLINE_TX_PB_WARN=off POWERLINE_TX_PB_CRIT=off POWERLINE_RX_PB_WARN=off POWERLINE_RX_PB_CRIT=off
XYMON=${HERE}/bin/fixture-send XYMSRV=127.0.0.1
export PATH PL_FIXTURES PL_MESSAGES POWERLINE_CONFIG POWERLINE_HELPER POWERLINE_SUDO
export POWERLINE_IP POWERLINE_STATE_DIR POWERLINE_HOSTS POWERLINE_MAPPING POWERLINE_XYMONCFG
export POWERLINE_COLLECTOR_HOST POWERLINE_ENABLED POWERLINE_SILENT XYMON XYMSRV
export POWERLINE_TX_PHY_WARN POWERLINE_TX_PHY_CRIT POWERLINE_RX_PHY_WARN POWERLINE_RX_PHY_CRIT
export POWERLINE_TX_PB_WARN POWERLINE_TX_PB_CRIT POWERLINE_RX_PB_WARN POWERLINE_RX_PB_CRIT

# Run one independent process so every assertion also covers restart persistence.
poll() {
    POWERLINE_NOW=${1} PL_TOPOLOGY=${2:-both} PL_STATS=${3:-stats1}
    export POWERLINE_NOW PL_TOPOLOGY PL_STATS
    : >"${PL_MESSAGES}"
    # shellcheck disable=SC2086 # TESTSH intentionally supports multiword shell.
    ${TESTSH} "${REPO}/extensions/powerline/powerline.sh" </dev/null >"${TMP}/stdout" 2>"${TMP}/stderr"
}
# Assertions do not abort, so one run reports all regressions.
ok() {
    if "${@}"; then printf 'ok: powerline %s\n' "${*}"
    else printf 'FAIL: powerline %s\n' "${*}"; cat "${TMP}/stderr"; FAIL=1; fi
}
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
has() { grep -E "${1}" "${PL_MESSAGES}" >/dev/null; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
lacks() { ! has "${1}"; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
unchanged() { cmp -s "${TMP}/saved" "${POWERLINE_STATE_DIR}/state"; }

ok poll 100000 both
ok has '^status\+15 powerline1,lan.powerline green '
ok has '^status\+15 powerline3,lan.powerline green '
ok has 'pf0b01484c53c_tx_phy_mbps : 152'
ok has 'tx_pb_interval_pct : U'
ok has '^data powerline3,lan.trends'
ok has '^DS:value:GAUGE:600:0:U U$'
ok has 'rx_slot5_ber_fail : 81479001'
ok has 'tx_mpdu_collision : 55112'

ok poll 100300 both stats2
ok has 'tx_pb_interval_pct : 1.908657'
ok has 'rx_pb_interval_pct : 1.538462'
ok has 'tx_pb_pass_per_second : 4.796667'
ok has 'tx_mpdu_collision_per_second : 0.016667'
ok poll 100600 both stats2
ok has 'tx_pb_interval_pct : U'
ok has 'tx_pb_pass_per_second : 0.000000'
ok poll 100900 both stats1
ok has 'tx_pb_pass_per_second : U'
ok poll 103000 both stats2
ok has 'tx_pb_interval_pct : U'

# Every adapter status explains its abbreviations.
ok has '^  PB +PHY block'
ok has '^  MPDU +MAC protocol data unit'
ok has '^  BER +bit errors'

# The helper runs inside while-read loops: one reading stdin must not eat
# the remaining adapters (the second one would lose its PHY rates).
PL_READ_STDIN=1; export PL_READ_STDIN
ok poll 103000 both stats2
ok has '^status\+15 powerline1,lan.powerline green '
ok has '^status\+15 powerline3,lan.powerline green '
unset PL_READ_STDIN

# Neighbor expiry must preserve identity; LOC must not resolve to the server BDA.
PL_NO_NEIGHBORS=1; export PL_NO_NEIGHBORS
ok poll 103300 both stats2
ok has '^status\+15 powerline1,lan.powerline green '
ok has '^status\+15 powerline3,lan.powerline green '
unset PL_NO_NEIGHBORS

# Single removal is yellow immediately; exactly one quiet hour settles to green.
ok poll 103600 local
ok has '^status\+15 powerline3,lan.powerline yellow '
ok has '^status\+15 powerline1,lan.powerline yellow '
ok poll 106900 local
ok has '^status\+15 powerline3,lan.powerline yellow '
ok poll 107200 local
ok has '^status\+15 powerline3,lan.powerline green '
ok lacks 'Topology changed|state flapping|[Dd]isappeared'
ok has 'rx_slot5_ber_fail : U'
ok poll 107500 both
ok has '^status\+15 powerline3,lan.powerline yellow '

# Repeated transitions keep one episode; red starts at its 180-minute boundary.
ok poll 110500 local
ok poll 113500 both
ok poll 116500 local
ok poll 118300 local
ok has '^status\+15 powerline3,lan.powerline red .*state flapping'
ok poll 120100 local
ok has '^status\+15 powerline3,lan.powerline green '
ok lacks 'state flapping'

# Exact quiet-boundary transition continues the episode (no green poll).
ok poll 120400 both
ok poll 124000 local
ok poll 127600 both
ok poll 131200 local
ok has '^status\+15 powerline3,lan.powerline red .*state flapping'

# Valid first inventory without REM accepts local green; later REM is new/yellow.
POWERLINE_STATE_DIR=${TMP}/new-state; export POWERLINE_STATE_DIR
ok poll 200000 local
ok has '^status\+15 powerline1,lan.powerline green '
ok poll 200300 both
ok has '^status\+15 powerline3,lan.powerline yellow '
ok poll 204000 both stats1
POWERLINE_TX_PHY_CRIT=160; export POWERLINE_TX_PHY_CRIT
ok poll 204300 both stats2
ok has '^status\+15 powerline3,lan.powerline red '
POWERLINE_TX_PHY_CRIT=off POWERLINE_TX_PB_WARN=1
export POWERLINE_TX_PHY_CRIT POWERLINE_TX_PB_WARN
ok poll 204600 both stats1
ok poll 204900 both stats2
ok has '^status\+15 powerline3,lan.powerline yellow '
POWERLINE_TX_PB_WARN=off; export POWERLINE_TX_PB_WARN

# Empty rc=0 PHY/statistics are failures, not false green.
PL_EMPTY_RATES=1; export PL_EMPTY_RATES
ok poll 205200 both
ok has '^status\+15 powerline3,lan.powerline red '
ok has 'rx_phy_mbps : U'
unset PL_EMPTY_RATES
PL_EMPTY_STATS=1; export PL_EMPTY_STATS
ok poll 205500 both
ok has '^status\+15 powerline3,lan.powerline red '
ok has 'rx_pb_pass : U'
unset PL_EMPTY_STATS

# An adapter absent longer than the retention (default: one day) is
# forgotten entirely.
POWERLINE_STATE_DIR=${TMP}/retention-state; export POWERLINE_STATE_DIR
unset POWERLINE_RETENTION_DAYS
ok poll 400000 both
ok poll 400300 local
ok poll 486300 local
ok grep -q '^state|e8df701d65a6|' "${POWERLINE_STATE_DIR}/state"
ok has '^status\+15 powerline3,lan.powerline green '
ok poll 486500 local
ok test -z "$(grep 'e8df701d65a6' "${POWERLINE_STATE_DIR}/state")"
ok lacks 'powerline3,lan'
ok has '^status\+15 powerline1,lan.powerline green '
POWERLINE_STATE_DIR=${TMP}/new-state; export POWERLINE_STATE_DIR

# Global errors never change inventory or age it into accepted absence.
cp "${POWERLINE_STATE_DIR}/state" "${TMP}/saved"
for mode in empty broken denied; do
    if poll 210000 "${mode}"; then printf 'FAIL: accepted %s topology\n' "${mode}"; FAIL=1; fi
    ok unchanged
    ok has '^status\+15 powerline3,lan.powerline red '
done
PL_SEND_FAIL=1; export PL_SEND_FAIL
if poll 210300 both; then printf '%s\n' 'FAIL: delivery failure accepted'; FAIL=1; fi
ok unchanged
unset PL_SEND_FAIL
if poll 200000 both; then printf '%s\n' 'FAIL: backward clock accepted'; FAIL=1; fi
ok unchanged

# Dry-run performs reads but sends nothing and does not commit state.
POWERLINE_DRY_RUN=1; export POWERLINE_DRY_RUN
ok poll 210600 both
ok unchanged
ok test ! -s "${PL_MESSAGES}"
unset POWERLINE_DRY_RUN

# A lock held by another invocation causes a harmless skip.
exec 8>"${POWERLINE_STATE_DIR}/lock"
flock -n 8 || exit 1
ok poll 210900 both
ok unchanged
ok test ! -s "${PL_MESSAGES}"
flock -u 8
exec 8>&-

# Config < environment < CLI; aliases canonicalize without DNS.
printf '%s\n' 'POWERLINE_TX_PHY_CRIT=200' >"${TMP}/config"
POWERLINE_CONFIG=${TMP}/config; export POWERLINE_CONFIG
ok poll 211200 both
ok has '^status\+15 powerline3,lan.powerline green '
: >"${PL_MESSAGES}"
# shellcheck disable=SC2086
ok ${TESTSH} "${REPO}/extensions/powerline/powerline.sh" --set POWERLINE_TX_PHY_CRIT=200
ok has '^status\+15 powerline3,lan.powerline red '
POWERLINE_CONFIG=/dev/null POWERLINE_MAPPING=${TMP}/map
export POWERLINE_CONFIG POWERLINE_MAPPING
printf '%s\n' 'E8:DF:70:1D:65:A6 adapter3' >"${POWERLINE_MAPPING}"
ok poll 211500 both
ok has '^status\+15 powerline3,lan.powerline green '
printf '%s\n' 'E8:DF:70:1D:65:A6 missing.lan' >"${POWERLINE_MAPPING}"
ok poll 211800 both
ok has '^status\+15 powerline-unknown-e8df701d65a6.powerline red '

# Multiple IPs with one canonical name are safe; a conflicting name is not.
POWERLINE_MAPPING='' POWERLINE_HOSTS=${TMP}/hosts
export POWERLINE_MAPPING POWERLINE_HOSTS
cp "${HERE}/hosts" "${POWERLINE_HOSTS}"
printf '%s\n' '192.168.5.7 powerline3.lan #' >>"${POWERLINE_HOSTS}"
PL_EXTRA_IP=1; export PL_EXTRA_IP
ok poll 211900 both
ok has '^status\+15 powerline3,lan.powerline green '
printf '%s\n' '192.168.5.7 other.lan #' >>"${POWERLINE_HOSTS}"
ok poll 212100 both
ok has '^status\+15 powerline-unknown-e8df701d65a6.powerline yellow '
ok has 'Ambiguous IP-to-host mapping'
POWERLINE_MAPPING=${TMP}/map; export POWERLINE_MAPPING
printf '%s\n' 'E8:DF:70:1D:65:A6 powerline3.lan' >"${POWERLINE_MAPPING}"
ok poll 212400 both
ok has '^status\+15 powerline3,lan.powerline green '
unset PL_EXTRA_IP

# An unrelated name collision in hosts.cfg must not stop the collector: the
# real host name wins over another host's CLIENT alias, whatever the order.
printf '%s\n' '192.168.5.7 adapter3 #' >>"${POWERLINE_HOSTS}"
ok poll 212700 both
ok has '^status\+15 powerline3,lan.powerline green '
ok grep -q 'Ignoring CLIENT alias adapter3' "${TMP}/stderr"

# An alias two hosts claim resolves to neither - and costs only that name.
POWERLINE_HOSTS=${TMP}/alias-hosts; export POWERLINE_HOSTS
cp "${HERE}/hosts" "${POWERLINE_HOSTS}"
printf '%s\n' '192.168.5.9 fourth.lan # CLIENT:adapter3' >>"${POWERLINE_HOSTS}"
printf '%s\n' 'E8:DF:70:1D:65:A6 adapter3' >"${POWERLINE_MAPPING}"
ok poll 212800 both
ok has '^status\+15 powerline-unknown-e8df701d65a6.powerline red '
ok has 'ambiguous CLIENT alias'
ok has '^status\+15 powerline1,lan.powerline green '

# A configured but absent mapping file means "no mapping", not a failed poll.
POWERLINE_MAPPING=${TMP}/absent-map; export POWERLINE_MAPPING
POWERLINE_HOSTS=${HERE}/hosts; export POWERLINE_HOSTS
ok poll 212900 both
ok has '^status\+15 powerline3,lan.powerline green '
POWERLINE_MAPPING=''; export POWERLINE_MAPPING
cp "${POWERLINE_STATE_DIR}/state" "${TMP}/saved"

# Includes must not be silently ignored when xymoncfg is unavailable.
POWERLINE_HOSTS=${TMP}/include-hosts; export POWERLINE_HOSTS
printf '%s\n' 'include /etc/other-hosts.cfg' >"${POWERLINE_HOSTS}"
if poll 213000 both; then printf '%s\n' 'FAIL: ignored hosts include'; FAIL=1; fi
ok unchanged
POWERLINE_HOSTS=${HERE}/hosts; export POWERLINE_HOSTS

# Damaged state is an error, not a fresh all-green baseline.
printf '%s\n' 'broken-record' >>"${POWERLINE_STATE_DIR}/state"
if poll 213300 both; then printf '%s\n' 'FAIL: damaged state accepted'; FAIL=1; fi
cp "${TMP}/saved" "${POWERLINE_STATE_DIR}/state"

# Untrusted PLC stdout and privileged arguments cannot become code or options.
if printf '%s\n' 'TX 1 2 3% 4 5 6 0%' | awk -v mode=stats -f "${REPO}/extensions/powerline/powerline-parse.awk" >/dev/null; then
    printf '%s\n' 'FAIL: incomplete statistics accepted'; FAIL=1
fi
# An unanswered VS_SW_VER drops CHIPSET/FIRMWARE from a topology line. Those
# two fields are unused, so the inventory must survive without them.
if ! printf '%s\n' \
    ' LOC CCO 001 F0:B0:14:84:C5:3C 52:3F:1F:31:6C:DB n/a n/a' \
    ' REM STA 004 E8:DF:70:1D:65:A6 EE:DF:70:1D:65:A3 152 145' \
    | awk -v mode=topology -f "${REPO}/extensions/powerline/powerline-parse.awk" \
    | grep -q '^edge|f0b01484c53c|e8df701d65a6$'; then
    printf '%s\n' 'FAIL: topology without chipset/firmware rejected'; FAIL=1
fi
for iface in --help 'eth0;id' '../eth0' ''; do
    if sh "${REPO}/extensions/powerline/powerline-read.sh" topology "${iface}" >/dev/null 2>&1; then
        printf 'FAIL: helper accepted interface %s\n' "${iface}"; FAIL=1
    fi
done
if sh "${REPO}/extensions/powerline/powerline-read.sh" stats eth0 --help 00:00:00:00:00:01 >/dev/null 2>&1; then
    printf '%s\n' 'FAIL: helper accepted bad MAC'; FAIL=1
fi
if sh "${REPO}/extensions/powerline/powerline-read.sh" topology eth0 extra >/dev/null 2>&1; then
    printf '%s\n' 'FAIL: helper accepted extra argument'; FAIL=1
fi
# --- occasional adapters and change texts ---------------------------------
# "garage" is plugged in now and then: every change is yellow for the hold
# time with a text that says what changed, it never escalates to flapping
# (for itself or for its peer), and it is never forgotten.
POWERLINE_STATE_DIR=${TMP}/occasional-state POWERLINE_HOSTS=${TMP}/occasional-hosts
POWERLINE_MAPPING=${TMP}/occasional-map
export POWERLINE_STATE_DIR POWERLINE_HOSTS POWERLINE_MAPPING
cp "${HERE}/hosts" "${POWERLINE_HOSTS}"
printf '%s\n' '192.168.5.8 garage.lan #' >>"${POWERLINE_HOSTS}"
printf '%s\n' '02:00:00:00:00:0C garage.lan occasional' >"${POWERLINE_MAPPING}"
ok poll 500000 both
ok has '^status\+15 powerline1,lan.powerline green '
ok poll 500300 garage
ok has '^status\+15 garage,lan.powerline yellow '
ok has '^Last change 0 minute\(s\) ago: New adapter detected\.$'
ok has '^Last change 0 minute\(s\) ago: Peer added: 02000000000c \(garage\.lan\)\.$'
ok has '^status\+15 powerline1,lan.powerline yellow '
ok has '^status\+15 powerline3,lan.powerline green '
ok poll 500600 garage
ok has '^Last change 5 minute\(s\) ago: New adapter detected\.$'
ok poll 500900 both
ok has '^status\+15 garage,lan.powerline yellow '
ok has '^Last change 0 minute\(s\) ago: Adapter disappeared\.$'
ok has '^Last change 0 minute\(s\) ago: Peer lost: 02000000000c \(garage\.lan\)\.$'
# Plugged in and out for hours: an ordinary adapter would be red by now.
t=502700
while [ "${t}" -le 513500 ]; do
    if [ $(((t - 502700) / 1800 % 2)) -eq 0 ]; then ok poll "${t}" garage; else ok poll "${t}" both; fi
    t=$((t + 1800))
done
ok lacks 'state flapping'
ok has '^status\+15 garage,lan.powerline yellow '
ok has '^status\+15 powerline1,lan.powerline yellow '
ok has 'Last change 0 minute\(s\) ago: Adapter is back\.$'
ok poll 513800 both
ok poll 517500 both
ok has '^status\+15 garage,lan.powerline green '
ok has '^Adapter 02000000000c is not plugged in \(occasional adapter\)\.$'
ok has '^status\+15 powerline1,lan.powerline green '
ok lacks 'Last change'
# Never forgotten, even long past the retention of one day.
ok poll 700000 both
ok grep -q '^state|02000000000c|0|garage.lan|' "${POWERLINE_STATE_DIR}/state"
ok has '^status\+15 garage,lan.powerline green '
# Ordinary adapters still get the precise text.
ok poll 700300 local
ok has '^Last change 0 minute\(s\) ago: Adapter disappeared\.$'
ok has '^Last change 0 minute\(s\) ago: Peer lost: e8df701d65a6 \(powerline3\.lan\)\.$'
# Old state files (11 fields, before 0.29) are still accepted.
awk -F'|' '$1 == "state" { NF = 11 } 1' OFS='|' "${POWERLINE_STATE_DIR}/state" >"${TMP}/state11"
cp "${TMP}/state11" "${POWERLINE_STATE_DIR}/state"
ok poll 700600 local
ok has '^status\+15 powerline1,lan.powerline yellow '
# A third field other than "occasional" is a broken mapping.
printf '%s\n' '02:00:00:00:00:0C garage.lan sometimes' >"${POWERLINE_MAPPING}"
if poll 700900 local; then printf '%s\n' 'FAIL: bad mapping flag accepted'; FAIL=1; fi
ok grep -q 'Cannot parse static mapping' "${TMP}/stderr"

# --- FRITZ!Box view from the fritzbox collector's hand-over file ----------
POWERLINE_STATE_DIR=${TMP}/fritz-state POWERLINE_HOSTS=${HERE}/hosts POWERLINE_MAPPING=''
POWERLINE_FRITZBOX_DIR=${TMP}/fritzbox
export POWERLINE_STATE_DIR POWERLINE_HOSTS POWERLINE_MAPPING POWERLINE_FRITZBOX_DIR
mkdir -p "${POWERLINE_FRITZBOX_DIR}"
# homeplug EPOCH - the reference box's list, written at EPOCH.
homeplug() {
    {
        printf '# fritzbox homeplug fritz.box %s\n' "${1}"
        printf '%s\n' 'F0:B0:14:84:C5:3C|1|0|failed|FRITZ!Powerline 1220E|Upstairs' \
            'E8:DF:70:1D:65:A6|0|1|succeeded|FRITZ!Powerline 1260E|Downstairs'
    } >"${POWERLINE_FRITZBOX_DIR}/fritz.box.homeplug"
}
homeplug 599940
ok poll 600000 both
ok has '^status\+15 powerline1,lan.powerline green '
ok has '^FRITZ!Box view \(fritz\.box\): "Upstairs", FRITZ!Powerline 1220E, active, last firmware update failed\.$'
ok has '^status\+15 powerline3,lan.powerline yellow '
ok has '^FRITZ!Box view \(fritz\.box\): "Downstairs", FRITZ!Powerline 1260E, not active, firmware update available\.$'
ok has '^The FRITZ!Box reports this adapter as not active\.$'
POWERLINE_FRITZBOX_UPDATE_FAILED=yellow; export POWERLINE_FRITZBOX_UPDATE_FAILED
ok poll 600300 both
ok has '^status\+15 powerline1,lan.powerline yellow '
unset POWERLINE_FRITZBOX_UPDATE_FAILED
# A stale list is only noted; it colors nothing.
homeplug 599400
ok poll 600600 both
ok has '^status\+15 powerline3,lan.powerline green '
ok has '^FRITZ!Box view \(fritz\.box\): stale, 20 minute\(s\) old - is the fritzbox collector running\?$'
# An adapter missing from a fresh list is noted.
homeplug 600840
grep -v '^E8:DF' "${POWERLINE_FRITZBOX_DIR}/fritz.box.homeplug" >"${TMP}/homeplug"
mv "${TMP}/homeplug" "${POWERLINE_FRITZBOX_DIR}/fritz.box.homeplug"
ok poll 600900 both
ok has '^FRITZ!Box view: this adapter is not in the box.s adapter list\.$'
# Malformed lines and files are ignored, never fatal.
printf '%s\n' 'garbage' >"${POWERLINE_FRITZBOX_DIR}/other.homeplug"
printf '%s\n' 'F0:B0:14:84:C5:3C|x|y|z' >>"${POWERLINE_FRITZBOX_DIR}/fritz.box.homeplug"
ok poll 601200 both
ok has '^status\+15 powerline1,lan.powerline green '
rm -rf "${POWERLINE_FRITZBOX_DIR}"
ok poll 601500 both
ok lacks 'FRITZ!Box view'
unset POWERLINE_FRITZBOX_DIR
POWERLINE_STATE_DIR=${TMP}/new-state; export POWERLINE_STATE_DIR

# --- graph coverage ----------------------------------------------------
# Every emitted RRD is drawn by exactly one graph, and every graph draws at
# least one RRD. FNPATTERN is PCRE; its only PCRE-ism is "(?:", so turning
# that into "(" gives ERE for grep -E (BusyBox has no grep -P).
ok poll 300000 both
GRAPHCFG=${REPO}/extensions/powerline/server/graphs.d/powerline.cfg
awk '/^\[/ { name = substr($0, 2, length($0) - 2) }
     /^[[:space:]]*FNPATTERN / { sub(/^[[:space:]]*FNPATTERN /, ""); print name "|" $0 }' \
    "${GRAPHCFG}" >"${TMP}/patterns"
sed -n 's/^\[\(powerline,.*\.rrd\)\]$/\1/p' "${PL_MESSAGES}" | sort -u >"${TMP}/rrds"

if [ ! -s "${TMP}/patterns" ] || [ ! -s "${TMP}/rrds" ]; then
    printf '%s\n' 'FAIL: graph coverage check has no patterns or no RRDs to check'
    FAIL=1
fi

: >"${TMP}/covered"
while IFS='|' read -r gname gpat; do
    epat=$(printf '%s' "${gpat}" | sed 's/(?:/(/g')
    if grep -E "${epat}" "${TMP}/rrds" >>"${TMP}/covered"; then
        :
    else
        printf 'FAIL: graph %s matches none of the emitted RRDs\n' "${gname}"
        FAIL=1
    fi
done <"${TMP}/patterns"

sort "${TMP}/covered" | uniq -d >"${TMP}/rrd-dupes"
if [ -s "${TMP}/rrd-dupes" ]; then
    printf 'FAIL: drawn by more than one graph: %s\n' "$(tr '\n' ' ' <"${TMP}/rrd-dupes")"
    FAIL=1
else
    printf '%s\n' 'ok: powerline every RRD is drawn by exactly one graph'
fi

sort -u "${TMP}/covered" >"${TMP}/covered-uniq"
grep -Fxv -f "${TMP}/covered-uniq" "${TMP}/rrds" >"${TMP}/rrd-uncovered" || true
if [ -s "${TMP}/rrd-uncovered" ]; then
    printf 'FAIL: written but drawn by no graph: %s\n' \
        "$(tr '\n' ' ' <"${TMP}/rrd-uncovered")"
    FAIL=1
else
    printf '%s\n' 'ok: powerline no RRD is left undrawn'
fi

# The status page draws exactly the graphs defined here - a name in one list
# and not the other is either an invisible graph or a broken page entry.
SRVCFG=${REPO}/extensions/powerline/server/xymonserver.d/powerline.cfg
sed -n 's/^\[\(.*\)\]$/\1/p' "${GRAPHCFG}" | sort >"${TMP}/graph-defined"
sed -n 's/^GRAPHS_powerline="\(.*\)"$/\1/p' "${SRVCFG}" | tr ',' '\n' | sort \
    >"${TMP}/graph-listed"
if cmp -s "${TMP}/graph-defined" "${TMP}/graph-listed"; then
    printf '%s\n' 'ok: powerline GRAPHS_powerline lists exactly the defined graphs'
else
    printf 'FAIL: GRAPHS_powerline and graphs.d disagree: %s\n' \
        "$(grep -Fxv -f "${TMP}/graph-listed" "${TMP}/graph-defined" | tr '\n' ' ')$(grep -Fxv -f "${TMP}/graph-defined" "${TMP}/graph-listed" | tr '\n' ' ')"
    FAIL=1
fi

exit "${FAIL}"
