#!/bin/sh
# Exercise the fritz-wifi collector against recorded TR-064 responses.
# Program flow: build a sandbox (hosts.cfg, password file, fake curl,
# sender and logger), run the collector once per scenario, then assert
# the status and trends messages, the credential handling and the
# failure behaviour. No network access, no real Xymon.
# Usage: sh tests/fritz-wifi/run.sh [--help]
# Env: TESTSH selects the shell under test (e.g. "busybox sh").
set -u
case "${1:-}" in -h|--help) printf '%s\n' 'Usage: run.sh; TESTSH selects the collector shell. No network access.'; exit 0 ;; esac
HERE=$(CDPATH='' cd -- "$(dirname -- "${0}")" && pwd) || exit 1
REPO=$(CDPATH='' cd -- "${HERE}/../.." && pwd) || exit 1
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "${TMP}"' 0
trap 'exit 1' 1 2 15
TESTSH=${TESTSH:-sh}
FAIL=0
SCRIPT=${REPO}/extensions/fritz-wifi/fritz-wifi.sh
STATE=${TMP}/state
PASSFILE=${TMP}/fritz.passwd

# Sandbox environment; nothing of the caller's fritz-wifi setup leaks in.
for v in $(env | sed -n 's/^\(FRITZ_WIFI_[A-Z_]*\)=.*/\1/p'); do unset "${v}"; done
unset FRITZPASSWORT FW_SCENARIO FW_DOWN FW_SLOW FW_CLIENTS1 FW_CLIENTS2 FW_SEND_FAIL
PATH="${HERE}/bin:${PATH}"
FW_DATA=${HERE}/data FW_LOG=${TMP}/log FW_MESSAGES=${TMP}/messages FW_SYSLOG=${TMP}/syslog
FW_USER=xymon
# shellcheck disable=SC2089,SC2090 # The quote and backslash are password characters.
FW_PASS='geheim pass"wo\rt'
FRITZ_WIFI_CONFIG=/dev/null FRITZ_WIFI_HOSTSCFG=${HERE}/hosts FRITZ_WIFI_XYMONCFG=/nonexistent
FRITZ_WIFI_STATE_DIR=${STATE} FRITZ_WIFI_PASSFILE=${PASSFILE} FRITZ_WIFI_CURL=${HERE}/fakecurl
XYMON=${HERE}/bin/fixture-send XYMSRV=127.0.0.1
# shellcheck disable=SC2090 # See FW_PASS above.
export PATH FW_DATA FW_LOG FW_MESSAGES FW_SYSLOG FW_USER FW_PASS
export FRITZ_WIFI_CONFIG FRITZ_WIFI_HOSTSCFG FRITZ_WIFI_XYMONCFG FRITZ_WIFI_STATE_DIR
export FRITZ_WIFI_PASSFILE FRITZ_WIFI_CURL XYMON XYMSRV

# The reference password file: an IP entry that must not match, then the
# device with the default user ("-") and a password containing blanks, a
# double quote and a backslash, followed by trailing blanks.
write_passfile() {
    cat >"${PASSFILE}" <<'EOF'
# host_or_ip     user    password (rest of the line)

192.0.2.99       admin   not this one
EOF
    # printf, not the here-document: editors strip trailing blanks.
    printf '%s \t \n' 'powerline3.lan   -       geheim pass"wo\rt' >>"${PASSFILE}"
    chmod 600 "${PASSFILE}"
}

# run [ARGS...] - one independent collector process (restart persistence
# is part of every assertion). Messages, logs and output are reset.
run() {
    : >"${FW_MESSAGES}"; : >"${FW_SYSLOG}"
    rm -rf "${FW_LOG}"; mkdir -p "${FW_LOG}"
    # shellcheck disable=SC2086 # TESTSH intentionally supports a multiword shell.
    ${TESTSH} "${SCRIPT}" "${@}" </dev/null >"${TMP}/stdout" 2>"${TMP}/stderr"
    rc=${?}
    return 0
}
# Assertions do not abort, so one run reports all regressions.
ok() {
    if "${@}"; then printf 'ok: fritz-wifi %s\n' "${*}"
    else printf 'FAIL: fritz-wifi %s\n' "${*}"; sed 's/^/      /' "${TMP}/stderr"; FAIL=1; fi
}
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
not() { ! "${@}"; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
has() { grep -E -- "${1}" "${FW_MESSAGES}" >/dev/null; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
lacks() { ! has "${1}"; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
out_has() { grep -E -- "${1}" "${TMP}/stdout" >/dev/null; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
err_has() { grep -E -- "${1}" "${TMP}/stderr" >/dev/null; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
err_lacks() { ! err_has "${1}"; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
syslog_has() { grep -E -- "${1}" "${FW_SYSLOG}" >/dev/null; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
exit_is() { [ "${rc}" -eq "${1}" ]; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
no_messages() { [ ! -s "${FW_MESSAGES}" ]; }
# rrd NAME VALUE - the trends message sets wifi,NAME.rrd to VALUE with
# the split-NCV data source definition (identical RRD files).
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
rrd() {
    awk -v n="[wifi,${1}.rrd]" -v v="DS:lambda:GAUGE:600:U:U ${2}" \
        'prev == n && $0 == v { found = 1 } { prev = $0 } END { exit !found }' "${FW_MESSAGES}"
}
# no_rrd NAME - no value at all for wifi,NAME.rrd.
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
no_rrd() { ! grep -F -- "[wifi,${1}.rrd]" "${FW_MESSAGES}" >/dev/null; }
# asked PATTERN - a TR-064 action matching PATTERN reached the device.
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
asked() { grep -E -- "${1}" "${FW_LOG}/actions" >/dev/null 2>&1; }
# only_read_actions - nothing but the three read-only actions was sent.
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
only_read_actions() {
    [ ! -s "${FW_LOG}/actions" ] ||
        ! grep -Ev '^[0-9]+ (GetInfo|GetTotalAssociations|GetGenericAssociatedDeviceInfo)$' "${FW_LOG}/actions" >/dev/null
}
# ncv_safe - outside the ncv_skip block no status line may carry ":" or
# "=": xymond_rrd feeds wifi status text to the NCV parser as well.
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
ncv_safe() {
    awk '/^status/ { instatus = 1; skip = 0; next }
         /^data / { instatus = 0 }
         !instatus { next }
         /^<!-- ncv_skipstart -->$/ { skip = 1; next }
         /^<!-- ncv_skipend -->$/ { skip = 0; next }
         !skip && /[:=]/ { bad = 1 }
         END { exit bad }' "${FW_MESSAGES}"
}
# no_leak - the password appears in no output, log, argv or state file.
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
no_leak() {
    ! grep -r -F -e 'geheim' -e 'pass"wo' -e 'right secret' "${TMP}/stdout" "${TMP}/stderr" \
        "${FW_MESSAGES}" "${FW_SYSLOG}" "${FW_LOG}" "${STATE}" >/dev/null 2>&1
}
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
no_env_leak() { [ ! -e "${FW_LOG}/envleak" ]; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
state_has() { grep -qx -- "${1}" "${STATE}/powerline3.lan.names"; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
state_unchanged() { cmp -s "${TMP}/saved-state" "${STATE}/powerline3.lan.names"; }
save_state() { cp "${STATE}/powerline3.lan.names" "${TMP}/saved-state"; }

write_passfile

# --- clean poll of the reference device -------------------------------
run
ok exit_is 0
ok has '^status\+15 powerline3,lan\.wifi green .* - wifi: 2 client\(s\) on 2 AP interface\(s\)$'
ok has '^data powerline3,lan\.trends$'
ok rrd clients_wl2g_ap1 1
ok rrd clients_wl5g_ap2 1
ok rrd clients_total 2
ok rrd channel_wl2g 11
ok rrd channel_wl5g 116
ok has '^wl2g  channel=11 \(2462 MHz\)  width=20 MHz \(client\)  busy=n/a rx=n/a tx=n/a  noise=n/a$'
ok has '^wl5g  channel=116 \(5580 MHz\)  width=80 MHz \(client\)  busy=n/a rx=n/a tx=n/a  noise=n/a$'
ok has '^  &green wl2g-ap1  ssid="Steingasse"  clients=1 \[tr064\]  txpower=n/a$'
ok has '^  &green wl5g-ap2  ssid="Steingasse-5G"  clients=1 \[tr064\]  txpower=n/a$'
ok has '^         rx=n/a tx=n/a kbit/s  airtime rx=n/a tx=n/a  retries=n/a failed=n/a$'
ok has '^         standard=n  signal min/avg=92/92 \(0-100\)  speed min/avg=144/144 Mbit/s$'
ok has '^         standard=ac  signal min/avg=91/91 \(0-100\)  speed min/avg=866/866 Mbit/s$'
ok has '^<!-- ncv_skipstart -->$'
ok has '^<!-- ncv_skipend -->$'
ok ncv_safe
# The disabled guest access (instance 3) is ignored completely.
ok lacks 'Gastzugang'
ok lacks 'ap3'
ok no_rrd clients_wlan3_ap3
ok asked '^3 GetInfo$'
ok not asked '^3 GetTotalAssociations$'
# Metrics TR-064 does not provide are not created at all.
ok lacks '^\[wifi,(busy|rxpct|txpct|noise|airrx|airtx|retries|failed|rxkbps|txkbps)_'
ok only_read_actions
ok state_has clients_total
ok state_has clients_wl2g_ap1
ok state_has channel_wl5g
ok no_leak
ok no_env_leak
save_state
ok grep -q -- '--max-time 3' "${FW_LOG}/argv"

# --- an exhausted poll budget still sends a warning and unknowns ------
run --set FRITZ_WIFI_RUN_BUDGET=1
ok has '^status\+15 powerline3,lan\.wifi yellow .* - wifi: run time budget exhausted$'
ok has '^&yellow run time budget exhausted before reading the TR-064 device description$'
ok rrd clients_total U
ok rrd channel_wl5g U
ok not asked 'GetInfo'
ok state_unchanged

# --- an incomplete GetInfo must not be mistaken for disabled Wi-Fi ---
FW_SCENARIO=noenable run
ok has '^status\+15 powerline3,lan\.wifi yellow .* - wifi: TR-064 error$'
ok has '^&yellow TR-064 GetInfo on WLANConfiguration:1 returned missing or invalid NewEnable$'
ok rrd clients_wl2g_ap1 U
ok rrd clients_total U
ok state_unchanged

# --- a wrong password is a login failure, never "0 clients" ------------
FW_PASS='other' run
ok exit_is 0
ok has '^status\+15 powerline3,lan\.wifi yellow .* - wifi: authentication failed$'
ok has '^&yellow TR-064 authentication failed \(HTTP 401\)'
ok rrd clients_wl2g_ap1 U
ok rrd clients_wl5g_ap2 U
ok rrd clients_total U
ok rrd channel_wl2g U
ok lacks 'DS:lambda:GAUGE:600:U:U 0$'
ok ncv_safe
ok state_unchanged
ok syslog_has 'warning: powerline3\.lan: TR-064 authentication failed'

# --- unreachable and timeout: red, every known RRD unknown -------------
FW_DOWN=192.0.2.1 run
ok has '^status\+15 powerline3,lan\.wifi red .* - wifi: unreachable$'
ok has '^&red cannot reach TR-064 at http://192\.0\.2\.1:49000 - curl: \(7\)'
ok rrd clients_total U
ok rrd channel_wl5g U
ok err_has 'powerline3\.lan: cannot reach TR-064'
ok state_unchanged
FW_SLOW=192.0.2.1 run
ok has '^status\+15 powerline3,lan\.wifi red .* - wifi: unreachable$'
ok has 'curl: \(28\) Connection timed out'
ok rrd clients_wl2g_ap1 U

# --- 0 clients is a value; widths are then unknown ---------------------
FW_CLIENTS1=0 FW_CLIENTS2=0 run
ok has ' green .* - wifi: 0 client\(s\) on 2 AP interface\(s\)$'
ok rrd clients_wl2g_ap1 0
ok rrd clients_total 0
ok has '^wl2g  channel=11 \(2462 MHz\)  width=n/a  busy=n/a'
ok has '^         standard=n  signal=n/a  speed=n/a$'
ok not asked 'GetGenericAssociatedDeviceInfo'

# --- a client leaving mid-poll (713) is no error ------------------------
FW_SCENARIO=race713 run
ok has ' green .* - wifi: 2 client\(s\) on 2 AP interface\(s\)$'
ok rrd clients_wl2g_ap1 1
ok has '^wl2g  channel=11 \(2462 MHz\)  width=n/a'
FW_CLIENTS2=2 run
ok has ' green .* - wifi: 3 client\(s\) on 2 AP interface\(s\)$'
ok asked '^2 GetGenericAssociatedDeviceInfo$'

# --- many clients: exact count, bounded number of detail queries -------
FW_CLIENTS1=40 run
ok rrd clients_wl2g_ap1 40
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
detail_queries() { [ "$(grep -c '^1 GetGenericAssociatedDeviceInfo$' "${FW_LOG}/actions")" -eq "${1}" ]; }
ok detail_queries 32
FW_CLIENTS1=1000000 run
ok has '^&yellow TR-064 GetTotalAssociations on WLANConfiguration:1 returned no client count'
ok rrd clients_wl2g_ap1 U
ok detail_queries 0

# --- protocol errors turn yellow and leave that count unknown -----------
FW_SCENARIO=err502 run
ok has '^status\+15 powerline3,lan\.wifi yellow .* - wifi: n/a client\(s\) on 2 AP interface\(s\)$'
ok has '^&yellow TR-064 GetTotalAssociations on WLANConfiguration:1 failed \(HTTP 502\)$'
ok rrd clients_wl2g_ap1 U
ok rrd clients_wl5g_ap2 1
ok rrd clients_total U
ok has '^  &yellow wl2g-ap1  ssid="Steingasse"  clients=n/a \[tr064\]'
FW_SCENARIO=empty run
ok has '^&yellow TR-064 GetTotalAssociations on WLANConfiguration:1 returned no client count'
ok rrd clients_wl2g_ap1 U
FW_SCENARIO=notup run
ok has ' yellow .* - wifi: '
ok has '^&yellow wl5g-ap2 \(WLANConfiguration:2\) is enabled but its status is Error$'
ok has '^  &yellow wl5g-ap2  ssid="Steingasse-5G"  status=Error  clients=n/a \[tr064\]'
ok rrd clients_wl5g_ap2 U
ok rrd channel_wl5g 116
ok not asked '^2 GetTotalAssociations$'
FW_SCENARIO=desc404 run
ok has ' yellow .* - wifi: TR-064 error$'
FW_SCENARIO=nowlan run
ok has ' clear .* - wifi: not applicable$'

# --- SSIDs: quotes decoded, HTML-significant characters stay encoded ---
FW_SCENARIO=ssid run
ok has '^  &green wl2g-ap1  ssid="A&amp;B "x" &lt;y&gt;"  clients=1'

# --- password file: lookup, user column, permissions -------------------
cat >"${PASSFILE}" <<'EOF'
192.0.2.1   admin   right secret
EOF
chmod 600 "${PASSFILE}"
FW_USER=admin FW_PASS='right secret' run
ok has ' green .* - wifi: 2 client\(s\)'
ok no_leak
# A file edited on Windows (CRLF) must work as well.
printf '192.0.2.1   admin   right secret\r\n' >"${PASSFILE}"
FW_USER=admin FW_PASS='right secret' run
ok has ' green .* - wifi: 2 client\(s\)'
FW_USER=other FW_PASS='right secret' run --user other
ok has ' green .* - wifi: 2 client\(s\)'
FW_USER=xymon FW_PASS='right secret' run
ok has ' yellow .* - wifi: authentication failed$'
chmod 644 "${PASSFILE}"
FW_USER=admin FW_PASS='right secret' run
ok has ' yellow .* - wifi: no password$'
ok has 'rejected: it must be a regular file owned by uid [0-9]+ without any group/other permission \(chmod 600\)'
ok err_has 'rejected'
ok not asked 'GetInfo'
cat >"${PASSFILE}" <<'EOF'
# nothing for this device
other.lan   -   secret
broken.lan  onlytwo
other.lan   -   second
EOF
chmod 600 "${PASSFILE}"
run
ok has ' yellow .* - wifi: no password$'
ok has '^&yellow no password for powerline3\.lan or 192\.0\.2\.1 in '
ok syslog_has 'line 3: expected host, user and password'
ok syslog_has 'line 4: duplicate entry for other\.lan, line 2 wins'
rm -f "${PASSFILE}"
run
ok has '^&yellow no password for powerline3\.lan: no password file at '

# --- FRITZPASSWORT wins over the file and never reaches curl -----------
write_passfile
FRITZPASSWORT='right secret' FW_PASS='right secret' run --verbose --debug
ok has ' green .* - wifi: 2 client\(s\)'
ok no_env_leak
ok no_leak

# --- dry run and debug --------------------------------------------------
write_passfile
run
save_state
FW_SCENARIO=sid run --dry-run --debug
ok exit_is 0
ok no_messages
ok out_has '^status\+15 powerline3,lan\.wifi green '
ok out_has '^DS:lambda:GAUGE:600:U:U 116$'
ok state_unchanged
ok err_has 'debug: powerline3\.lan WLANConfiguration:1 GetInfo'
ok err_has 'NewSSID>Steingasse<'
ok err_has 'sid=XXXX'
ok err_lacks '0123456789abcdef'
ok no_leak
(unset XYMON XYMSRV; run --dry-run; exit "${rc}")
rc=${?}
ok exit_is 0
ok out_has '^data powerline3,lan\.trends$'

# --- host selection -----------------------------------------------------
FRITZ_WIFI_HOSTSCFG=${HERE}/hosts-multi FW_DOWN=192.0.2.9 run
ok has '^status\+15 powerline9,lan\.wifi yellow .* - wifi: no password$'
cat >>"${PASSFILE}" <<'EOF'
powerline9.lan  -  geheim pass"wo\rt
byname.lan      -  geheim pass"wo\rt
EOF
FRITZ_WIFI_HOSTSCFG=${HERE}/hosts-multi FW_DOWN=192.0.2.9 run
ok has '^status\+15 powerline9,lan\.wifi red .* - wifi: unreachable$'
ok has '^status\+15 powerline3,lan\.wifi green '
ok has '^status\+15 byname,lan\.wifi green '
ok grep -q 'http://byname\.lan:49000/tr64desc\.xml' "${FW_LOG}/argv"
run --host powerline3.lan --host byname.lan
ok grep -q 'http://192\.0\.2\.1:49000/tr64desc\.xml' "${FW_LOG}/argv"
ok has '^status\+15 byname,lan\.wifi green '
ok lacks 'powerline9'
FRITZ_WIFI_TAG=nosuchtag run
ok exit_is 0
ok no_messages
ok lacks 'notag'

# --- missing prerequisites and settings ---------------------------------
FRITZ_WIFI_CURL=/nonexistent/curl run
ok has '^status\+15 powerline3,lan\.wifi clear .* - wifi: not checked$'
ok lacks '^data '
FRITZ_WIFI_ENABLED=0 run
ok exit_is 0
ok no_messages
run --silent --verbose
ok exit_is 2
run --ask-password
ok exit_is 2
ok err_has 'needs a terminal'
run --bogus
ok exit_is 2
run --set FRITZ_WIFI_PORT=0
ok exit_is 1
run --set FRITZ_WIFI_USER=a:b
ok exit_is 1
run --help
ok exit_is 0
ok out_has 'FRITZPASSWORT'
run --version
ok out_has '^fritz-wifi\.sh [0-9]+\.[0-9]+\.[0-9]+$'

# --- delivery failure and the lock --------------------------------------
save_state
FW_CLIENTS1=0 FW_SEND_FAIL=1 run
ok exit_is 1
ok state_unchanged
# The caller holds the lock: the collector must leave quietly. The
# collector must not be the subshell's last command - dash would exec it
# in place, and its own reopening of the lock file would drop the lock.
: >"${FW_MESSAGES}"
(
    flock -n 9 || exit 1
    # shellcheck disable=SC2086 # TESTSH intentionally supports a multiword shell.
    ${TESTSH} "${SCRIPT}" </dev/null >"${TMP}/stdout" 2>"${TMP}/stderr"
    lockrc=${?}
    exit "${lockrc}"
) 9>"${STATE}/lock"
rc=${?}
ok exit_is 0
ok no_messages

if [ "${FAIL}" -eq 0 ]; then echo "fritz-wifi: all tests passed"; fi
exit "${FAIL}"
