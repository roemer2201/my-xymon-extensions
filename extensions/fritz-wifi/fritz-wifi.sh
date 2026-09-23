#!/bin/sh
# fritz-wifi.sh - server-side Xymon collector for the Wi-Fi metadata of
# AVM FRITZ! devices (reference: FRITZ!Powerline 1260E), read over TR-064.
#
# Every hosts.cfg host tagged "fritzwifi" gets a status in the existing
# "wifi" column, laid out like the OpenWrt wifi extension, and the same
# RRD files (wifi,<name>.rrd, DS "lambda"), so the wifi graphs work
# unchanged. The RRD values go out as native "data HOST.trends" messages,
# which - unlike NCV - keep an explicit U: a failed poll or a refused
# login becomes a graph gap, never a zero. Metrics TR-064 does not
# provide (busy, noise, airtime, retries, throughput) are not created.
#
# Version: 1.0.0  (2026-09-23)
#
# Program flow:
# 1. Resolve settings (defaults < config < environment < CLI), validate
#    them, optionally prompt for the password (--ask-password).
# 2. Take the lock, build the host list (hosts.cfg tag or --host) and
#    check the password file (owner and permissions).
# 3. Per host, one after another: read /tr64desc.xml, then for every
#    enabled WLANConfiguration instance GetInfo, GetTotalAssociations and
#    GetGenericAssociatedDeviceInfo per associated client.
# 4. Build color, status text and RRD values; after a failure the names
#    of the last clean run get U.
# 5. Deliver status and trends (or print them with --dry-run) and
#    remember the RRD names of a clean run.
#
# Usage: fritz-wifi.sh --config FILE [--host NAME] [--dry-run] [--help]
set -u
CONFIG_NAME=fritz-wifi.cfg
SCRIPT_VERSION=1.0.0

usage() {
    cat <<'EOF'
Usage: fritz-wifi.sh [--config FILE] [--host NAME]... [--user NAME]
                     [--ask-password] [--set KEY=VALUE]...
                     [--silent | --verbose] [--debug] [--dry-run]
                     [--help] [--version]

Polls AVM FRITZ! devices over TR-064 and reports their Wi-Fi metadata
into the Xymon "wifi" column (and its RRD files) of each device's host.

  --config FILE     FRITZ_WIFI_CONFIG; default XYMONHOME/etc/
                    my-xymon-extensions-server/fritz-wifi.cfg
  --host NAME       FRITZ_WIFI_HOSTS (space-separated list); poll only
                    these hosts instead of every host tagged
                    FRITZ_WIFI_TAG. Repeatable.
  --user NAME       FRITZ_WIFI_USER; TR-064 user name. Overrides the
                    user column of the password file (default: xymon).
  --ask-password    Prompt for the password on the terminal (no echo).
                    Wins over FRITZPASSWORT and the password file and
                    applies to every polled host; combine with --host.
  -s, --silent      FRITZ_WIFI_SILENT=1; errors only
  -v, --verbose     FRITZ_WIFI_VERBOSE=1; diagnostic messages
  --debug           FRITZ_WIFI_DEBUG=1; raw TR-064 responses on stderr
                    (session IDs masked, credentials never printed)
  --dry-run         FRITZ_WIFI_DRY_RUN=1; print the status and trends
                    messages on stdout, send nothing, keep the state
  --set KEY=VALUE   Any of these environment/config settings:
    FRITZ_WIFI_ENABLED (1), FRITZ_WIFI_TAG (fritzwifi)
    FRITZ_WIFI_PASSFILE (XYMONHOME/etc/my-xymon-extensions-server/
      fritz.passwd)
    FRITZ_WIFI_PORT (49000), FRITZ_WIFI_CONNECT_TIMEOUT (5 seconds),
    FRITZ_WIFI_MAX_TIME (10 seconds per request)
    FRITZ_WIFI_LIFETIME (15 minutes), FRITZ_WIFI_COLUMN (wifi)
    FRITZ_WIFI_STATE_DIR (XYMONVAR/fritz-wifi)
    FRITZ_WIFI_HOSTSCFG (HOSTSCFG), FRITZ_WIFI_XYMONCFG
      (XYMONHOME/bin/xymoncfg), FRITZ_WIFI_CURL (curl)
    FRITZ_WIFI_SILENT, FRITZ_WIFI_VERBOSE, FRITZ_WIFI_DEBUG,
    FRITZ_WIFI_DRY_RUN (0)
  -h, --help        Show this help without touching devices or state.
  --version         Print the version.

Environment only:
  FRITZPASSWORT     Password for every polled host. Wins over the
                    password file, loses against --ask-password. It is
                    removed from the environment before curl runs.
With --ask-password or FRITZPASSWORT the password file is not read; the
user is then FRITZ_WIFI_USER or "xymon".

Precedence: CLI > exported environment > config file > defaults.
Silent and verbose are mutually exclusive; on the command line either
switch overrides the other one's setting. Automated runs log via syslog
(tag fritz-wifi); errors also go to stderr (the task's log file).

Password file: one "host_or_ip user password" line per device; the
password is the rest of the line (spaces allowed, leading/trailing blanks
removed), "-" as user means "xymon". Blank lines and "#" lines are
ignored. It must be owned by the running user and have no group/other
permissions (chmod 600), or it is rejected. Passwords reach curl only on
stdin, never on its command line.

Example: fritz-wifi.sh --host powerline3.lan --ask-password --dry-run
EOF
}

# Restrict configurable names; export a validated NAME=VALUE, never eval.
setting() {
    # shellcheck disable=SC2163 # Export a validated NAME=VALUE, not positional $1.
    case "${1%%=*}" in
        FRITZ_WIFI_ENABLED|FRITZ_WIFI_TAG|FRITZ_WIFI_HOSTS|FRITZ_WIFI_USER|FRITZ_WIFI_PASSFILE|FRITZ_WIFI_PORT|FRITZ_WIFI_CONNECT_TIMEOUT|FRITZ_WIFI_MAX_TIME|FRITZ_WIFI_LIFETIME|FRITZ_WIFI_COLUMN|FRITZ_WIFI_STATE_DIR|FRITZ_WIFI_HOSTSCFG|FRITZ_WIFI_XYMONCFG|FRITZ_WIFI_CURL|FRITZ_WIFI_SILENT|FRITZ_WIFI_VERBOSE|FRITZ_WIFI_DEBUG|FRITZ_WIFI_DRY_RUN) export "${1}" ;;
        *) printf 'Unknown setting: %s\n' "${1%%=*}" >&2; exit 2 ;;
    esac
}

# The password is taken over first and dropped from the environment, so
# neither the config file nor any child process (curl) ever sees it.
env_password=${FRITZPASSWORT:-}
unset FRITZPASSWORT

# Parse the command line without touching the filesystem, so --help is
# always usable. Settings are collected and applied after the config.
cli=''
cli_hosts=''
cli_silent=0
cli_verbose=0
ask_password=0
config=${FRITZ_WIFI_CONFIG:-${XYMONHOME:-}/etc/my-xymon-extensions-server/${CONFIG_NAME}}
explicit_config=0
[ -z "${FRITZ_WIFI_CONFIG:-}" ] || explicit_config=1
while [ "${#}" -gt 0 ]; do
    case "${1}" in
        -h|--help) usage; exit 0 ;;
        --version) printf 'fritz-wifi.sh %s\n' "${SCRIPT_VERSION}"; exit 0 ;;
        --config|--host|--user|--set)
            [ "${#}" -ge 2 ] || { printf '%s requires a value\n' "${1}" >&2; exit 2; }
            case "${1}" in
                --config) config=${2}; explicit_config=1 ;;
                --host) cli_hosts="${cli_hosts} ${2}" ;;
                --user) cli="${cli}
FRITZ_WIFI_USER=${2}" ;;
                --set) case "${2}" in FRITZ_WIFI_*=*) cli="${cli}
${2}" ;; *) printf '%s\n' 'Expected FRITZ_WIFI_KEY=VALUE' >&2; exit 2 ;; esac ;;
            esac
            shift 2 ;;
        --ask-password) ask_password=1; shift ;;
        # A CLI switch also clears its counterpart, so --verbose works
        # against FRITZ_WIFI_SILENT=1 from the config or environment.
        -s|--silent) cli_silent=1; cli="${cli}
FRITZ_WIFI_SILENT=1
FRITZ_WIFI_VERBOSE=0"; shift ;;
        -v|--verbose) cli_verbose=1; cli="${cli}
FRITZ_WIFI_VERBOSE=1
FRITZ_WIFI_SILENT=0"; shift ;;
        --debug) cli="${cli}
FRITZ_WIFI_DEBUG=1"; shift ;;
        --dry-run) cli="${cli}
FRITZ_WIFI_DRY_RUN=1"; shift ;;
        *) printf 'Unknown option: %s (see --help)\n' "${1}" >&2; exit 2 ;;
    esac
done
if [ "${cli_silent}${cli_verbose}" = 11 ]; then
    printf '%s\n' 'Silent and verbose are mutually exclusive (see --help)' >&2; exit 2
fi
[ -z "${cli_hosts}" ] || cli="${cli}
FRITZ_WIFI_HOSTS=${cli_hosts# }"

# Defaults, then the trusted admin-owned config, then the saved
# environment and the command line on top (CLI > env > config > default).
saved_env=$(env | LC_ALL=C sort | awk '/^FRITZ_WIFI_/ && !/^FRITZ_WIFI_CONFIG=/')
FRITZ_WIFI_ENABLED=1 FRITZ_WIFI_TAG=fritzwifi FRITZ_WIFI_HOSTS='' FRITZ_WIFI_USER=''
FRITZ_WIFI_PASSFILE=${XYMONHOME:-}/etc/my-xymon-extensions-server/fritz.passwd
FRITZ_WIFI_PORT=49000 FRITZ_WIFI_CONNECT_TIMEOUT=5 FRITZ_WIFI_MAX_TIME=10
FRITZ_WIFI_LIFETIME=15 FRITZ_WIFI_COLUMN=wifi
FRITZ_WIFI_STATE_DIR=${XYMONVAR:-}/fritz-wifi
FRITZ_WIFI_HOSTSCFG=${HOSTSCFG:-${XYMONHOME:-}/etc/hosts.cfg}
FRITZ_WIFI_XYMONCFG=${XYMONHOME:-}/bin/xymoncfg FRITZ_WIFI_CURL=curl
FRITZ_WIFI_SILENT=0 FRITZ_WIFI_VERBOSE=0 FRITZ_WIFI_DEBUG=0 FRITZ_WIFI_DRY_RUN=0
if [ -r "${config}" ]; then
    # shellcheck source=/dev/null
    . "${config}"
elif [ "${explicit_config}" -eq 1 ]; then
    printf 'Cannot read config: %s\n' "${config}" >&2; exit 1
fi
unset FRITZPASSWORT
while IFS= read -r assignment; do
    [ -z "${assignment}" ] || setting "${assignment}"
done <<EOF
${saved_env}
${cli}
EOF
LC_ALL=C
export LC_ALL
umask 077
work=''
tty_saved=''
NL='
'

# Explicit logging was requested for this server task: syslog always,
# the console only when interactive or verbose; errors always on stderr
# (the task's LOGFILE). Never pass credentials to this function.
log() {
    level=${1}; shift
    [ "${level}" != debug ] || [ "${FRITZ_WIFI_VERBOSE}" = 1 ] || return 0
    if command -v logger >/dev/null 2>&1; then logger -t fritz-wifi -- "${level}: ${*}" || :; fi
    if [ "${level}" = error ]; then printf 'fritz-wifi: %s\n' "${*}" >&2
    elif [ "${FRITZ_WIFI_SILENT}" = 0 ] && { [ -t 2 ] || [ "${FRITZ_WIFI_VERBOSE}" = 1 ]; }; then
        printf 'fritz-wifi: %s: %s\n' "${level}" "${*}" >&2
    fi
}

# A collector-level failure: nothing was polled, no status is invented.
fail() {
    log error "${*}"
    exit 1
}

# Restore the terminal (--ask-password) and remove the work directory on
# every exit path, including signals.
# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap.
cleanup() {
    [ -z "${tty_saved}" ] || stty "${tty_saved}" 2>/dev/null || :
    [ -z "${work}" ] || rm -rf "${work}"
}
trap cleanup 0
trap 'exit 1' 1 2 15

# Validate every setting before it is used in arithmetic, paths or URLs.
for n in "${FRITZ_WIFI_ENABLED}" "${FRITZ_WIFI_SILENT}" "${FRITZ_WIFI_VERBOSE}" "${FRITZ_WIFI_DEBUG}" "${FRITZ_WIFI_DRY_RUN}"; do
    case "${n}" in 0|1) ;; *) printf '%s\n' 'Boolean settings must be 0 or 1' >&2; exit 2 ;; esac
done
if [ "${FRITZ_WIFI_SILENT}${FRITZ_WIFI_VERBOSE}" = 11 ]; then
    printf '%s\n' 'Silent and verbose are mutually exclusive (see --help)' >&2; exit 2
fi
# Disabled: quiet for the task, a hint for a manual run on a terminal.
if [ "${FRITZ_WIFI_ENABLED}" != 1 ]; then
    [ ! -t 2 ] || printf '%s\n' 'fritz-wifi: disabled (FRITZ_WIFI_ENABLED=0) - nothing to do; see --help' >&2
    exit 0
fi
for n in "${FRITZ_WIFI_PORT}" "${FRITZ_WIFI_CONNECT_TIMEOUT}" "${FRITZ_WIFI_MAX_TIME}" "${FRITZ_WIFI_LIFETIME}"; do
    case "${n}" in ''|*[!0-9]*) fail "Expected a positive integer, got '${n}'" ;; esac
    [ "${n}" -gt 0 ] || fail 'Port, timeouts and lifetime must be positive'
done
[ "${FRITZ_WIFI_PORT}" -le 65535 ] || fail "Invalid TR-064 port ${FRITZ_WIFI_PORT}"
case "${FRITZ_WIFI_COLUMN}" in ''|*[!a-z0-9_-]*) fail 'The column name must be lowercase letters, digits, _ or -' ;; esac
case "${FRITZ_WIFI_TAG}" in ''|*[!A-Za-z0-9_-]*) fail 'Invalid hosts.cfg tag' ;; esac
case "${FRITZ_WIFI_USER}" in *:*) fail 'The TR-064 user name must not contain a colon' ;; esac
case "${FRITZ_WIFI_STATE_DIR}" in /*) ;; *) fail 'The state directory must be absolute' ;; esac
[ "${FRITZ_WIFI_STATE_DIR}" != /fritz-wifi ] || fail 'Set XYMONVAR or FRITZ_WIFI_STATE_DIR to a persistent writable directory'
if [ "${FRITZ_WIFI_DRY_RUN}" = 0 ] && { [ -z "${XYMON:-}" ] || [ -z "${XYMSRV:-}" ]; }; then
    fail 'Use the Xymon server environment (XYMON/XYMSRV), or --dry-run'
fi
if [ "${FRITZ_WIFI_DRY_RUN}" = 0 ]; then
    command -v "${XYMON}" >/dev/null 2>&1 || fail 'Xymon sender is not executable'
fi
command -v flock >/dev/null 2>&1 || fail 'flock is required'

# Interactive password: POSIX has no "read -s" (dash only knows -r/-p),
# so echo is switched off with stty and restored by cleanup() at exit.
asked_password=''
if [ "${ask_password}" = 1 ]; then
    [ -t 0 ] || { printf '%s\n' '--ask-password needs a terminal on stdin' >&2; exit 2; }
    tty_saved=$(stty -g) || fail 'Cannot read the terminal settings'
    printf 'TR-064 password: ' >&2
    stty -echo || fail 'Cannot switch off the terminal echo'
    IFS= read -r asked_password || asked_password=''
    stty "${tty_saved}" || :
    tty_saved=''
    printf '\n' >&2
fi

mkdir -p "${FRITZ_WIFI_STATE_DIR}" || fail "Cannot create state directory ${FRITZ_WIFI_STATE_DIR}"
exec 9>"${FRITZ_WIFI_STATE_DIR}/lock" || fail "Cannot open ${FRITZ_WIFI_STATE_DIR}/lock"
flock -n 9 || { log debug 'Another fritz-wifi run holds the lock'; exit 0; }
work=$(mktemp -d "${FRITZ_WIFI_STATE_DIR}/run.XXXXXX") || fail 'Cannot create temporary directory'

# ----------------------------------------------------------------------
# Host list: hosts.cfg flattened by Xymon's own parser (includes!), like
# powerline; a plain file only when it has no include statements.
# ----------------------------------------------------------------------
load_hosts() {
    if [ -x "${FRITZ_WIFI_XYMONCFG}" ]; then
        "${FRITZ_WIFI_XYMONCFG}" "${FRITZ_WIFI_HOSTSCFG}" >"${work}/hosts.cfg" || return 1
    else
        [ -r "${FRITZ_WIFI_HOSTSCFG}" ] || return 1
        if grep -E '^[[:space:]]*(optional[[:space:]]+)?(include|directory|netinclude|dispinclude)[[:space:]]' "${FRITZ_WIFI_HOSTSCFG}" >/dev/null; then
            log error 'hosts.cfg contains includes; configure FRITZ_WIFI_XYMONCFG'
            return 1
        fi
        cp "${FRITZ_WIFI_HOSTSCFG}" "${work}/hosts.cfg" || return 1
    fi
}

# Output lines "hostname ip"; ip is "" when unknown (connect by name).
if [ -n "${FRITZ_WIFI_HOSTS}" ]; then
    # Manual selection: hosts.cfg only supplies the IP, if readable.
    load_hosts 2>/dev/null || : >"${work}/hosts.cfg"
    for h in ${FRITZ_WIFI_HOSTS}; do
        case "${h}" in *[!A-Za-z0-9_.-]*|-*) fail "Invalid host name: ${h}" ;; esac
        awk -v h="${h}" '$2 == h && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { ip = $1; exit }
            END { print h, ip }' "${work}/hosts.cfg"
    done >"${work}/targets" || fail 'Cannot build the host list'
else
    load_hosts || fail "Cannot load hosts.cfg (${FRITZ_WIFI_HOSTSCFG})"
    awk -v tag="${FRITZ_WIFI_TAG}" '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
        for (i = 3; i <= NF; i++) if ($i == tag) { print $2, $1; break }
    }' "${work}/hosts.cfg" | awk '$1 ~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/ && !seen[$1]++' \
        >"${work}/targets" || fail 'Cannot parse hosts.cfg'
fi
if [ ! -s "${work}/targets" ]; then
    log info "No host tagged ${FRITZ_WIFI_TAG} in hosts.cfg - nothing to poll"
    exit 0
fi

# ----------------------------------------------------------------------
# Password file: read as data, never sourced. Only a regular file owned
# by the running user without any group/other permission is used - the
# same rule ssh applies to private keys.
# ----------------------------------------------------------------------
passfile_ok=0
passfile_problem=''
check_passfile() {
    pf=${FRITZ_WIFI_PASSFILE}
    if [ -z "${pf}" ] || { [ ! -e "${pf}" ] && [ ! -L "${pf}" ]; }; then
        passfile_problem="no password file at ${pf:-(unset)}"
        return
    fi
    uid=$(id -u) || { passfile_problem='cannot determine the own user id'; return; }
    # find -prune tests the path itself; a symlink fails -type f.
    if [ -z "$(find "${pf}" -prune -type f -user "${uid}" ! -perm -040 ! -perm -020 ! -perm -010 ! -perm -004 ! -perm -002 ! -perm -001 -print)" ]; then
        passfile_problem="password file ${pf} rejected: it must be a regular file owned by uid ${uid} without any group/other permission (chmod 600)"
        log error "${passfile_problem}"
        return
    fi
    if [ ! -r "${pf}" ]; then
        passfile_problem="password file ${pf} is not readable"
        log error "${passfile_problem}"
        return
    fi
    passfile_ok=1
    # Report malformed and duplicate lines by number, never by content.
    awk '
        { sub(/\r$/, "") }
        /^[ \t]*$/ || /^[ \t]*#/ { next }
        {
            line = $0; sub(/^[ \t]+/, "", line)
            n = split(line, f, /[ \t]+/)
            if (n < 3) { print "line " NR ": expected host, user and password"; next }
            if (index(f[2], ":")) { print "line " NR ": the user must not contain a colon"; next }
            k = tolower(f[1])
            if (k in seen) print "line " NR ": duplicate entry for " f[1] ", line " seen[k] " wins"
            else seen[k] = NR
        }' "${pf}" | while IFS= read -r msg; do
        log warning "${pf} ${msg}"
    done
}

# lookup_password NAME IP - prints "user", a newline and the password of
# the first entry for NAME, else for IP; fails when there is none. The
# password only travels through pipes and variables, never through argv.
lookup_password() {
    awk -v name="${1}" -v ip="${2}" '
        { sub(/\r$/, "") }
        /^[ \t]*$/ || /^[ \t]*#/ { next }
        {
            line = $0; sub(/^[ \t]+/, "", line)
            key = line; sub(/[ \t].*$/, "", key)
            rest = substr(line, length(key) + 1); sub(/^[ \t]+/, "", rest)
            user = rest; sub(/[ \t].*$/, "", user)
            pw = substr(rest, length(user) + 1)
            sub(/^[ \t]+/, "", pw); sub(/[ \t]+$/, "", pw)
            if (key == "" || user == "" || pw == "" || index(user, ":")) next
            k = tolower(key)
            if (k == tolower(name)) { if (!("n" in hit)) hit["n"] = user "\n" pw }
            else if (ip != "" && k == ip) { if (!("i" in hit)) hit["i"] = user "\n" pw }
        }
        END {
            if ("n" in hit) print hit["n"]
            else if ("i" in hit) print hit["i"]
            else exit 1
        }' "${FRITZ_WIFI_PASSFILE}"
}

# curl_quote TEXT - escape for a double-quoted curl config value: curl
# knows \\ \" \t \n \r \v there (docs/cmdline-opts/config.md), so " and \
# must be escaped. printf is a shell builtin: TEXT never reaches an argv.
curl_quote() {
    printf '%s' "${1}" | sed 's/[\\"]/\\&/g'
}

if [ "${ask_password}" = 0 ] && [ -z "${env_password}" ]; then
    check_passfile
fi

curl_ok=1
command -v "${FRITZ_WIFI_CURL}" >/dev/null 2>&1 || curl_ok=0
# Per-client queries per network and run (see collect_host).
max_client_details=32

# ----------------------------------------------------------------------
# TR-064 plumbing
# ----------------------------------------------------------------------

# debug_dump LABEL - raw response of the last request on stderr, with
# session IDs masked (--debug). Credentials are never part of it.
debug_dump() {
    [ "${FRITZ_WIFI_DEBUG}" = 1 ] || return 0
    {
        printf 'fritz-wifi: debug: %s %s\n' "${host}" "${1}"
        sed 's/sid=[^&"<[:space:]]*/sid=XXXX/g' "${hw}/resp"
        printf '\n'
    } >&2
}

# field NAME - text of the first element NAME in the last response. The
# response was split at every "<", so an element is a line "NAME>text".
field() {
    awk -v n="${1}" 'index($0, n ">") == 1 { print substr($0, length(n) + 2); exit }' "${hw}/resp.lines"
}

# soap PATH INSTANCE ACTION [INDEX] - one TR-064 call on
# WLANConfiguration:INSTANCE. Only read-only actions are allowed; above
# all GetSecurityKeys (it returns the Wi-Fi passphrase) is never sent.
# Sets HTTPCODE, ERRCODE and CURLERR. Returns 0 = HTTP 200, 1 = transport
# error or timeout, 2 = authentication refused (401, UPnP 606),
# 3 = array index invalid (UPnP 713), 4 = any other error.
soap() {
    s_path=${1} s_inst=${2} s_act=${3} s_args=''
    HTTPCODE='' ERRCODE='' CURLERR=''
    case "${s_act}" in
        GetInfo|GetTotalAssociations) ;;
        GetGenericAssociatedDeviceInfo) s_args="<NewAssociatedDeviceIndex>${4}</NewAssociatedDeviceIndex>" ;;
        *) log error "Refusing TR-064 action ${s_act}: not on the read-only list"; return 4 ;;
    esac
    s_urn="urn:dslforum-org:service:WLANConfiguration:${s_inst}"
    : >"${hw}/resp"
    # The action element needs its own closing tag: the reference device
    # answers a self-closing one with "502 XML error".
    HTTPCODE=$(printf '%s\n' "${cred_config}" | "${FRITZ_WIFI_CURL}" --silent --show-error \
        --digest --config - \
        --connect-timeout "${FRITZ_WIFI_CONNECT_TIMEOUT}" --max-time "${FRITZ_WIFI_MAX_TIME}" \
        --output "${hw}/resp" --write-out '%{http_code}' \
        --header 'Content-Type: text/xml; charset="utf-8"' \
        --header "SoapAction: \"${s_urn}#${s_act}\"" \
        --data "<?xml version='1.0' encoding='utf-8'?><s:Envelope s:encodingStyle='http://schemas.xmlsoap.org/soap/encoding/' xmlns:s='http://schemas.xmlsoap.org/soap/envelope/'><s:Body><u:${s_act} xmlns:u='${s_urn}'>${s_args}</u:${s_act}></s:Body></s:Envelope>" \
        "${base_url}${s_path}" 2>"${hw}/curlerr")
    s_rc=${?}
    CURLERR=$(head -n 1 "${hw}/curlerr")
    tr '<' '\n' <"${hw}/resp" >"${hw}/resp.lines"
    debug_dump "WLANConfiguration:${s_inst} ${s_act}${4:+ index ${4}} -> curl ${s_rc}, HTTP ${HTTPCODE:-none}"
    [ "${s_rc}" -eq 0 ] || return 1
    case "${HTTPCODE}" in
        200) return 0 ;;
        401) return 2 ;;  # HTML body, not a SOAP fault - never parsed
    esac
    ERRCODE=$(field errorCode)
    case "${ERRCODE}" in
        713) return 3 ;;
        606) return 2 ;;  # UPnP "Action not authorized"
    esac
    return 4
}

# soap_problem RC ACTION INSTANCE - human-readable reason for RC.
soap_problem() {
    case "${1}" in
        1) printf 'cannot reach TR-064 at %s - %s' "${base_url}" "${CURLERR:-connection failed}" ;;
        2) printf 'TR-064 authentication failed (HTTP %s%s) - check user and password for %s' \
               "${HTTPCODE}" "${ERRCODE:+, UPnP error ${ERRCODE}}" "${host}" ;;
        *) printf 'TR-064 %s on WLANConfiguration:%s failed (HTTP %s%s)' "${2}" "${3}" \
               "${HTTPCODE:-none}" "${ERRCODE:+, UPnP error ${ERRCODE}}" ;;
    esac
}

# worst COLOR COLOR - the more severe of red, yellow and green. "clear"
# (nothing to monitor) is set directly where it applies.
worst() {
    for w_c in red yellow green clear; do
        if [ "${1}" = "${w_c}" ] || [ "${2}" = "${w_c}" ]; then printf '%s' "${w_c}"; return; fi
    done
    printf '%s' green
}

# note COLOR TEXT - a colored line above the details; raises the color.
note() {
    color=$(worst "${color}" "${1}")
    printf '&%s %s\n' "${1}" "${2}" >>"${hw}/notes"
}

# metric NAME VALUE - one RRD value (U = unknown) for the trends message.
metric() {
    printf '%s %s\n' "${1}" "${2}" >>"${hw}/metrics"
}

# is_uint VALUE - true for a non-empty decimal integer.
is_uint() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}

# traffic_kbps SUFFIX - throughput hook for the wifikbps graph. The
# reference device returns 0 from GetStatistics/GetPacketStatistics even
# under load, so there is no usable source yet and the rxkbps_/txkbps_
# RRDs are not created. A future source prints "RXKBPS TXKBPS" here and
# returns 0; the caller then writes both metrics and shows the values.
traffic_kbps() {
    return 1
}

# ----------------------------------------------------------------------
# collect_host - poll one device. Fills ${hw}/radios, ifs, clients,
# metrics and notes. Returns 1 on a failure that ends the poll of this
# host (unreachable, login refused, no TR-064); color/summary are set.
# ----------------------------------------------------------------------
collect_host() {
    # Credentials: prompt > FRITZPASSWORT > password file; user:
    # FRITZ_WIFI_USER > password file column > "xymon".
    c_user='' c_pass=''
    if [ "${ask_password}" = 1 ]; then
        c_pass=${asked_password}
    elif [ -n "${env_password}" ]; then
        c_pass=${env_password}
    elif [ "${passfile_ok}" = 1 ] && c_entry=$(lookup_password "${host}" "${ip}"); then
        c_user=${c_entry%%"${NL}"*}
        c_pass=${c_entry#*"${NL}"}
    else
        if [ "${passfile_ok}" = 1 ]; then
            note yellow "no password for ${host}${ip:+ or ${ip}} in ${FRITZ_WIFI_PASSFILE}"
        else
            note yellow "no password for ${host}: ${passfile_problem}"
        fi
        summary='no password'
        return 1
    fi
    [ "${c_user}" != - ] || c_user=''
    [ -z "${FRITZ_WIFI_USER}" ] || c_user=${FRITZ_WIFI_USER}
    [ -n "${c_user}" ] || c_user=xymon
    cred_config="user = \"$(curl_quote "${c_user}"):$(curl_quote "${c_pass}")\""
    c_pass='' c_entry=''

    # The device description lists the WLANConfiguration instances and
    # their control URLs; it needs no login.
    : >"${hw}/resp"
    HTTPCODE=$("${FRITZ_WIFI_CURL}" --silent --show-error \
        --connect-timeout "${FRITZ_WIFI_CONNECT_TIMEOUT}" --max-time "${FRITZ_WIFI_MAX_TIME}" \
        --output "${hw}/resp" --write-out '%{http_code}' \
        "${base_url}/tr64desc.xml" </dev/null 2>"${hw}/curlerr")
    c_rc=${?}
    CURLERR=$(head -n 1 "${hw}/curlerr")
    debug_dump "tr64desc.xml -> curl ${c_rc}, HTTP ${HTTPCODE:-none}"
    if [ "${c_rc}" -ne 0 ]; then
        note red "$(soap_problem 1)"
        summary='unreachable'
        return 1
    fi
    if [ "${HTTPCODE}" != 200 ]; then
        note yellow "TR-064 device description not available at ${base_url}/tr64desc.xml (HTTP ${HTTPCODE}) - is TR-064 enabled?"
        summary='TR-064 error'
        return 1
    fi
    tr '<' '\n' <"${hw}/resp" | awk '
        index($0, "serviceType>") == 1 { t = substr($0, 13) }
        index($0, "controlURL>") == 1 { u = substr($0, 12) }
        index($0, "/service>") == 1 {
            if (t ~ /^urn:dslforum-org:service:WLANConfiguration:[0-9]+$/ && u ~ /^\/[A-Za-z0-9_\/.-]+$/) {
                n = t; sub(/.*:/, "", n)
                if (!seen[n]++) print n, u
            }
            t = ""; u = ""
        }' | sort -n >"${hw}/instances"
    if [ ! -s "${hw}/instances" ]; then
        [ "${color}" != green ] || color=clear
        printf '%s\n' "no WLANConfiguration service in the TR-064 description - no Wi-Fi to monitor" >>"${hw}/notes"
        summary='not applicable'
        return 1
    fi

    # One instance after another; the loop reads its list from fd 4 so
    # nothing inside can consume it.
    while read -r inst path <&4; do
        soap "${path}" "${inst}" GetInfo
        c_rc=${?}
        case "${c_rc}" in
            0) ;;
            1) note red "$(soap_problem 1)"; summary='unreachable'; return 1 ;;
            2) note yellow "$(soap_problem 2)"; summary='authentication failed'; return 1 ;;
            *) note yellow "$(soap_problem "${c_rc}" GetInfo "${inst}")"; partial=1; continue ;;
        esac
        i_enable=$(field NewEnable)
        i_status=$(field NewStatus | tr -cd 'A-Za-z0-9_.,+/-')
        i_channel=$(field NewChannel)
        i_ssid=$(field NewSSID | tr -d '\001-\037\177')
        # Device strings end up in "|"-separated records: keep them tame.
        i_standard=$(field NewStandard | tr -cd 'A-Za-z0-9_.,+/-')
        i_band=$(field NewX_AVM-DE_FrequencyBand)
        is_uint "${i_band}" || i_band=''
        if [ -z "${i_enable}" ] && [ -z "${i_status}" ]; then
            note yellow "TR-064 GetInfo on WLANConfiguration:${inst} returned no NewEnable/NewStatus - unexpected response"
            partial=1
            continue
        fi
        # A disabled network (e.g. the guest access) is ignored completely.
        if [ "${i_enable}" != 1 ] || [ "${i_status}" = Disabled ]; then
            log debug "${host}: WLANConfiguration:${inst} is disabled - ignored"
            continue
        fi
        nif=$((nif + 1))
        # Radio names by band, resolved at runtime; interface names like
        # OpenWrt's phyN-apM (metric suffix wl2g_ap1).
        case "${i_band}" in
            2400) radio=wl2g ;;
            5000) radio=wl5g ;;
            6000) radio=wl6g ;;
            *) radio="wlan${inst}" ;;
        esac
        iface="${radio}-ap${inst}"
        sif=$(printf '%s' "${iface}" | sed 's/-/_/g')
        is_uint "${i_channel}" || i_channel=''
        if ! grep -q "^${radio} " "${hw}/radios"; then
            printf '%s %s %s\n' "${radio}" "${i_band:--}" "${i_channel:--}" >>"${hw}/radios"
            metric "channel_${radio}" "${i_channel:-U}"
        fi

        # Clients: only for a network that is up. A count that cannot be
        # read is unknown (U), never 0.
        i_clients=''
        i_color=green
        if [ "${i_status}" != Up ]; then
            note yellow "${iface} (WLANConfiguration:${inst}) is enabled but its status is ${i_status:-empty}"
            i_color=yellow
        else
            soap "${path}" "${inst}" GetTotalAssociations
            c_rc=${?}
            case "${c_rc}" in
                0)
                    i_clients=$(field NewTotalAssociations)
                    # More than 5 digits is no plausible count (and would
                    # overflow the shell arithmetic below).
                    case "${i_clients}" in ??????*) i_clients=x ;; esac
                    if ! is_uint "${i_clients}"; then
                        i_clients=''
                        note yellow "TR-064 GetTotalAssociations on WLANConfiguration:${inst} returned no client count - unexpected response"
                        i_color=yellow
                    fi ;;
                1) note red "$(soap_problem 1)"; summary='unreachable'; return 1 ;;
                2) note yellow "$(soap_problem 2)"; summary='authentication failed'; return 1 ;;
                *) note yellow "$(soap_problem "${c_rc}" GetTotalAssociations "${inst}")"; i_color=yellow ;;
            esac
        fi
        metric "clients_${sif}" "${i_clients:-U}"
        if [ -n "${i_clients}" ] && [ -n "${total}" ]; then
            total=$((total + i_clients))
        else
            total=''
        fi

        # Per client: PHY speed, signal strength (0-100, not dBm) and the
        # channel width of its link. 713 means the client left between
        # the count and this query - normal, not an error.
        # At most max_client_details queries per network, so a device with
        # very many clients cannot stretch a run beyond MAXTIME; the count
        # itself stays exact.
        idx=0
        while [ -n "${i_clients}" ] && [ "${idx}" -lt "${i_clients}" ] && [ "${idx}" -lt "${max_client_details}" ]; do
            soap "${path}" "${inst}" GetGenericAssociatedDeviceInfo "${idx}"
            c_rc=${?}
            case "${c_rc}" in
                0) ;;
                1) note red "$(soap_problem 1)"; summary='unreachable'; return 1 ;;
                2) note yellow "$(soap_problem 2)"; summary='authentication failed'; return 1 ;;
                3) log debug "${host}: client ${idx} on WLANConfiguration:${inst} left during the poll"; break ;;
                *) log warning "${host}: $(soap_problem "${c_rc}" GetGenericAssociatedDeviceInfo "${inst}")"; break ;;
            esac
            c_speed=$(field NewX_AVM-DE_Speed)
            c_signal=$(field NewX_AVM-DE_SignalStrength)
            c_width=$(field NewX_AVM-DE_ChannelWidth)
            is_uint "${c_speed}" || c_speed=-
            is_uint "${c_signal}" || c_signal=-
            is_uint "${c_width}" || c_width=-
            printf '%s %s %s %s %s\n' "${sif}" "${radio}" "${c_speed}" "${c_signal}" "${c_width}" >>"${hw}/clients"
            idx=$((idx + 1))
        done

        # Throughput hook (see traffic_kbps); nothing is created today.
        if i_kbps=$(traffic_kbps "${sif}"); then
            metric "rxkbps_${sif}" "${i_kbps%% *}"
            metric "txkbps_${sif}" "${i_kbps#* }"
        else
            i_kbps=''
        fi

        # SSID last: it may contain any character, including "|".
        printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "${radio}" "${iface}" "${i_color}" \
            "${i_clients:-n/a}" "${i_standard:-n/a}" "${i_status:-n/a}" "${i_kbps:--}" "${i_ssid}" >>"${hw}/ifs"
    done 4<"${hw}/instances"
    return 0
}

# render_details - the OpenWrt-style details from radios, ifs and clients.
render_details() {
    awk -v radios="${hw}/radios" -v clients="${hw}/clients" '
        # Channel number -> center frequency, as Linux
        # ieee80211_channel_to_freq_khz() computes it (802.11 Annex E).
        function freq(b, c) {
            if (c !~ /^[0-9]+$/ || c == 0) return ""
            if (b == "2400") return c == 14 ? 2484 : (c < 14 ? 2407 + 5 * c : "")
            if (b == "5000") return (c >= 182 && c <= 196) ? 4000 + 5 * c : 5000 + 5 * c
            if (b == "6000") return c == 2 ? 5935 : (c <= 253 ? 5950 + 5 * c : "")
            return ""
        }
        # TR-064 values are XML-escaped. Quotes are decoded; &amp; &lt;
        # &gt; and numeric references stay encoded, because the Xymon
        # status page is HTML (a raw "<" or "&red" would be markup).
        function ssid_text(s) {
            gsub(/&quot;/, "\"", s); gsub(/&apos;/, "\047", s)
            return s
        }
        BEGIN {
            while ((getline line < radios) > 0) {
                split(line, r, " ")
                nr++; rname[nr] = r[1]; rband[r[1]] = r[2]; rchan[r[1]] = r[3]
            }
            while ((getline line < clients) > 0) {
                split(line, c, " ")
                if (c[5] ~ /^[0-9]+$/ && c[5] + 0 > width[c[2]] + 0) width[c[2]] = c[5]
                if (c[4] ~ /^[0-9]+$/) {
                    sn[c[1]]++; ssum[c[1]] += c[4]
                    if (!(c[1] in smin) || c[4] + 0 < smin[c[1]]) smin[c[1]] = c[4] + 0
                }
                if (c[3] ~ /^[0-9]+$/) {
                    pn[c[1]]++; psum[c[1]] += c[3]
                    if (!(c[1] in pmin) || c[3] + 0 < pmin[c[1]]) pmin[c[1]] = c[3] + 0
                }
            }
        }
        {
            rest = $0
            for (i = 1; i <= 7; i++) { f[i] = substr(rest, 1, index(rest, "|") - 1); rest = substr(rest, index(rest, "|") + 1) }
            n++; iradio[n] = f[1]; iname[n] = f[2]; icolor[n] = f[3]; iclients[n] = f[4]
            istd[n] = f[5]; istatus[n] = f[6]; ikbps[n] = f[7]; issid[n] = ssid_text(rest)
        }
        END {
            for (ri = 1; ri <= nr; ri++) {
                rn = rname[ri]; ch = rchan[rn]; fr = freq(rband[rn], ch)
                printf "%s  channel=%s%s  width=%s  busy=n/a rx=n/a tx=n/a  noise=n/a\n", rn,
                    (ch == "-" ? "n/a" : ch), (fr == "" ? "" : " (" fr " MHz)"),
                    ((rn in width) ? width[rn] " MHz (client)" : "n/a")
                for (i = 1; i <= n; i++) {
                    if (iradio[i] != rn) continue
                    s = iname[i]; gsub(/-/, "_", s)
                    printf "  &%s %s  ssid=\"%s\"%s  clients=%s [tr064]  txpower=n/a\n", icolor[i], iname[i],
                        issid[i], (istatus[i] == "Up" ? "" : "  status=" istatus[i]), iclients[i]
                    if (ikbps[i] == "-") kb = "rx=n/a tx=n/a kbit/s"
                    else { split(ikbps[i], k, " "); kb = "rx=" k[1] " tx=" k[2] " kbit/s" }
                    printf "         %s  airtime rx=n/a tx=n/a  retries=n/a failed=n/a\n", kb
                    sig = (s in sn) ? sprintf("signal min/avg=%d/%.0f (0-100)", smin[s], ssum[s] / sn[s]) : "signal=n/a"
                    spd = (s in pn) ? sprintf("speed min/avg=%d/%.0f Mbit/s", pmin[s], psum[s] / pn[s]) : "speed=n/a"
                    printf "         standard=%s  %s  %s\n", istd[i], sig, spd
                }
            }
        }' "${hw}/ifs"
}

# ----------------------------------------------------------------------
# Deliver one message, or print it for --dry-run.
# ----------------------------------------------------------------------
deliver() {
    if [ "${FRITZ_WIFI_DRY_RUN}" = 1 ]; then printf '%s\n\n' "${1}"
    else "${XYMON}" "${XYMSRV}" "${1}"; fi
}

# poll_host NAME IP - poll, render, deliver and remember one device.
sent_all=1
poll_host() {
    host=${1} ip=${2}
    hw="${work}/host"
    rm -rf "${hw}"
    mkdir "${hw}" || fail 'Cannot create the per-host work directory'
    : >"${hw}/notes"; : >"${hw}/metrics"; : >"${hw}/radios"; : >"${hw}/ifs"; : >"${hw}/clients"
    color=green summary='' partial=0 nif=0 total=0
    case "${ip}" in ''|0.0.0.0) target=${host} ;; *) target=${ip} ;; esac
    base_url="http://${target}:${FRITZ_WIFI_PORT}"
    wirehost=$(printf '%s' "${host}" | tr . ,)
    statefile="${FRITZ_WIFI_STATE_DIR}/${host}.names"
    log debug "Polling ${host} at ${base_url}"

    if [ "${curl_ok}" = 0 ]; then
        color=clear summary='not checked'
        printf '%s\n' "curl (${FRITZ_WIFI_CURL}) not found - install curl to enable this test" >"${hw}/notes"
        # Nothing was measured: no RRD update at all.
    elif collect_host; then
        if [ "${nif}" -eq 0 ]; then
            [ "${color}" != green ] || color=clear
            [ -s "${hw}/notes" ] || printf '%s\n' 'no enabled Wi-Fi network on this device' >>"${hw}/notes"
            summary='no enabled Wi-Fi network'
        else
            metric clients_total "${total:-U}"
            summary="${total:-n/a} client(s) on ${nif} AP interface(s)"
        fi
    else
        partial=1
    fi
    cred_config=''

    # After any failure the RRDs of the last clean run that got no value
    # now are set to U: rrdtool would bridge a single missing update
    # (heartbeat 600 s) with the next value and hide the outage.
    if [ "${partial}" = 1 ] && [ -r "${statefile}" ]; then
        # FILENAME, not NR == FNR: the metrics file may well be empty.
        awk -v m="${hw}/metrics" 'FILENAME == m { have[$1] = 1; next }
             $1 ~ /^[a-z0-9_]+$/ && !($1 in have) { have[$1] = 1; print $1, "U" }' \
            "${hw}/metrics" "${statefile}" >"${hw}/unknown" || fail 'Cannot read the saved RRD names'
        cat "${hw}/unknown" >>"${hw}/metrics" || fail 'Cannot build the RRD values'
    fi
    [ "${color}" != red ] || log error "${host}: $(head -n 1 "${hw}/notes" | sed 's/^&[a-z]* //')"
    [ "${color}" != yellow ] || log warning "${host}: $(head -n 1 "${hw}/notes" | sed 's/^&[a-z]* //')"

    # The details are wrapped in ncv_skip markers: the wifi column is an
    # NCV test, and xymond_rrd parses status text too ("channel=11"
    # would otherwise become a stray wifi,<radio>_channel.rrd).
    {
        printf 'status+%s %s.%s %s %s - wifi: %s\n\n' "${FRITZ_WIFI_LIFETIME}" "${wirehost}" \
            "${FRITZ_WIFI_COLUMN}" "${color}" "$(date)" "${summary}"
        printf '%s\n' '<!-- ncv_skipstart -->'
        if [ -s "${hw}/notes" ]; then cat "${hw}/notes"; printf '\n'; fi
        if [ -s "${hw}/ifs" ]; then render_details; printf '\n'; fi
        printf 'Source: TR-064 at %s [tr064]. Channel utilization, noise, TX power,\n' "${base_url}"
        printf '%s\n' 'throughput, airtime and retries are not provided by TR-064 (n/a).'
        printf '%s\n' 'Channel width is the widest link of the associated clients (n/a without clients).'
        printf '%s\n' '<!-- ncv_skipend -->'
    } >"${hw}/status" || fail 'Cannot build the status message'
    h_sent=1
    deliver "$(cat "${hw}/status")" || h_sent=0
    if [ -s "${hw}/metrics" ]; then
        deliver "data ${wirehost}.trends
$(awk '{ printf "[wifi,%s.rrd]\nDS:lambda:GAUGE:600:U:U %s\n", $1, $2 }' "${hw}/metrics")" || h_sent=0
    fi
    if [ "${h_sent}" = 0 ]; then
        log error "${host}: Xymon delivery failed; state not updated"
        sent_all=0
        return
    fi

    # Remember the names: a clean run replaces the list, a failed one
    # keeps the old names too. Never in a dry run.
    if [ "${FRITZ_WIFI_DRY_RUN}" = 0 ] && [ "${curl_ok}" = 1 ]; then
        if [ "${partial}" = 1 ] && [ -r "${statefile}" ]; then
            { awk '{ print $1 }' "${hw}/metrics"; awk '$1 ~ /^[a-z0-9_]+$/ { print $1 }' "${statefile}"; } | sort -u
        else
            awk '{ print $1 }' "${hw}/metrics" | sort -u
        fi >"${hw}/names"
        if ! mv "${hw}/names" "${statefile}"; then log error "${host}: cannot write ${statefile}"; fi
    fi
}

# Hosts one after another (few devices; a dead one costs at most the
# connect timeout). fd 3 keeps the list away from curl's stdin.
while read -r t_host t_ip <&3; do
    poll_host "${t_host}" "${t_ip:-}"
done 3<"${work}/targets"
[ "${sent_all}" = 1 ] || exit 1
log debug 'Collection complete'
exit 0
