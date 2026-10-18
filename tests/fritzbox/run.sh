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
# copy_state DIR - the state files without the lock and the homeplug
# hand-over file, which is not Xymon state: it is replaced by every poll
# that reads the adapter list, delivered or not. (No "diff -x": BusyBox.)
copy_state() {
    rm -rf "${1}"; mkdir -p "${1}"
    for f in "${STATE}"/*; do
        case "${f}" in */lock|*.homeplug|*/run.*) continue ;; esac
        [ ! -f "${f}" ] || cp "${f}" "${1}/"
    done
}
snapshot() { copy_state "${TMP}/snap"; }
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
state_unchanged() { copy_state "${TMP}/now" && diff -r "${TMP}/snap" "${TMP}/now" >/dev/null; }
# ncv_matches_trends - what Xymon's NCV parser (xymond/rrd/do_ncv.c:
# directives at the start of a line, "name : value" or "name = value",
# split-NCV name mangling) would read from each status equals the known
# values of the column's trends message.
# shellcheck disable=SC2317,SC2329 # Invoked via ok's command argument.
ncv_matches_trends() {
    rm -f "${TMP}/ncv" "${TMP}/tr"
    awk -v nf="${TMP}/ncv" -v tf="${TMP}/tr" '
        /^status\+/ { col = $2; sub(/^[^.]*\./, "", col); mode = "ncv"; skip = 0; next }
        /^data / { mode = "trends"; next }
        mode == "ncv" && /^[ \t]*<!-- ncv_skipstart -->/ { skip = 1; next }
        mode == "ncv" && /^[ \t]*<!-- ncv_skipend -->/ { skip = 0; next }
        mode == "ncv" && /^[ \t]*<!-- ncv_end -->/ { mode = ""; next }
        mode == "ncv" && !skip && match($0, /[:=]/) {
            n = substr($0, 1, RSTART - 1); v = substr($0, RSTART + 1)
            sub(/^[ \t]+/, "", n); gsub(/[^A-Za-z0-9]+/, "_", n); sub(/_$/, "", n)
            sub(/^[ \t]+/, "", v)
            if (match(v, /^[-+]?[0-9.eE+-]+([ \t]|$)/)) {
                v = substr(v, 1, RLENGTH); sub(/[ \t]$/, "", v); print col, n, v > nf
            }
            next
        }
        mode == "trends" && /^\[/ { r = $0; sub(/^\[[^,]*,/, "", r); sub(/\.rrd\]$/, "", r); next }
        mode == "trends" && /^DS:/ && $2 != "U" { print col, r, $2 > tf }
    ' "${FB_MESSAGES}" || return 1
    [ -s "${TMP}/ncv" ] && sort "${TMP}/ncv" >"${TMP}/ncv.s" && sort "${TMP}/tr" >"${TMP}/tr.s" &&
        cmp -s "${TMP}/ncv.s" "${TMP}/tr.s"
}
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
ok rrd fritzdsl reconnect 0 DERIVE
ok has '^    modulation       VDSL, profile 35b$'
ok has '^    far end \(ATU-C\)  crc=30 fec=532305 hec=0$'
# fritzwan: the IGD link rate (the box's own 100%), 64-bit counters.
ok rrd fritzwan maxbps_down 233094000
ok rrd fritzwan bps_down U
ok has '^    link capacity    down=233\.1 up=45\.5 Mbit/s \[UPnP\]$'
ok has '\[UPnP 64-bit counters\]$'
ok rrd fritzwan link_up 1
ok rrd fritzwan connected 1
ok has '^    connection       Connected \(PPP\), up 0d 19h 21m$'
ok rrd fritzwan pps_down U
ok lacks '^    packets '
# The values also travel as a hidden NCV block after the visible text.
ok has '^<!-- ncv_skipstart -->$'
ok has '^rate_down : 240017$'
ok lacks '^bps_down : '
ok has '^<!-- ncv_end -->$'
ok ncv_matches_trends
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
ok has '^  &green SIP account 1: 301234568 via sip\.example\.net \(registered\)$'
ok has '^    DECT 1: "Handset 1" not connected, update available=0$'
ok only_read_actions
ok no_leak
ok no_env_leak
ok grep -q -- '--digest --ntlm --config -' "${FB_LOG}/argv"
ok not grep -q -e '--anyauth' -e '--basic' "${FB_LOG}/argv"
# One login probe, then the modules; the GETs carry no credentials.
ok asked '^GET /tr64desc\.xml$'
ok asked '^GET /devicehostlist\.lua$'
ok state_has dsl '^1792275201 3102 69660 0$'
ok state_has wan '^1792275201 902062269148 186340859835 64 igd$'
ok state_has wanpkt '^1792275201 781496626 423526819 32 igd$'
ok state_has log '^last 261017050731 1$'
ok state_has fritzdsl.names '^crc DERIVE$'
ok state_has homeplug '^# fritzbox homeplug fritz\.box 1792275201$'
ok state_has homeplug '^02:00:00:00:00:A1\|1\|0\|failed\|FRITZ!Powerline 1220E\|Upstairs$'
ok state_has homeplug '^02:00:00:00:00:A3\|1\|0\|failed\|FRITZ!Powerline 1260E\|Downstairs$'

# --- five minutes later: rates, CRC warning, new log entries, a change ------
NOW=$((N0 + 300))
over igdupnp_control_WANCommonIFC1__GetAddonInfos.xml \
    's/>902062269148</>902099769148</; s/>186340859835</>186344609835</'
over igdupnp_control_WANCommonIFC1__GetTotalPacketsReceived.xml 's/>781496626</>781796626</'
over igdupnp_control_WANCommonIFC1__GetTotalPacketsSent.xml 's/>423526819</>423676819</'
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
ok rrd fritzwan pps_down 1000
ok rrd fritzwan pps_up 500
ok has '^    packets          down=1000 up=500 per second \(average since the last poll\)$'
ok status fritzwan green 'Up, 1\.0/0\.1 Mbit/s \(down/up\)'
ok rrd fritzlan bps_in 100000
ok rrd fritzlan bps_out 1000000
ok ncv_matches_trends
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
# "not registered" with its blank, as documented (TR-064_VoIP.pdf).
over x_voip__X_AVM-DE_GetVoIPStatus__1.xml 's|>registered<|>not registered<|'
run --set FRITZBOX_MODULES=tel --set FRITZBOX_MASK=1
ok status fritztel red '2/3 SIP account\(s\) registered'
ok has '^&red SIP account 1 \(##### via sip\.example\.net\) is not registered, status: not registered$'
ok lacks '30123456'
# A disabled account is listed, but neither counted nor an alarm.
over x_voip__X_AVM-DE_GetVoIPStatus__1.xml 's|>registered<|>disabled<|'
run --set FRITZBOX_MODULES=tel
ok status fritztel green '2/2 SIP account\(s\) registered'
ok has '^    SIP account 1: 301234568 via sip\.example\.net \(disabled\)$'
for i in 0 1 2; do over "x_voip__X_AVM-DE_GetVoIPStatus__${i}.xml" 's|>registered<|>disabled<|'; done
run --set FRITZBOX_MODULES=tel
ok status fritztel clear 'no SIP accounts'
reset_over
over x_voip__X_AVM-DE_GetVoIPAccounts.xml 's|&lt;AccountList&gt;.*&lt;/AccountList&gt;|\&lt;AccountList\&gt;\&lt;/AccountList\&gt;|'
run --set FRITZBOX_MODULES=tel
ok status fritztel clear 'no SIP accounts'
reset_over

# DECT connection text must distinguish missing/invalid data from zero.
over x_dect__GetGenericDectEntry__0.xml 's|<NewActive>0</NewActive>|<NewActive>1</NewActive>|'
run --set FRITZBOX_MODULES=tel
ok has '^    DECT 1: "Handset 1" connected, update available=0$'
for dect_active in '' 2 invalid1; do
    over x_dect__GetGenericDectEntry__0.xml "s|<NewActive>0</NewActive>|<NewActive>${dect_active}</NewActive>|"
    run --set FRITZBOX_MODULES=tel
    ok status fritztel green '3/3 SIP account\(s\) registered'
    ok has '^    DECT 1: "Handset 1" connection state unknown, update available=0$'
done
over x_dect__GetGenericDectEntry__0.xml '/<NewActive>/d'
run --set FRITZBOX_MODULES=tel
ok has '^    DECT 1: "Handset 1" connection state unknown, update available=0$'
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
printf '%s 4294967000 600 32 tr064\n' "$((N0 - 300))" >"${STATE}/fritz.box.wan"
run --set FRITZBOX_MODULES=wan --set FRITZBOX_WAN_MODE=tr064
# rx wrapped (previous value in the upper half): 496 bytes in 300 s.
ok rrd fritzwan bps_down 13
ok rrd fritzwan bps_up 11
printf '%s 1000 600 32 tr064\n' "$((N0 - 300))" >"${STATE}/fritz.box.wan"
run --set FRITZBOX_MODULES=wan --set FRITZBOX_WAN_MODE=tr064
# rx went backwards from a low value: a reset, no rate this round.
ok rrd fritzwan bps_down U
# A state of 0.30.0 and earlier names no source: no rate this round.
printf '%s 100 600 32\n' "$((N0 - 300))" >"${STATE}/fritz.box.wan"
run --set FRITZBOX_MODULES=wan --set FRITZBOX_WAN_MODE=tr064
ok rrd fritzwan bps_down U
ok state_has wan '^1792275201 200 1000 32 tr064$'
reset_over
# IGD and TR-064 count differently: a change of source is no rate, the
# packet counters come from the same source as the byte counters.
printf '%s 902812000000 191423000000 64 igd\n' "$((N0 - 300))" >"${STATE}/fritz.box.wan"
printf '%s 784000000 428500000 32 igd\n' "$((N0 - 300))" >"${STATE}/fritz.box.wanpkt"
run --set FRITZBOX_MODULES=wan --set FRITZBOX_WAN_MODE=tr064
ok rrd fritzwan bps_down U
ok rrd fritzwan pps_down U
ok state_has wanpkt '^1792275201 784019552 428560384 32 tr064$'
ok asked '^wancommonifconfig1 GetTotalPacketsSent$'
ok not asked '^igdupnp'
NOW=$((N0 + 300)) run --set FRITZBOX_MODULES=wan --set FRITZBOX_WAN_MODE=tr064
ok rrd fritzwan pps_down 0
# A failed IGD packet request falls back to TR-064 within the poll.
cp "${FB_DATA}/fault401.xml" "${OVER}/igdupnp_control_WANCommonIFC1__GetTotalPacketsSent.xml"
NOW=$((N0 + 600)) run --set FRITZBOX_MODULES=wan
ok state_has wanpkt ' tr064$'
ok rrd fritzwan pps_up 0
ok state_has wan ' 64 igd$'
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

# --- fritzlog: long texts end after 300 bytes, never inside a UTF-8
# character, and are masked before the cut (a cut address stays hidden).
rm -f "${STATE}/fritz.box.log"
run --set FRITZBOX_MODULES=log
l_uml=$(printf '\303\244')
l_x=$(awk 'BEGIN { while (i++ < 299) printf "x" }')
l_y=$(awk 'BEGIN { while (i++ < 290) printf "y" }')
over deviceinfo__GetDeviceLog.xml "s|<NewDeviceLog>|<NewDeviceLog>18.10.26 00:12:00 ${l_x}${l_uml}tail\\
18.10.26 00:11:00 ${l_y} 203.0.113.250\\
|"
run --set FRITZBOX_MODULES=log --set FRITZBOX_MASK=1
ok status fritzlog yellow '2 new entries'
ok has '^  &yellow 18\.10\.26 00:12:00 \[unmatched\] \(new\) x{299}$'
ok has '^  &yellow 18\.10\.26 00:11:00 \[unmatched\] \(new\) y{290} x\.x\.x\.x$'
ok has '^&yellow 18\.10\.26 00:12:00 \[unmatched\] x{270} \(60 min left\)$'
ok has '^&yellow 18\.10\.26 00:11:00 \[unmatched\] y{270} \(60 min left\)$'
ok lacks '203\.0\.113'
reset_over

# --- failed DSL statistics must not become a zero counter baseline ---------
NOW=$((N0 + 300))
cp "${FB_DATA}/fault401.xml" "${OVER}/wandslifconfig1__GetStatisticsTotal.xml"
run --set FRITZBOX_MODULES=dsl
ok status fritzdsl yellow 'Up at 240017/46719 kbit/s'
ok rrd fritzdsl crc U DERIVE
NOW=$((N0 + 600))
reset_over
run --set FRITZBOX_MODULES=dsl
ok status fritzdsl green 'Up at 240017/46719 kbit/s'
ok lacks 'CRC errors:'
NOW=''

# --- connected SIP accounts and documented text statuses in the list -------
over x_voip__X_AVM-DE_GetVoIPStatus__1.xml 's|>registered<|>connected<|'
run --set FRITZBOX_MODULES=tel
ok status fritztel green '3/3 SIP account\(s\) registered'
reset_over
over x_voip__X_AVM-DE_GetVoIPAccounts.xml 's|X_AVM-DE_VoIPStatus&gt;2&lt;|X_AVM-DE_VoIPStatus\&gt;connected\&lt;|g'
for i in 0 1 2; do cp "${FB_DATA}/fault401.xml" "${OVER}/x_voip__X_AVM-DE_GetVoIPStatus__${i}.xml"; done
run --set FRITZBOX_MODULES=tel
ok status fritztel green '3/3 SIP account\(s\) registered'
reset_over

# --- incomplete telephony data is unknown rather than zero accounts --------
cp "${FB_DATA}/fault401.xml" "${OVER}/x_voip__X_AVM-DE_GetVoIPAccounts.xml"
run --set FRITZBOX_MODULES=tel
ok status fritztel yellow 'SIP account list unavailable'
ok rrd fritztel sip_total U
ok rrd fritztel sip_registered U
reset_over

# --- a truncated port list cannot replace the exposure baseline ------------
cp "${STATE}/fritz.box.fw" "${TMP}/fw.before"
over wanpppconn1__GetPortMappingNumberOfEntries.xml 's|>1<|>33<|'
i=1
while [ "${i}" -le 31 ]; do
    cp "${FB_DATA}/wanpppconn1__GetGenericPortMappingEntry__0.xml" "${OVER}/wanpppconn1__GetGenericPortMappingEntry__${i}.xml"
    i=$((i + 1))
done
run --set FRITZBOX_MODULES=fw
ok status fritzfw yellow 'port mapping list incomplete'
ok rrd fritzfw portmaps U
ok cmp -s "${STATE}/fritz.box.fw" "${TMP}/fw.before"
reset_over

# --- an entry vanishing during the poll (713) is one note, not two --------
over wanpppconn1__GetPortMappingNumberOfEntries.xml 's|>1<|>2<|'
run --set FRITZBOX_MODULES=fw
ok status fritzfw yellow 'port mapping list incomplete'
ok has '^&yellow WANPPPConnection:1 GetGenericPortMappingEntry failed \(HTTP 500, UPnP error 713\)$'
ok lacks 'read 1 of 2 entries'
ok rrd fritzfw portmaps U
reset_over

# --- incomplete HomePlug enumerations leave the old list aging -------------
cp "${STATE}/fritz.box.homeplug" "${TMP}/homeplug.before"
over x_homeplug__GetNumberOfDeviceEntries.xml 's|>2<|>3<|'
NOW=$((N0 + 300)) run --set FRITZBOX_MODULES=plc
ok cmp -s "${STATE}/fritz.box.homeplug" "${TMP}/homeplug.before"
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

# --- a shorter WAN uptime is a reconnect; the connection state as 1/0 ----------
reset_over
printf '%s 3102 69660 4\n' "$((N0 - 300))" >"${STATE}/fritz.box.dsl"
over wanpppconn1__GetStatusInfo.xml 's|<NewUptime>69660<|<NewUptime>120<|'
run --set 'FRITZBOX_MODULES=dsl wan'
ok has '^Note: the connection was re-established since the last poll$'
ok rrd fritzdsl reconnect 5 DERIVE
ok rrd fritzdsl uptime 120
ok state_has dsl '^1792275201 3102 120 5$'
# The state of fritzbox.sh 1.0.5 and older has no count yet.
printf '%s 3102 69660\n' "$((N0 - 300))" >"${STATE}/fritz.box.dsl"
run --set 'FRITZBOX_MODULES=dsl wan'
ok rrd fritzdsl reconnect 1 DERIVE
over wanpppconn1__GetStatusInfo.xml 's|>Connected<|>Disconnected<|; s|<NewUptime>69660<|<NewUptime>0<|'
run --set 'FRITZBOX_MODULES=dsl wan'
ok rrd fritzwan link_up 1
ok rrd fritzwan connected 0
ok has '^&yellow WAN connection status: Disconnected$'
ok has '^    connection       Disconnected \(PPP\)$'
# fritzdsl and fritzwan share one answer per service and poll.
ok test "$(grep -c '^wanpppconn1 GetStatusInfo$' "${FB_LOG}/actions")" -eq 1
ok test "$(grep -c '^wanipconnection1 GetStatusInfo$' "${FB_LOG}/actions")" -eq 1
# Without a WAN connection service both stay unknown.
run --set 'FRITZBOX_MODULES=dsl wan' --set FRITZBOX_DSL_WAN_SERVICE=off
ok rrd fritzwan connected U
ok rrd fritzdsl reconnect U DERIVE
ok lacks '^    connection '
reset_over

# --- graph coverage -------------------------------------------------------------------
# Every RRD a full poll writes is drawn by exactly one graph, every graph
# draws at least one, and GRAPHS_<column> lists exactly the graphs of that
# column. FNPATTERNs here are plain ERE.
reset_over
run --set FRITZBOX_LAN_NEW_MAC=0
SRVDIR=${REPO}/extensions/fritzbox/server
cat "${SRVDIR}"/graphs.d/*.cfg | awk '/^\[/ { name = substr($0, 2, length($0) - 2) }
     /^[[:space:]]*FNPATTERN / { sub(/^[[:space:]]*FNPATTERN /, ""); print name "|" $0 }' >"${TMP}/patterns"
sed -n 's/^\[\(fritz[a-z]*,.*\.rrd\)\]$/\1/p' "${FB_MESSAGES}" | sort -u >"${TMP}/rrds"
ok test -s "${TMP}/patterns"
ok test "$(wc -l <"${TMP}/rrds")" -ge 40
: >"${TMP}/covered"
while IFS='|' read -r gname gpat; do
    if grep -E "^${gpat}\$" "${TMP}/rrds" >>"${TMP}/covered"; then :
    else printf 'FAIL: fritzbox graph %s matches none of the emitted RRDs\n' "${gname}"; FAIL=1; fi
done <"${TMP}/patterns"
ok test -z "$(sort "${TMP}/covered" | uniq -d)"
ok test -z "$(sort -u "${TMP}/covered" | grep -Fxv -f - "${TMP}/rrds")"
for c in ${COLUMNS}; do
    sed -n "s/^GRAPHS_${c}=\"\(.*\)\"\$/\1/p" "${SRVDIR}"/xymonserver.d/*.cfg | tr ',' '\n' | sort >"${TMP}/listed"
    awk -F'|' -v c="${c}" '{ split($2, p, ","); if (p[1] == c) print $1 }' "${TMP}/patterns" | sort -u >"${TMP}/defined"
    ok cmp -s "${TMP}/listed" "${TMP}/defined"
    # Without a GRAPHS entry named like the column (the TEST2RRD name)
    # the status page draws no graph at all (lib/htmllog.c); the trends
    # page draws the graph of that name.
    ok grep -Eq "^GRAPHS\+=.*,${c}(::[0-9]+)?[,\"]" "${SRVDIR}"/xymonserver.d/*.cfg
    ok grep -q "^${c}|" "${TMP}/patterns"
    ok grep -q "^TEST2RRD+=.*[,\"]${c}[,\"]" "${SRVDIR}"/xymonserver.d/*.cfg
done


# A single failed exposure-settings request is an incomplete poll, not a
# settings change. Keep the previous baseline and send an explicit unknown.
reset_over
FRITZBOX_MODULES=fw
export FRITZBOX_MODULES
run
cp "${STATE}/fritz.box.fw" "${TMP}/fw.before" || exit 1
cp "${FB_DATA}/fault502.xml" "${OVER}/x_remote__GetInfo.xml" || exit 1
run
ok status fritzfw yellow '1 port mapping\(s\), exposure settings incomplete'
ok has '^&yellow X_AVM-DE_RemoteAccess:1 GetInfo failed'
# The port mapping list itself was read completely.
ok rrd fritzfw portmaps 1
ok cmp -s "${TMP}/fw.before" "${STATE}/fritz.box.fw"
reset_over
unset FRITZBOX_MODULES

if [ "${FAIL}" -eq 0 ]; then echo "fritzbox: all tests passed"; fi
exit "${FAIL}"
