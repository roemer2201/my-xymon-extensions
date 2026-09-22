#!/bin/sh
# Exercise Powerline parser, collector and state using fake tools only.
# Program flow: configure sandbox, replay snapshots/transitions, assert
# protocol messages, then check failure isolation and privileged argv guards.
# Usage: sh tests/powerline/run.sh [--help]
# Env: TESTSH selects shell under test (e.g. "busybox sh").
# Version: 1.0.0 (2026-09-22)
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
    ${TESTSH} "${REPO}/extensions/powerline/powerline.sh" >"${TMP}/stdout" 2>"${TMP}/stderr"
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
exit "${FAIL}"
