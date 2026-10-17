#!/bin/sh
# Exercise the fritzbox collector against anonymized TR-064 responses.
# Program flow: build a sandbox (hosts.cfg, password file, fake curl,
# sender and logger), run the collector once per scenario - single
# answers replaced through the override directory - then assert the
# status and trends messages, the state, the credential handling and
# the failure behaviour. No network access, no real Xymon.
# Usage: sh tests/fritzbox/run.sh [--help]
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
SCRIPT=${REPO}/extensions/fritzbox/fritzbox.sh
STATE=${TMP}/state
PASSFILE=${TMP}/fritz.passwd
OVER=${TMP}/over
# The box's clock in the fixtures: 2026-10-18T00:13:21+02:00.
N0=1792275201

# Sandbox environment; nothing of the caller's fritzbox setup leaks in.
for v in $(env | sed -n 's/^\(FRITZBOX_[A-Z_]*\)=.*/\1/p'); do unset "${v}"; done
unset FRITZPASSWORT FB_DOWN FB_NOIGD FB_SEND_FAIL
PATH="${HERE}/bin:${PATH}"
FB_DATA=${HERE}/data FB_OVER=${OVER} FB_LOG=${TMP}/log FB_MESSAGES=${TMP}/messages FB_SYSLOG=${TMP}/syslog
FB_USER=monitor
# shellcheck disable=SC2089,SC2090 # The quote and backslash are password characters.
FB_PASS='box pass"wo\rd'
FRITZBOX_CONFIG=/dev/null FRITZBOX_HOSTSCFG=${HERE}/hosts FRITZBOX_XYMONCFG=/nonexistent
FRITZBOX_STATE_DIR=${STATE} FRITZBOX_PASSFILE=${PASSFILE} FRITZBOX_CURL=${HERE}/fakecurl
FRITZBOX_LOG_RULES=${REPO}/extensions/fritzbox/fritzbox-log.rules
XYMON=${HERE}/bin/fixture-send XYMSRV=127.0.0.1
# shellcheck disable=SC2090 # See FB_PASS above.
export PATH FB_DATA FB_OVER FB_LOG FB_MESSAGES FB_SYSLOG FB_USER FB_PASS
export FRITZBOX_CONFIG FRITZBOX_HOSTSCFG FRITZBOX_XYMONCFG FRITZBOX_STATE_DIR
export FRITZBOX_PASSFILE FRITZBOX_CURL FRITZBOX_LOG_RULES XYMON XYMSRV

# The password file: an entry for another device, then the box with a
# user and a password containing blanks, a double quote and a backslash.
cat >"${PASSFILE}" <<'EOF'
# host_or_ip     user      password (rest of the line)
powerline1.lan   -         not this one
fritz.box        monitor   box pass"wo\rd
EOF
chmod 600 "${PASSFILE}"

# run [ARGS...] - one independent collector process; messages, logs and
# output are reset. FRITZBOX_NOW defaults to the fixture clock.
run() {
    : >"${FB_MESSAGES}"; : >"${FB_SYSLOG}"
    rm -rf "${FB_LOG}"; mkdir -p "${FB_LOG}" "${OVER}"
    # shellcheck disable=SC2086 # TESTSH intentionally supports a multiword shell.
    FRITZBOX_NOW=${NOW:-${N0}} ${TESTSH} "${SCRIPT}" "${@}" </dev/null >"${TMP}/stdout" 2>"${TMP}/stderr"
    rc=${?}
    return 0
}
# over FILE SED-SCRIPT - replace one fixture answer for the next runs.
over() {
    mkdir -p "${OVER}"
    sed "${2}" "${FB_DATA}/${1}" >"${OVER}/${1}"
}
reset_over() { rm -rf "${OVER}"; mkdir -p "${OVER}"; }
# Assertions do not abort, so one run reports all regressions.
ok() {
    if "${@}"; then printf 'ok: fritzbox %s\n' "${*}"
    else printf 'FAIL: fritzbox %s\n' "${*}"; sed 's/^/      /' "${TMP}/stderr"; FAIL=1; fi
}
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
not() { ! "${@}"; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
has() { grep -E -- "${1}" "${FB_MESSAGES}" >/dev/null; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
lacks() { ! has "${1}"; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
out_has() { grep -E -- "${1}" "${TMP}/stdout" >/dev/null; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
err_has() { grep -E -- "${1}" "${TMP}/stderr" >/dev/null; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
exit_is() { [ "${rc}" -eq "${1}" ]; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
no_messages() { [ ! -s "${FB_MESSAGES}" ]; }
# status COLUMN COLOR SUMMARY-ERE - the column's status headline.
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
status() { has "^status\\+15 fritz,box\\.${1} ${2} .* - [A-Za-z ]+: ${3}\$"; }
# rrd COLUMN NAME VALUE [TYPE] - the trends message sets COLUMN,NAME.rrd.
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
rrd() {
    r_min=U; [ "${4:-GAUGE}" != DERIVE ] || r_min=0
    awk -v n="[${1},${2}.rrd]" -v v="DS:lambda:${4:-GAUGE}:600:${r_min}:U ${3}" \
        'prev == n && $0 == v { found = 1 } { prev = $0 } END { exit !found }' "${FB_MESSAGES}"
}
# asked PATTERN - a request matching PATTERN reached the box.
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
asked() { grep -E -- "${1}" "${FB_LOG}/actions" >/dev/null 2>&1; }
# soap_count - number of SOAP requests (GETs excluded).
# shellcheck disable=SC2317,SC2329 # Invoked via soap_count_is.
soap_count() { grep -vc '^GET ' "${FB_LOG}/actions" 2>/dev/null || :; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
soap_count_is() { [ "$(soap_count)" -eq "${1}" ]; }
# only_read_actions - nothing but read-only actions was sent.
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
only_read_actions() {
    ! grep -Ev '^(GET |[A-Za-z0-9_]+ (Get|X_AVM-DE_Get|X_AVM_DE_Get))' "${FB_LOG}/actions" >/dev/null &&
        ! grep -E ' (GetSecurityKeys|X_AVM-DE_GetVoIPAccount|X_AVM-DE_GetClient[0-9]*)$' "${FB_LOG}/actions" >/dev/null
}
# no_leak - the password appears in no output, log, argv or state file.
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
no_leak() {
    ! grep -r -F -e 'box pass' -e 'pass"wo' "${TMP}/stdout" "${TMP}/stderr" \
        "${FB_MESSAGES}" "${FB_SYSLOG}" "${FB_LOG}" "${STATE}" >/dev/null 2>&1
}
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
no_env_leak() { [ ! -e "${FB_LOG}/envleak" ]; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
state_has() { grep -E -- "${2}" "${STATE}/fritz.box.${1}" >/dev/null 2>&1; }
snapshot() { rm -rf "${TMP}/snap"; cp -R "${STATE}" "${TMP}/snap"; }
# The homeplug hand-over file is not Xymon state: it is replaced by every
# poll that reads the adapter list, delivered or not.
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
state_unchanged() { diff -r -x lock -x '*.homeplug' "${TMP}/snap" "${STATE}" >/dev/null; }
COLUMNS='fritzdsl fritzwan fritzsys fritzlog fritzfw fritzlan fritztel'

# --- baseline poll of the reference box -----------------------------------
run
ok exit_is 0
ok status fritzdsl green 'Up at 240017/46719 kbit/s'
ok status fritzwan green 'Up'
ok status fritzsys green 'FRITZ!Box 7510 \(UI\), FRITZ!OS 8\.26, up 61d 20h 39m'
ok status fritzlog green 'baseline of 10 entries'
ok status fritzfw green '1 port mapping\(s\)'
ok status fritzlan green '4 of 6 hosts active'
ok status fritztel green '3/3 SIP account\(s\) registered'
ok has '^data fritz,box\.trends$'
# fritzdsl keeps the RRD names and DS types of the former NCV extension.
ok rrd fritzdsl rate_down 240017
ok rrd fritzdsl margin_down 9.0
ok rrd fritzdsl atten_up 13.0
ok rrd fritzdsl crc 3102 DERIVE
ok rrd fritzdsl atuc_crc 30 DERIVE
ok rrd fritzdsl uptime 69660
ok has '^    modulation       VDSL, profile 35b$'
ok has '^    far end \(ATU-C\)  crc=30 fec=532305 hec=0$'
# fritzwan: the IGD link rate (the box's own 100%), 64-bit counters.
ok rrd fritzwan maxbps_down 233094000
ok rrd fritzwan bps_down U
ok has '^    link capacity    down=233\.1 up=45\.5 Mbit/s \[UPnP\]$'
ok has '\[UPnP 64-bit counters\]$'
ok rrd fritzsys uptime 5344796
ok rrd fritzsys clock_offset 0
ok has '^    box time         2026-10-18T00:13:21\+02:00 \(offset 0 s\)$'
ok rrd fritzlog voip_fail U
ok rrd fritzlog unmatched U
# Old entries carry no color icon on the baseline.
ok has '^    - 14\.10\.26 09:45:32 \[voip_fail\] Internettelefonie mit 4930123456 '
ok lacks '^  &yellow 14\.10\.26'
ok rrd fritzfw portmaps 1
ok has '^    on  TCP:2222:192\.0\.2\.22:22 SSH-Server$'
ok has 'upnp=1 upnp_portmapping=1 remote_access=0'
ok has '^baseline: changes are reported from the next poll$'
ok lacks 'remoteuser|ddnsuser|owner@example|box\.example\.net|abc\.myfritz'
ok rrd fritzlan hosts_total 6
ok rrd fritzlan hosts_active 4
ok rrd fritzlan active_wlan 2
ok rrd fritzlan guests_active 1
ok lacks 'host[0-9]|device[0-9]|02:00:00:00:10'
ok rrd fritztel sip_registered 3
ok has '^  &green SIP account 1: 301234568 via sip\.example\.net$'
ok has '^    DECT 1: "Handset 1" active=0 update available=0$'
ok only_read_actions
ok no_leak
ok no_env_leak
ok grep -q -- '--digest --ntlm --config -' "${FB_LOG}/argv"
ok not grep -q -e '--anyauth' -e '--basic' "${FB_LOG}/argv"
# One login probe, then the modules; the GETs carry no credentials.
ok asked '^GET /tr64desc\.xml$'
ok asked '^GET /devicehostlist\.lua$'
ok state_has dsl '^1792275201 3102 69660$'
ok state_has wan '^1792275201 902062269148 186340859835 64$'
ok state_has log '^last 261017050731 1$'
ok state_has fritzdsl.names '^crc DERIVE$'
ok state_has homeplug '^# fritzbox homeplug fritz\.box 1792275201$'
ok state_has homeplug '^02:00:00:00:00:A1\|1\|0\|failed\|FRITZ!Powerline 1220E\|Upstairs$'
ok state_has homeplug '^02:00:00:00:00:A3\|1\|0\|failed\|FRITZ!Powerline 1260E\|Downstairs$'

# --- five minutes later: rates, CRC warning, new log entries, a change ------
NOW=$((N0 + 300))
over igdupnp_control_WANCommonIFC1__GetAddonInfos.xml \
    's/>902062269148</>902099769148</; s/>186340859835</>186344609835</'
over lanethernetifcfg__GetStatistics.xml 's/>243840809260</>243844559260</; s/>926989326008</>927026826008</'
over wandslifconfig1__GetStatisticsTotal.xml 's/<NewCRCErrors>3102</<NewCRCErrors>3252</'
over wanpppconn1__GetGenericPortMappingEntry__0.xml 's/>2222</>2223</'
over deviceinfo__GetDeviceLog.xml 's|<NewDeviceLog>|<NewDeviceLog>18.10.26 00:11:00 Neue unbekannte Meldung XYZ.\
18.10.26 00:10:00 Internettelefonie mit 4930123456 \&#252;ber sip.example.net war nicht erfolgreich. Ursache: Request Timeout (408)\
|'
run
ok exit_is 0
ok rrd fritzwan bps_down 1000000
ok rrd fritzwan bps_up 100000
ok rrd fritzwan util_down 0.4
ok status fritzwan green 'Up, 1\.0/0\.1 Mbit/s \(down/up\)'
ok rrd fritzlan bps_in 100000
ok rrd fritzlan bps_out 1000000
ok status fritzdsl yellow 'Up at 240017/46719 kbit/s'
ok has '^&yellow CRC errors: 30\.0/min since the last poll \(limit 30/min\)$'
ok status fritzlog yellow '2 new entries'
ok has '^&yellow 18\.10\.26 00:11:00 \[unmatched\] Neue unbekannte Meldung XYZ\. \(60 min left\)$'
ok has '^&yellow 18\.10\.26 00:10:00 \[voip_fail\] Internettelefonie mit 4930123456 '
ok has '^  &yellow 18\.10\.26 00:11:00 \[unmatched\] \(new\) Neue unbekannte Meldung XYZ\.$'
ok rrd fritzlog voip_fail 1
ok rrd fritzlog unmatched 1
ok rrd fritzlog reconnect 0
ok status fritzfw yellow '1 port mapping\(s\)'
ok has "^&yellow port mappings changed: now 'TCP:2223:192\\.0\\.2\\.22:22', before 'TCP:2222:192\\.0\\.2\\.22:22' \\(60 min left\\)\$"

# --- still held ten minutes later, nothing new ------------------------------
NOW=$((N0 + 900))
run
ok status fritzlog yellow '0 new entries'
ok has '\[unmatched\] Neue unbekannte Meldung XYZ\. \(50 min left\)$'
ok rrd fritzlog unmatched 0
ok status fritzfw yellow '1 port mapping\(s\)'
# --- and green after the hold time -------------------------------------
NOW=$((N0 + 300 + 3600))
run
ok status fritzlog green '0 new entries'
ok status fritzfw green '1 port mapping\(s\)'
ok status fritzdsl green 'Up at 240017/46719 kbit/s'
reset_over

# --- a wrong password: one refused request, every column yellow, unknowns --
NOW=$((N0 + 4200))
FB_PASS=other run
ok exit_is 0
for c in ${COLUMNS}; do ok status "${c}" yellow 'authentication failed'; done
ok has '^&yellow TR-064 authentication failed \(HTTP 401\) - check user and password for fritz\.box$'
# The 401 is answered before the action is logged: one request was sent.
ok soap_count_is 0
ok test "$(grep -c -- '--data' "${FB_LOG}/argv")" -eq 1
ok rrd fritzdsl crc U DERIVE
ok rrd fritzlan hosts_active U
ok rrd fritztel sip_total U

# --- an unreachable box: red, unknowns, state kept ---------------------------
snapshot
FB_DOWN=192.0.2.1 run
ok exit_is 0
for c in ${COLUMNS}; do ok status "${c}" red 'unreachable'; done
ok has '^&red cannot reach TR-064 at http://192\.0\.2\.1:49000 - curl: \(7\) Failed to connect'
ok rrd fritzdsl rate_down U
ok rrd fritzwan bps_down U
ok state_unchanged
NOW=''

# --- an exhausted run budget never starts a request --------------------------
run --set FRITZBOX_RUN_BUDGET=1
for c in ${COLUMNS}; do ok status "${c}" yellow 'run time budget exhausted'; done
ok not asked .

# --- no password for the selected host ---------------------------------------
run --host otherbox.lan
ok has '^status\+15 otherbox,lan\.fritzsys yellow .* - System: no password$'
ok has "^&yellow no password for otherbox\\.lan or 192\\.0\\.2\\.3 in ${PASSFILE}\$"
ok not asked .

# --- fritzsys: update, reboot, clock, failed update ---------------------------
over userif__GetInfo.xml 's|<NewUpgradeAvailable>0<|<NewUpgradeAvailable>1<|; s|<NewX_AVM-DE_Version><|<NewX_AVM-DE_Version>271.08.30<|'
over deviceinfo__GetInfo.xml 's|<NewUpTime>5344796<|<NewUpTime>600<|'
over userif__X_AVM-DE_GetInfo.xml 's|>succeeded<|>failed<|'
NOW=$((N0 - 400)) run --set FRITZBOX_MODULES=sys
ok status fritzsys red 'FRITZ!Box 7510 \(UI\), FRITZ!OS 8\.26, up 0d 0h 10m'
ok has '^&yellow FRITZ!OS update available: 271\.08\.30$'
ok has '^&yellow the box restarted 10 minute\(s\) ago$'
ok has '^&red box clock is off by 400 s \(limit 300 s\)$'
ok has '^Note: the last FRITZ!OS update failed \(2026-08-17T03:36:34\+02:00\)$'
ok rrd fritzsys clock_offset 400
ok lacks 'fritzdsl|fritzlog'
ok not asked 'x_homeplug'
NOW=$((N0 + 100)) run --set FRITZBOX_MODULES=sys --set FRITZBOX_SYS_UPDATE_COLOR=green \
    --set FRITZBOX_SYS_UPDATE_FAILED_COLOR=yellow --set FRITZBOX_HOLD_MINUTES=5
ok status fritzsys yellow 'FRITZ!Box 7510 \(UI\), FRITZ!OS 8\.26, up 0d 0h 10m'
ok has '^&yellow box clock is off by -100 s \(limit 60 s\)$'
ok has '^Note: FRITZ!OS update available: 271\.08\.30$'
ok has '^&yellow the last FRITZ!OS update failed'
ok lacks 'restarted'
reset_over

# --- fritztel: an unregistered account is red; masking ------------------------
over x_voip__X_AVM-DE_GetVoIPStatus__1.xml 's|>registered<|>unregistered<|'
run --set FRITZBOX_MODULES=tel --set FRITZBOX_MASK=1
ok status fritztel red '2/3 SIP account\(s\) registered'
ok has '^&red SIP account 1 \(##### via sip\.example\.net\) is not registered: unregistered$'
ok lacks '30123456'
rm -f "${OVER}/x_voip__X_AVM-DE_GetVoIPStatus__1.xml"
over x_voip__X_AVM-DE_GetVoIPAccounts.xml 's|&lt;AccountList&gt;.*&lt;/AccountList&gt;|\&lt;AccountList\&gt;\&lt;/AccountList\&gt;|'
run --set FRITZBOX_MODULES=tel
ok status fritztel clear 'no SIP accounts'
reset_over

# --- fritzlan: required devices, new MACs -------------------------------------
run --set FRITZBOX_MODULES=lan --set 'FRITZBOX_LAN_REQUIRED=02:00:00:00:10:03=nas 02-00-00-00-10-01' \
    --set FRITZBOX_LAN_NEW_MAC=1
ok status fritzlan yellow '4 of 6 hosts active'
ok has '^&yellow required device 02:00:00:00:10:03 \(nas\) is not active$'
ok has '^required device 02:00:00:00:10:01 is active$'
ok has '^baseline of known MACs: new devices are reported from the next poll$'
over hostlist.xml 's|</List>|<Item><Index>7</Index><MACAddress>02:00:00:00:10:07</MACAddress><Active>1</Active><InterfaceType>802.11</InterfaceType><X_AVM-DE_Guest>0</X_AVM-DE_Guest></Item></List>|'
run --set FRITZBOX_MODULES=lan --set FRITZBOX_LAN_NEW_MAC=1
ok status fritzlan yellow '5 of 7 hosts active'
ok has '^&yellow new device 02:00:00:00:10:07 in the host list \(60 min left\)$'
run --set FRITZBOX_MODULES=lan --set FRITZBOX_LAN_NEW_MAC=1
ok has '^&yellow new device 02:00:00:00:10:07 in the host list \(60 min left\)$'
NOW=$((N0 + 3700)) run --set FRITZBOX_MODULES=lan --set FRITZBOX_LAN_NEW_MAC=1
ok status fritzlan green '5 of 7 hosts active, 0\.0/0\.0 Mbit/s to/from LAN'
reset_over

# --- fritzfw: expected mappings --------------------------------------------------
run --set FRITZBOX_MODULES=fw --set 'FRITZBOX_FW_EXPECTED=TCP:2222:192.0.2.22:22'
ok status fritzfw green '1 port mapping\(s\)'
run --set FRITZBOX_MODULES=fw --set 'FRITZBOX_FW_EXPECTED=UDP:1194:192.0.2.9:1194' --set FRITZBOX_FW_COLOR=red
ok status fritzfw red '1 port mapping\(s\)'
ok has '^&red port mapping TCP:2222:192\.0\.2\.22:22 is not in FRITZBOX_FW_EXPECTED$'
ok has '^&red expected port mapping UDP:1194:192\.0\.2\.9:1194 is missing$'

# --- fritzwan: TR-064 only, 32-bit wrap and reset, no IGD -----------------------
run --set FRITZBOX_MODULES=wan --set FRITZBOX_WAN_MODE=tr064
ok has '^    link capacity    down=268\.3 up=47\.4 Mbit/s \[TR-064\]$'
ok has '\[TR-064 64-bit counters\]$'
ok not asked '^igdupnp'
over wancommonifconfig1__GetTotalBytesReceived.xml 's|>902812111894<|>200<|'
over wancommonifconfig1__GetTotalBytesSent.xml 's|>191423805702<|>1000<|'
printf '%s 4294967000 600 32\n' "$((N0 - 300))" >"${STATE}/fritz.box.wan"
run --set FRITZBOX_MODULES=wan --set FRITZBOX_WAN_MODE=tr064
# rx wrapped (previous value in the upper half): 496 bytes in 300 s.
ok rrd fritzwan bps_down 13
ok rrd fritzwan bps_up 11
printf '%s 1000 600 32\n' "$((N0 - 300))" >"${STATE}/fritz.box.wan"
run --set FRITZBOX_MODULES=wan --set FRITZBOX_WAN_MODE=tr064
# rx went backwards from a low value: a reset, no rate this round.
ok rrd fritzwan bps_down U
reset_over
FB_NOIGD=1 run --set FRITZBOX_MODULES='wan fw'
ok has '^    link capacity    down=268\.3 up=47\.4 Mbit/s \[TR-064\]$'
ok lacks '^Settings: .*upnp_portmapping'
FB_NOIGD=1 run --set FRITZBOX_MODULES=wan --set FRITZBOX_WAN_MODE=igd
ok status fritzwan clear 'UPnP status info disabled'

# --- fritzdsl: low margin, missing service ---------------------------------------
over wandslifconfig1__GetInfo.xml 's|<NewDownstreamNoiseMargin>90<|<NewDownstreamNoiseMargin>25<|'
run --set FRITZBOX_MODULES=dsl
ok status fritzdsl red 'Up at 240017/46719 kbit/s'
ok has '^&red downstream noise margin 2\.5 dB is below 3 dB$'
reset_over
over tr64desc.xml '/WANDSLInterfaceConfig/d'
run --set FRITZBOX_MODULES=dsl
ok status fritzdsl clear 'no DSL interface'
reset_over

# --- fritzlog: blanks instead of line breaks, reset, missing rules --------------
rm -f "${STATE}/fritz.box.log"
mkdir -p "${OVER}"
tr '\n' ' ' <"${FB_DATA}/deviceinfo__GetDeviceLog.xml" >"${OVER}/deviceinfo__GetDeviceLog.xml"
run --set FRITZBOX_MODULES=log
ok status fritzlog green 'baseline of 10 entries'
printf 'last 991231235959 1\n' >"${STATE}/fritz.box.log"
run --set FRITZBOX_MODULES=log
ok status fritzlog green 'new baseline of 10 entries'
ok state_has log '^last 261017050731 1$'
run --set FRITZBOX_MODULES=log --set FRITZBOX_LOG_RULES=/nonexistent
ok status fritzlog yellow '0 new entries'
ok has '^&yellow rules file /nonexistent is not readable'
reset_over

# --- dry run: printed, nothing sent, state kept ------------------------------------
snapshot
run --dry-run
ok exit_is 0
ok no_messages
ok out_has '^status\+15 fritz,box\.fritzdsl green '
ok out_has '^data fritz,box\.trends$'
ok state_unchanged

# --- settings, help, disabled ---------------------------------------------------------
run --help
ok exit_is 0
ok out_has 'FRITZPASSWORT'
run --version
ok out_has '^fritzbox\.sh [0-9]+\.[0-9]+\.[0-9]+$'
run --set FRITZBOX_USER=a:b
ok exit_is 1
run --set FRITZBOX_MODULES=foo
ok exit_is 1
ok err_has 'Unknown module in FRITZBOX_MODULES: foo'
run --set FRITZBOX_SYS_UPDATE_COLOR=blue
ok exit_is 1
run --set FRITZBOX_ENABLED=0
ok exit_is 0
ok no_messages
ok not asked .

# --- the password file must be private ---------------------------------------------
chmod 644 "${PASSFILE}"
run --set FRITZBOX_MODULES=sys
ok status fritzsys yellow 'no password'
ok has 'password file .* rejected'
chmod 600 "${PASSFILE}"

# --- delivery failure and the lock -------------------------------------------------------
snapshot
FB_SEND_FAIL=1 run
ok exit_is 1
ok state_unchanged
# The caller holds the lock: the collector must leave quietly. The
# collector must not be the subshell's last command - dash would exec it
# in place, and its own reopening of the lock file would drop the lock.
: >"${FB_MESSAGES}"
(
    flock -n 9 || exit 1
    # shellcheck disable=SC2086 # TESTSH intentionally supports a multiword shell.
    FRITZBOX_NOW=${N0} ${TESTSH} "${SCRIPT}" </dev/null >"${TMP}/stdout" 2>"${TMP}/stderr"
    lockrc=${?}
    exit "${lockrc}"
) 9>"${STATE}/lock"
rc=${?}
ok exit_is 0
ok no_messages

if [ "${FAIL}" -eq 0 ]; then echo "fritzbox: all tests passed"; fi
exit "${FAIL}"
