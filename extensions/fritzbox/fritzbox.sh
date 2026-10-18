#!/bin/sh
# fritzbox.sh - server-side Xymon collector for AVM FRITZ!Box routers,
# read over TR-064 (and UPnP/IGD for the WAN counters and link rates).
#
# Every hosts.cfg host tagged "fritzbox" is polled once per run: one
# login check, one device description, then the enabled modules. Each
# module reports one column on the box's own host:
#   dsl -> fritzdsl  DSL line state, rates, margins, error counters
#   wan -> fritzwan  WAN link state, throughput, utilization
#   sys -> fritzsys  model, firmware, updates, uptime, clock offset
#   log -> fritzlog  new event log entries, classified by a rules file
#   fw  -> fritzfw   port mappings, UPnP, remote access, MyFRITZ, DynDNS
#   lan -> fritzlan  LAN throughput, host counts, required devices
#   tel -> fritztel  SIP account registration, DECT handsets
#   plc -> (none)    powerline adapter list for powerline.sh
# RRD values go out as native "data HOST.trends" messages, which - unlike
# NCV - keep an explicit U: a failed poll becomes a graph gap, never a
# zero. Only read-only TR-064 actions are ever sent.
#
# Version: 1.0.5  (2026-10-18)
#
# Program flow:
# 1. Resolve settings (defaults < config < environment < CLI), validate
#    them, optionally prompt for the password (--ask-password).
# 2. Take the lock, build the host list (hosts.cfg tag or --host) and
#    check the password file (owner and permissions).
# 3. Per host, one after another: read /tr64desc.xml (and /igddesc.xml),
#    probe the login, then run the enabled modules within the run time
#    budget. A transport failure or a refused login ends the host.
# 4. Per column: color, status text and RRD values; after a failure the
#    RRD names of the last clean run get U.
# 5. Deliver status and trends (or print them with --dry-run), then save
#    the per-host state and the powerline hand-over file.
#
# Usage: fritzbox.sh --config FILE [--host NAME] [--dry-run] [--help]
set -u
CONFIG_NAME=fritzbox.cfg
SCRIPT_VERSION=1.0.5

usage() {
    cat <<'EOF'
Usage: fritzbox.sh [--config FILE] [--host NAME]... [--user NAME]
                   [--ask-password] [--set KEY=VALUE]...
                   [--silent | --verbose] [--debug] [--dry-run]
                   [--help] [--version]

Polls AVM FRITZ!Box routers over TR-064 and reports the columns
fritzdsl, fritzwan, fritzsys, fritzlog, fritzfw, fritzlan and fritztel
on each box's host, plus the adapter list read by powerline.sh.

  --config FILE     FRITZBOX_CONFIG; default XYMONHOME/etc/
                    my-xymon-extensions-server/fritzbox.cfg
  --host NAME       FRITZBOX_HOSTS (space-separated list); poll only
                    these hosts instead of every host tagged
                    FRITZBOX_TAG. Repeatable.
  --user NAME       FRITZBOX_USER; TR-064 user name. Overrides the user
                    column of the password file (default: xymon).
  --ask-password    Prompt for the password on the terminal (no echo).
                    Wins over FRITZPASSWORT and the password file and
                    applies to every polled host; combine with --host.
  -s, --silent      FRITZBOX_SILENT=1; errors only
  -v, --verbose     FRITZBOX_VERBOSE=1; diagnostic messages
  --debug           FRITZBOX_DEBUG=1; raw TR-064 responses on stderr
                    (session IDs masked, credentials never printed)
  --dry-run         FRITZBOX_DRY_RUN=1; print the status and trends
                    messages on stdout, send nothing, keep the state
  --set KEY=VALUE   Any of these environment/config settings:
    FRITZBOX_ENABLED (1), FRITZBOX_TAG (fritzbox)
    FRITZBOX_MODULES ("dsl wan sys log fw lan tel plc")
    FRITZBOX_PASSFILE (XYMONHOME/etc/my-xymon-extensions-server/
      fritz.passwd, shared with fritz-wifi)
    FRITZBOX_PORT (49000), FRITZBOX_CONNECT_TIMEOUT (3 seconds),
    FRITZBOX_MAX_TIME (5 seconds per request)
    FRITZBOX_RUN_BUDGET (180 seconds for network requests)
    FRITZBOX_LIFETIME (15 minutes), FRITZBOX_HOLD_MINUTES (60)
    FRITZBOX_STATE_DIR (XYMONVAR/fritzbox), FRITZBOX_MASK (0)
    FRITZBOX_HOSTSCFG (HOSTSCFG), FRITZBOX_XYMONCFG
      (XYMONHOME/bin/xymoncfg), FRITZBOX_CURL (curl)
    fritzdsl: FRITZBOX_DSL_MARGIN_WARN (6), FRITZBOX_DSL_MARGIN_CRIT (3)
      dB; FRITZBOX_DSL_CRC_WARN (30), FRITZBOX_DSL_CRC_CRIT (300)
      CRC errors per minute; FRITZBOX_DSL_WAN_SERVICE (auto|ppp|ip|off)
    fritzwan: FRITZBOX_WAN_MODE (auto|igd|tr064),
      FRITZBOX_WAN_UTIL_WARN (0), FRITZBOX_WAN_UTIL_CRIT (0) percent
    fritzsys: FRITZBOX_SYS_CLOCK_WARN (60), FRITZBOX_SYS_CLOCK_CRIT
      (300) seconds; FRITZBOX_SYS_UPDATE_COLOR (yellow),
      FRITZBOX_SYS_UPDATE_FAILED_COLOR (green)
    fritzlog: FRITZBOX_LOG_RULES (CONFIGDIR/fritzbox-log.rules),
      FRITZBOX_LOG_SHOW (20), FRITZBOX_LOG_UNMATCHED_COLOR (yellow)
    fritzfw: FRITZBOX_FW_EXPECTED (""), FRITZBOX_FW_COLOR (yellow)
    fritzlan: FRITZBOX_LAN_REQUIRED (""), FRITZBOX_LAN_REQUIRED_COLOR
      (yellow), FRITZBOX_LAN_NEW_MAC (0)
    fritztel: FRITZBOX_TEL_COLOR (red)
    FRITZBOX_SILENT, FRITZBOX_VERBOSE, FRITZBOX_DEBUG,
    FRITZBOX_DRY_RUN (0)
    FRITZBOX_NOW (epoch seconds; replay tests only)
  -h, --help        Show this help without touching devices or state.
  --version         Print the version.

Environment only:
  FRITZPASSWORT     Password for every polled host. Wins over the
                    password file, loses against --ask-password. It is
                    removed from the environment before curl runs.
With --ask-password or FRITZPASSWORT the password file is not read; the
user is then FRITZBOX_USER or "xymon".

Precedence: CLI > exported environment > config file > defaults.
Colors are green, yellow or red; a "green" color setting turns that
finding into a note without changing the column color. The run budget
leaves one minute for status delivery before the shipped Xymon task's
MAXTIME of four minutes. Silent and verbose are mutually exclusive; on
the command line either switch overrides the other one's setting.
Automated runs log via syslog (tag fritzbox); errors also go to stderr
(the task's log file).

Password file: the fritz-wifi format, one "host_or_ip user password"
line per device; the password is the rest of the line, "-" as user means
"xymon". It must be a regular file either owned by the running user
without any group/other permission (chmod 600), or owned by root with
the running user's primary group, read-only for that group and nothing
for others (chown root:xymon, chmod 640); anything else is rejected.
Passwords reach curl only on stdin, never on its command line.

Example: fritzbox.sh --host fritz.box --ask-password --dry-run
EOF
}

# Restrict configurable names; export a validated NAME=VALUE, never eval.
setting() {
    # shellcheck disable=SC2163 # Export a validated NAME=VALUE, not positional $1.
    case "${1%%=*}" in
        FRITZBOX_ENABLED|FRITZBOX_TAG|FRITZBOX_HOSTS|FRITZBOX_USER|FRITZBOX_PASSFILE|FRITZBOX_PORT|FRITZBOX_CONNECT_TIMEOUT|FRITZBOX_MAX_TIME|FRITZBOX_RUN_BUDGET|FRITZBOX_LIFETIME|FRITZBOX_HOLD_MINUTES|FRITZBOX_STATE_DIR|FRITZBOX_MASK|FRITZBOX_MODULES|FRITZBOX_HOSTSCFG|FRITZBOX_XYMONCFG|FRITZBOX_CURL|FRITZBOX_DSL_MARGIN_WARN|FRITZBOX_DSL_MARGIN_CRIT|FRITZBOX_DSL_CRC_WARN|FRITZBOX_DSL_CRC_CRIT|FRITZBOX_DSL_WAN_SERVICE|FRITZBOX_WAN_MODE|FRITZBOX_WAN_UTIL_WARN|FRITZBOX_WAN_UTIL_CRIT|FRITZBOX_SYS_CLOCK_WARN|FRITZBOX_SYS_CLOCK_CRIT|FRITZBOX_SYS_UPDATE_COLOR|FRITZBOX_SYS_UPDATE_FAILED_COLOR|FRITZBOX_LOG_RULES|FRITZBOX_LOG_SHOW|FRITZBOX_LOG_UNMATCHED_COLOR|FRITZBOX_FW_EXPECTED|FRITZBOX_FW_COLOR|FRITZBOX_LAN_REQUIRED|FRITZBOX_LAN_REQUIRED_COLOR|FRITZBOX_LAN_NEW_MAC|FRITZBOX_TEL_COLOR|FRITZBOX_SILENT|FRITZBOX_VERBOSE|FRITZBOX_DEBUG|FRITZBOX_DRY_RUN|FRITZBOX_NOW) export "${1}" ;;
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
config=${FRITZBOX_CONFIG:-${XYMONHOME:-}/etc/my-xymon-extensions-server/${CONFIG_NAME}}
explicit_config=0
[ -z "${FRITZBOX_CONFIG:-}" ] || explicit_config=1
while [ "${#}" -gt 0 ]; do
    case "${1}" in
        -h|--help) usage; exit 0 ;;
        --version) printf 'fritzbox.sh %s\n' "${SCRIPT_VERSION}"; exit 0 ;;
        --config|--host|--user|--set)
            [ "${#}" -ge 2 ] || { printf '%s requires a value\n' "${1}" >&2; exit 2; }
            case "${1}" in
                --config) config=${2}; explicit_config=1 ;;
                --host) cli_hosts="${cli_hosts} ${2}" ;;
                --user) cli="${cli}
FRITZBOX_USER=${2}" ;;
                --set) case "${2}" in FRITZBOX_*=*) cli="${cli}
${2}" ;; *) printf '%s\n' 'Expected FRITZBOX_KEY=VALUE' >&2; exit 2 ;; esac ;;
            esac
            shift 2 ;;
        --ask-password) ask_password=1; shift ;;
        # A CLI switch also clears its counterpart, so --verbose works
        # against FRITZBOX_SILENT=1 from the config or environment.
        -s|--silent) cli_silent=1; cli="${cli}
FRITZBOX_SILENT=1
FRITZBOX_VERBOSE=0"; shift ;;
        -v|--verbose) cli_verbose=1; cli="${cli}
FRITZBOX_VERBOSE=1
FRITZBOX_SILENT=0"; shift ;;
        --debug) cli="${cli}
FRITZBOX_DEBUG=1"; shift ;;
        --dry-run) cli="${cli}
FRITZBOX_DRY_RUN=1"; shift ;;
        *) printf 'Unknown option: %s (see --help)\n' "${1}" >&2; exit 2 ;;
    esac
done
if [ "${cli_silent}${cli_verbose}" = 11 ]; then
    printf '%s\n' 'Silent and verbose are mutually exclusive (see --help)' >&2; exit 2
fi
[ -z "${cli_hosts}" ] || cli="${cli}
FRITZBOX_HOSTS=${cli_hosts# }"

# Defaults, then the trusted admin-owned config, then the saved
# environment and the command line on top (CLI > env > config > default).
saved_env=$(env | LC_ALL=C sort | awk '/^FRITZBOX_/ && !/^FRITZBOX_CONFIG=/')
confdir=${XYMONHOME:-}/etc/my-xymon-extensions-server
FRITZBOX_ENABLED=1 FRITZBOX_TAG=fritzbox FRITZBOX_HOSTS='' FRITZBOX_USER=''
FRITZBOX_PASSFILE=${confdir}/fritz.passwd
FRITZBOX_PORT=49000 FRITZBOX_CONNECT_TIMEOUT=3 FRITZBOX_MAX_TIME=5
FRITZBOX_RUN_BUDGET=180 FRITZBOX_LIFETIME=15 FRITZBOX_HOLD_MINUTES=60
FRITZBOX_STATE_DIR=${XYMONVAR:-}/fritzbox FRITZBOX_MASK=0
FRITZBOX_MODULES='dsl wan sys log fw lan tel plc'
FRITZBOX_HOSTSCFG=${HOSTSCFG:-${XYMONHOME:-}/etc/hosts.cfg}
FRITZBOX_XYMONCFG=${XYMONHOME:-}/bin/xymoncfg FRITZBOX_CURL=curl
FRITZBOX_DSL_MARGIN_WARN=6 FRITZBOX_DSL_MARGIN_CRIT=3
FRITZBOX_DSL_CRC_WARN=30 FRITZBOX_DSL_CRC_CRIT=300 FRITZBOX_DSL_WAN_SERVICE=auto
FRITZBOX_WAN_MODE=auto FRITZBOX_WAN_UTIL_WARN=0 FRITZBOX_WAN_UTIL_CRIT=0
FRITZBOX_SYS_CLOCK_WARN=60 FRITZBOX_SYS_CLOCK_CRIT=300
FRITZBOX_SYS_UPDATE_COLOR=yellow FRITZBOX_SYS_UPDATE_FAILED_COLOR=green
FRITZBOX_LOG_RULES=${confdir}/fritzbox-log.rules FRITZBOX_LOG_SHOW=20
FRITZBOX_LOG_UNMATCHED_COLOR=yellow
FRITZBOX_FW_EXPECTED='' FRITZBOX_FW_COLOR=yellow
FRITZBOX_LAN_REQUIRED='' FRITZBOX_LAN_REQUIRED_COLOR=yellow FRITZBOX_LAN_NEW_MAC=0
FRITZBOX_TEL_COLOR=red
FRITZBOX_SILENT=0 FRITZBOX_VERBOSE=0 FRITZBOX_DEBUG=0 FRITZBOX_DRY_RUN=0
FRITZBOX_NOW=''
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

# Explicit logging was requested for the server tasks: syslog always,
# the console only when interactive or verbose; errors always on stderr
# (the task's LOGFILE). Never pass credentials to this function.
log() {
    level=${1}; shift
    [ "${level}" != debug ] || [ "${FRITZBOX_VERBOSE}" = 1 ] || return 0
    if command -v logger >/dev/null 2>&1; then logger -t fritzbox -- "${level}: ${*}" || :; fi
    if [ "${level}" = error ]; then printf 'fritzbox: %s\n' "${*}" >&2
    elif [ "${FRITZBOX_SILENT}" = 0 ] && { [ -t 2 ] || [ "${FRITZBOX_VERBOSE}" = 1 ]; }; then
        printf 'fritzbox: %s: %s\n' "${level}" "${*}" >&2
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

# ----------------------------------------------------------------------
# Validate every setting before it is used in arithmetic, paths or URLs.
# ----------------------------------------------------------------------
for n in "${FRITZBOX_ENABLED}" "${FRITZBOX_SILENT}" "${FRITZBOX_VERBOSE}" "${FRITZBOX_DEBUG}" "${FRITZBOX_DRY_RUN}" "${FRITZBOX_MASK}" "${FRITZBOX_LAN_NEW_MAC}"; do
    case "${n}" in 0|1) ;; *) printf '%s\n' 'Boolean settings must be 0 or 1' >&2; exit 2 ;; esac
done
if [ "${FRITZBOX_SILENT}${FRITZBOX_VERBOSE}" = 11 ]; then
    printf '%s\n' 'Silent and verbose are mutually exclusive (see --help)' >&2; exit 2
fi
# Disabled: quiet for the task, a hint for a manual run on a terminal.
if [ "${FRITZBOX_ENABLED}" != 1 ]; then
    [ ! -t 2 ] || printf '%s\n' 'fritzbox: disabled (FRITZBOX_ENABLED=0) - nothing to do; see --help' >&2
    exit 0
fi
for n in "${FRITZBOX_PORT}" "${FRITZBOX_CONNECT_TIMEOUT}" "${FRITZBOX_MAX_TIME}" "${FRITZBOX_RUN_BUDGET}" "${FRITZBOX_LIFETIME}" "${FRITZBOX_HOLD_MINUTES}" "${FRITZBOX_LOG_SHOW}" "${FRITZBOX_SYS_CLOCK_WARN}" "${FRITZBOX_SYS_CLOCK_CRIT}"; do
    case "${n}" in ''|*[!0-9]*) fail "Expected a positive integer, got '${n}'" ;; esac
    [ "${n}" -gt 0 ] || fail 'Port, timeouts, lifetime, hold, LOG_SHOW and clock limits must be positive'
done
[ "${FRITZBOX_PORT}" -le 65535 ] || fail "Invalid TR-064 port ${FRITZBOX_PORT}"
[ "${FRITZBOX_RUN_BUDGET}" -lt 240 ] || fail 'The run budget must be below the task MAXTIME of 240 seconds'
# Thresholds may be decimals; 0 disables a check.
for n in "${FRITZBOX_DSL_MARGIN_WARN}" "${FRITZBOX_DSL_MARGIN_CRIT}" "${FRITZBOX_DSL_CRC_WARN}" "${FRITZBOX_DSL_CRC_CRIT}" "${FRITZBOX_WAN_UTIL_WARN}" "${FRITZBOX_WAN_UTIL_CRIT}"; do
    case "${n}" in ''|*[!0-9.]*|*.*.*|.*|*.) fail "Expected a number, got '${n}'" ;; esac
done
for n in "${FRITZBOX_SYS_UPDATE_COLOR}" "${FRITZBOX_SYS_UPDATE_FAILED_COLOR}" "${FRITZBOX_LOG_UNMATCHED_COLOR}" "${FRITZBOX_FW_COLOR}" "${FRITZBOX_LAN_REQUIRED_COLOR}" "${FRITZBOX_TEL_COLOR}"; do
    case "${n}" in green|yellow|red) ;; *) fail "Colors must be green, yellow or red, got '${n}'" ;; esac
done
case "${FRITZBOX_DSL_WAN_SERVICE}" in auto|ppp|ip|off) ;; *) fail 'FRITZBOX_DSL_WAN_SERVICE must be auto, ppp, ip or off' ;; esac
case "${FRITZBOX_WAN_MODE}" in auto|igd|tr064) ;; *) fail 'FRITZBOX_WAN_MODE must be auto, igd or tr064' ;; esac
for m in ${FRITZBOX_MODULES}; do
    case "${m}" in dsl|wan|sys|log|fw|lan|tel|plc) ;; *) fail "Unknown module in FRITZBOX_MODULES: ${m}" ;; esac
done
case "${FRITZBOX_TAG}" in ''|*[!A-Za-z0-9_-]*) fail 'Invalid hosts.cfg tag' ;; esac
case "${FRITZBOX_USER}" in *:*) fail 'The TR-064 user name must not contain a colon' ;; esac
case "${FRITZBOX_STATE_DIR}" in /*) ;; *) fail 'The state directory must be absolute' ;; esac
[ "${FRITZBOX_STATE_DIR}" != /fritzbox ] || fail 'Set XYMONVAR or FRITZBOX_STATE_DIR to a persistent writable directory'
case "${FRITZBOX_NOW}" in *[!0-9]*) fail 'FRITZBOX_NOW must be epoch seconds' ;; esac
if [ "${FRITZBOX_DRY_RUN}" = 0 ] && { [ -z "${XYMON:-}" ] || [ -z "${XYMSRV:-}" ]; }; then
    fail 'Use the Xymon server environment (XYMON/XYMSRV), or --dry-run'
fi
if [ "${FRITZBOX_DRY_RUN}" = 0 ]; then
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

mkdir -p "${FRITZBOX_STATE_DIR}" || fail "Cannot create state directory ${FRITZBOX_STATE_DIR}"
exec 9>"${FRITZBOX_STATE_DIR}/lock" || fail "Cannot open ${FRITZBOX_STATE_DIR}/lock"
flock -n 9 || { log debug 'Another fritzbox run holds the lock'; exit 0; }
work=$(mktemp -d "${FRITZBOX_STATE_DIR}/run.XXXXXX") || fail 'Cannot create temporary directory'

# now_s - the current time; FRITZBOX_NOW replaces the clock in tests.
now_s() {
    if [ -n "${FRITZBOX_NOW}" ]; then printf '%s' "${FRITZBOX_NOW}"; else date +%s; fi
}
poll_deadline=$(($(date +%s) + FRITZBOX_RUN_BUDGET))
hold_seconds=$((FRITZBOX_HOLD_MINUTES * 60))

# Reserve time for status delivery: a request may consume MAX_TIME even
# when the device never replies. Expired requests are never started.
request_time_available() {
    rt_now=$(date +%s) || fail 'Cannot read the current time'
    [ "$((rt_now + FRITZBOX_MAX_TIME))" -le "${poll_deadline}" ]
}

# ----------------------------------------------------------------------
# Host list: hosts.cfg flattened by Xymon's own parser (includes!), like
# powerline; a plain file only when it has no include statements.
# ----------------------------------------------------------------------
load_hosts() {
    if [ -x "${FRITZBOX_XYMONCFG}" ]; then
        "${FRITZBOX_XYMONCFG}" "${FRITZBOX_HOSTSCFG}" >"${work}/hosts.cfg" || return 1
    else
        [ -r "${FRITZBOX_HOSTSCFG}" ] || return 1
        if grep -E '^[[:space:]]*(optional[[:space:]]+)?(include|directory|netinclude|dispinclude)[[:space:]]' "${FRITZBOX_HOSTSCFG}" >/dev/null; then
            log error 'hosts.cfg contains includes; configure FRITZBOX_XYMONCFG'
            return 1
        fi
        cp "${FRITZBOX_HOSTSCFG}" "${work}/hosts.cfg" || return 1
    fi
}

# Output lines "hostname ip"; ip is "" when unknown (connect by name).
if [ -n "${FRITZBOX_HOSTS}" ]; then
    # Manual selection: hosts.cfg only supplies the IP, if readable.
    load_hosts 2>/dev/null || : >"${work}/hosts.cfg"
    for h in ${FRITZBOX_HOSTS}; do
        case "${h}" in *[!A-Za-z0-9_.-]*|-*) fail "Invalid host name: ${h}" ;; esac
        awk -v h="${h}" '$2 == h && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { ip = $1; exit }
            END { print h, ip }' "${work}/hosts.cfg"
    done >"${work}/targets" || fail 'Cannot build the host list'
else
    load_hosts || fail "Cannot load hosts.cfg (${FRITZBOX_HOSTSCFG})"
    awk -v tag="${FRITZBOX_TAG}" '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
        for (i = 3; i <= NF; i++) if ($i == tag) { print $2, $1; break }
    }' "${work}/hosts.cfg" | awk '$1 ~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/ && !seen[$1]++' \
        >"${work}/targets" || fail 'Cannot parse hosts.cfg'
fi
if [ ! -s "${work}/targets" ]; then
    log info "No host tagged ${FRITZBOX_TAG} in hosts.cfg - nothing to poll"
    exit 0
fi

# ----------------------------------------------------------------------
# Password file: read as data, never sourced - the fritz-wifi rules.
# Only a regular file owned by the running user without any group/other
# permission is used - the same rule ssh applies to private keys - or one
# owned by root that only the running user's primary group may read
# (root:xymon 640): then the collector cannot change the file, and no one
# outside that group can read it. Group write access is refused in both.
# ----------------------------------------------------------------------
passfile_ok=0
passfile_problem=''
passfile_malformed=''
check_passfile() {
    pf=${FRITZBOX_PASSFILE}
    if [ -z "${pf}" ] || { [ ! -e "${pf}" ] && [ ! -L "${pf}" ]; }; then
        passfile_problem="no password file at ${pf:-(unset)}"
        return
    fi
    uid=$(id -u) || { passfile_problem='cannot determine the own user id'; return; }
    gid=$(id -g) || { passfile_problem='cannot determine the own group id'; return; }
    # find -prune tests the path itself; a symlink fails -type f. Two
    # separate calls instead of \( ... -o ... \) keep the expressions
    # simple for every find implementation.
    if [ -z "$(find "${pf}" -prune -type f -user "${uid}" ! -perm -040 ! -perm -020 ! -perm -010 ! -perm -004 ! -perm -002 ! -perm -001 -print)" ] &&
        [ -z "$(find "${pf}" -prune -type f -user 0 -group "${gid}" -perm -040 ! -perm -020 ! -perm -010 ! -perm -004 ! -perm -002 ! -perm -001 -print)" ]; then
        passfile_problem="password file ${pf} rejected: it must be a regular file owned by uid ${uid} without any group/other permission (chmod 600), or owned by root with group gid ${gid}, group read-only and no other permission (chmod 640)"
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
    pf_msgs=$(awk '
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
        }' "${pf}") || pf_msgs=''
    [ -z "${pf_msgs}" ] || printf '%s\n' "${pf_msgs}" | while IFS= read -r msg; do
        log warning "${pf} ${msg}"
    done
    # The malformed lines (not the duplicates) also go into the status of
    # a host without a password: numbers only, at most five of them.
    passfile_malformed=$(printf '%s\n' "${pf_msgs}" | awk '
        /^line [0-9]+: / && !/: duplicate entry / {
            n++; sub(/: /, " - ")
            if (n <= 5) list = list (n > 1 ? "; " : "") $0
        }
        END {
            if (n) printf "%d malformed line%s ignored: %s%s", n, (n > 1 ? "s" : ""), list, (n > 5 ? "; ..." : "")
        }')
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
        }' "${FRITZBOX_PASSFILE}"
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
command -v "${FRITZBOX_CURL}" >/dev/null 2>&1 || curl_ok=0

# Upper limits for indexed lists, so a broken or huge reply cannot
# stretch a run beyond MAXTIME.
max_entries=32

# ----------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------

# is_uint VALUE - true for a non-empty decimal integer.
is_uint() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}

# is_num VALUE - true for a decimal number (optional sign and fraction).
is_num() {
    case "${1:-}" in ''|-|*[!0-9.-]*|?*-*|*.*.*) return 1 ;; esac
    return 0
}

# fbelow A B - true if A < B (floating point)
fbelow() {
    awk -v a="${1}" -v b="${2}" 'BEGIN { exit !(a + 0 < b + 0) }'
}

# db10 VALUE - tenths of a dB as dB (65 -> 6.5); empty for a non-number.
db10() {
    is_uint "${1:-}" || return 0
    awk -v v="${1}" 'BEGIN { printf "%.1f", v / 10 }'
}

# mbit BITS - bit/s as Mbit/s with one decimal.
mbit() {
    is_uint "${1:-}" || return 0
    awk -v v="${1}" 'BEGIN { printf "%.1f", v / 1000000 }'
}

# gib BYTES - bytes as GiB with one decimal.
gib() {
    is_uint "${1:-}" || return 0
    awk -v v="${1}" 'BEGIN { printf "%.1f", v / 1073741824 }'
}

# fmt_duration SECONDS - "3d 7h 31m"
fmt_duration() {
    printf '%dd %dh %dm' "$(($1 / 86400))" "$(($1 % 86400 / 3600))" "$(($1 % 3600 / 60))"
}

# clean TEXT [MAX] - a device string for status text: no control
# characters, no "|" (record separator), at most MAX bytes (default 120).
# The box sends UTF-8 and the cut counts bytes (LC_ALL=C), so a
# character split at the end is removed. XML escapes stay: the Xymon
# status page is HTML.
u8_lead=$(printf '\300-\377') u8_lead3=$(printf '\340-\377')
u8_lead4=$(printf '\360-\377') u8_cont=$(printf '\200-\277')
clean() {
    printf '%s' "${1}" | tr -d '\001-\037\177|' | cut -b "1-${2:-120}" |
        sed -E "s/([${u8_lead}]|[${u8_lead3}][${u8_cont}]|[${u8_lead4}][${u8_cont}][${u8_cont}])\$//"
}

# mask TEXT - FRITZBOX_MASK=1 hides addresses and long numbers (public
# IPs, prefixes, phone numbers) in texts that go into a status.
mask() {
    if [ "${FRITZBOX_MASK}" = 1 ]; then
        printf '%s\n' "${1}" | sed -E \
            -e 's/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/x.x.x.x/g' \
            -e 's/[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{0,4}){3,7}(\/[0-9]+)?/xxxx::/g' \
            -e 's/[0-9]{5,}/#####/g'
    else
        printf '%s\n' "${1}"
    fi
}

# worst COLOR COLOR - the more severe of red, yellow, green and clear.
worst() {
    for w_c in red yellow green clear; do
        if [ "${1}" = "${w_c}" ] || [ "${2}" = "${w_c}" ]; then printf '%s' "${w_c}"; return; fi
    done
    printf '%s' green
}

# ----------------------------------------------------------------------
# TR-064 plumbing
# ----------------------------------------------------------------------

# debug_dump LABEL - raw response of the last request on stderr, with
# session IDs masked (--debug). Credentials are never part of it.
debug_dump() {
    [ "${FRITZBOX_DEBUG}" = 1 ] || return 0
    {
        printf 'fritzbox: debug: %s %s\n' "${host}" "${1}"
        sed 's/sid=[^&"<[:space:]]*/sid=XXXX/g' "${hw}/resp"
        printf '\n'
    } >&2
}

# field NAME - text of the first element NAME in the last response. The
# response was split at every "<", so an element is a line "NAME>text".
field() {
    awk -v n="${1}" 'index($0, n ">") == 1 { print substr($0, length(n) + 2); exit }' "${hw}/resp.lines"
}

# fetch PATH - unauthenticated GET of PATH on the box into ${hw}/resp.
# Returns 0 = HTTP 200, 1 = transport error, 4 = other HTTP code,
# 5 = run time budget exhausted before the request.
fetch() {
    HTTPCODE='' ERRCODE='' CURLERR=''
    request_time_available || return 5
    : >"${hw}/resp"
    HTTPCODE=$("${FRITZBOX_CURL}" --silent --show-error \
        --connect-timeout "${FRITZBOX_CONNECT_TIMEOUT}" --max-time "${FRITZBOX_MAX_TIME}" \
        --output "${hw}/resp" --write-out '%{http_code}' \
        "${base_url}${1}" </dev/null 2>"${hw}/curlerr")
    f_rc=${?}
    CURLERR=$(head -n 1 "${hw}/curlerr")
    debug_dump "GET ${1%%\?*} -> curl ${f_rc}, HTTP ${HTTPCODE:-none}"
    [ "${f_rc}" -eq 0 ] || return 1
    [ "${HTTPCODE}" = 200 ] || return 4
    return 0
}

# soap MODE PATH URN ACTION [ARGXML] - one SOAP call; MODE is auth
# (TR-064 digest login) or noauth (UPnP/IGD). Only read-only actions are
# allowed, and none that returns a secret. Sets HTTPCODE, ERRCODE and
# CURLERR. Returns 0 = HTTP 200, 1 = transport error or timeout,
# 2 = authentication refused (401, UPnP 606), 3 = array index invalid
# (UPnP 713), 4 = any other error, 5 = run time budget exhausted.
# A 1, 2 or 5 also ends the poll of this host (host_abort).
soap() {
    s_mode=${1} s_path=${2} s_urn=${3} s_act=${4} s_args=${5:-}
    HTTPCODE='' ERRCODE='' CURLERR=''
    [ "${host_abort}" = 0 ] || return "${host_abort}"
    case "${s_act}" in
        GetSecurityKeys|X_AVM-DE_GetVoIPAccount|X_AVM-DE_GetClient*|X_AVM-DE_GetConfigFile)
            log error "Refusing TR-064 action ${s_act}: it returns secrets"; return 4 ;;
        Get*|X_AVM-DE_Get*|X_AVM_DE_Get*) ;;
        *) log error "Refusing TR-064 action ${s_act}: not read-only"; return 4 ;;
    esac
    if ! request_time_available; then host_abort=5; return 5; fi
    if [ "${s_mode}" = auth ]; then s_cfg=${cred_config}; else s_cfg=''; fi
    : >"${hw}/resp"
    # The action element needs its own closing tag: AVM devices answer a
    # self-closing one with "502 XML error".
    # --digest --ntlm, not --digest alone: with a single method curl sends
    # its first, unauthenticated POST as an empty "probe" (lib/http.c),
    # and AVM devices answer the empty body with UPnP error 502 instead
    # of the 401 challenge. With two methods curl sends the full body,
    # then picks Digest from the challenge. Not --anyauth: that would
    # fall back to Basic, the password in clear text over plain HTTP.
    HTTPCODE=$(printf '%s\n' "${s_cfg}" | "${FRITZBOX_CURL}" --silent --show-error \
        --digest --ntlm --config - \
        --connect-timeout "${FRITZBOX_CONNECT_TIMEOUT}" --max-time "${FRITZBOX_MAX_TIME}" \
        --output "${hw}/resp" --write-out '%{http_code}' \
        --header 'Content-Type: text/xml; charset="utf-8"' \
        --header "SoapAction: \"${s_urn}#${s_act}\"" \
        --data "<?xml version='1.0' encoding='utf-8'?><s:Envelope s:encodingStyle='http://schemas.xmlsoap.org/soap/encoding/' xmlns:s='http://schemas.xmlsoap.org/soap/envelope/'><s:Body><u:${s_act} xmlns:u='${s_urn}'>${s_args}</u:${s_act}></s:Body></s:Envelope>" \
        "${base_url}${s_path}" 2>"${hw}/curlerr")
    s_rc=${?}
    CURLERR=$(head -n 1 "${hw}/curlerr")
    tr '\n' ' ' <"${hw}/resp" | tr '<' '\n' >"${hw}/resp.lines"
    debug_dump "${s_urn##*:service:} ${s_act} -> curl ${s_rc}, HTTP ${HTTPCODE:-none}"
    if [ "${s_rc}" -ne 0 ]; then host_abort=1; return 1; fi
    case "${HTTPCODE}" in
        200) return 0 ;;
        401) host_abort=2; return 2 ;;  # HTML body, not a SOAP fault - never parsed
    esac
    ERRCODE=$(field errorCode)
    case "${ERRCODE}" in
        713) return 3 ;;
        606) host_abort=2; return 2 ;;  # UPnP "Action not authorized"
    esac
    return 4
}

# svc_url FILE URN - control URL of a service from a parsed description.
svc_url() {
    awk -v t="${2}" '$1 == t { print $2; exit }' "${1}"
}

# has_service URN / has_igd URN - true when the box offers the service.
has_service() {
    [ -n "$(svc_url "${hw}/services" "${1}")" ]
}
has_igd() {
    load_igd
    [ -n "$(svc_url "${hw}/igd" "${1}")" ]
}

# tr64 URN ACTION [ARGXML] - authenticated TR-064 call; 6 = no service.
tr64() {
    t_url=$(svc_url "${hw}/services" "${1}")
    [ -n "${t_url}" ] || return 6
    soap auth "${t_url}" "${1}" "${2}" "${3:-}"
}

# igd URN ACTION - unauthenticated UPnP/IGD call; 6 = no service.
igd() {
    load_igd
    t_url=$(svc_url "${hw}/igd" "${1}")
    [ -n "${t_url}" ] || return 6
    soap noauth "${t_url}" "${1}" "${2}" ''
}

# parse_desc FILE - "serviceType controlURL" per service of a device
# description; only well-formed URLs are kept.
parse_desc() {
    tr '\n' ' ' <"${1}" | tr '<' '\n' | awk '
        index($0, "serviceType>") == 1 { t = substr($0, 13); gsub(/[ \t]/, "", t) }
        index($0, "controlURL>") == 1 { u = substr($0, 12); gsub(/[ \t]/, "", u) }
        index($0, "/service>") == 1 {
            if (t ~ /^urn:[A-Za-z0-9.:_-]+$/ && u ~ /^\/[A-Za-z0-9_\/.-]+$/ && !seen[t]++) print t, u
            t = ""; u = ""
        }'
}

# load_igd - read /igddesc.xml once per host. Missing or disabled UPnP
# status information just leaves the IGD service list empty.
load_igd() {
    [ "${igd_loaded}" = 0 ] || return 0
    igd_loaded=1
    : >"${hw}/igd"
    [ "${host_abort}" = 0 ] || return 0
    fetch /igddesc.xml
    case "${?}" in
        0) parse_desc "${hw}/resp" >"${hw}/igd" ;;
        1) host_abort=1 ;;
        5) host_abort=5 ;;
        *) log debug "${host}: /igddesc.xml not available (HTTP ${HTTPCODE:-none})" ;;
    esac
}

# soap_problem RC SERVICE ACTION - human-readable reason for RC.
soap_problem() {
    case "${1}" in
        1) printf 'cannot reach TR-064 at %s - %s' "${base_url}" "${CURLERR:-connection failed}" ;;
        2) printf 'TR-064 authentication failed (HTTP %s%s) - check user and password for %s' \
               "${HTTPCODE}" "${ERRCODE:+, UPnP error ${ERRCODE}}" "${host}" ;;
        5) printf '%s' 'run time budget exhausted before the next request' ;;
        *) printf '%s %s failed (HTTP %s%s)' "${2##*:service:}" "${3}" \
               "${HTTPCODE:-none}" "${ERRCODE:+, UPnP error ${ERRCODE}}" ;;
    esac
}

# ----------------------------------------------------------------------
# Column assembly. A module calls col_begin, adds notes, detail lines and
# metrics, and ends with col_end; the delivery step reads the result.
# ----------------------------------------------------------------------

# col_begin COLUMN TITLE - start collecting one column.
col_begin() {
    col=${1} col_title=${2}
    cdir="${hw}/col.${col}"
    mkdir -p "${cdir}" || fail 'Cannot create the per-column work directory'
    : >"${cdir}/notes"; : >"${cdir}/details"; : >"${cdir}/metrics"
    color=green summary='' partial=0
    printf '%s\n' "${col}" >>"${hw}/columns"
}

# note COLOR TEXT - a colored line above the details; raises the color.
note() {
    color=$(worst "${color}" "${1}")
    printf '&%s %s\n' "${1}" "${2}" >>"${cdir}/notes"
}

# plain TEXT - an uncolored line above the details.
plain() {
    printf '%s\n' "${1}" >>"${cdir}/notes"
}

# finding COLOR TEXT - a finding whose color is a setting: "green" makes
# it a plain note that leaves the column color alone.
finding() {
    if [ "${1}" = green ]; then plain "Note: ${2}"; else note "${1}" "${2}"; fi
}

# detail FORMAT [ARG...] - one detail line (printf format).
detail() {
    # shellcheck disable=SC2059 # The format is always a literal of this script.
    printf "$@" >>"${cdir}/details"
}

# metric NAME VALUE [GAUGE|DERIVE] - one RRD value (U = unknown).
metric() {
    m_val=${2}
    is_num "${m_val}" || m_val=U
    printf '%s %s %s\n' "${1}" "${m_val}" "${3:-GAUGE}" >>"${cdir}/metrics"
}

# col_clear SUMMARY TEXT - nothing to monitor here (missing service).
col_clear() {
    [ "${color}" != green ] || color=clear
    summary=${1}
    plain "${2}"
}

# fail_call RC SERVICE ACTION - a failed request inside a module: host
# level failures are reported by col_end, others become a yellow note.
fail_call() {
    partial=1
    case "${1}" in
        1|2|5) ;;
        6) note yellow "service ${2##*:service:} is not offered by this box" ;;
        *) note yellow "$(soap_problem "${1}" "${2}" "${3}")" ;;
    esac
}

# need URN ACTION [ARGXML] - tr64 that reports its own failure.
need() {
    tr64 "$@"
    n_rc=${?}
    [ "${n_rc}" = 0 ] && return 0
    fail_call "${n_rc}" "${1}" "${2}"
    return 1
}

# save_state NAME - stdin becomes STATE_DIR/HOST.NAME after a successful
# delivery (never in a dry run).
save_state() {
    cat >"${cdir}/save.${1}" || fail 'Cannot write the column state'
}

# state_file NAME - path of the saved state NAME of this host.
state_file() {
    printf '%s/%s.%s' "${FRITZBOX_STATE_DIR}" "${host}" "${1}"
}

# col_end - finish the column: a host level failure (unreachable, login
# refused, budget) is added here, with the column marked as partial.
col_end() {
    case "${host_abort}" in
        1) note red "$(soap_problem 1)"; summary='unreachable'; partial=1 ;;
        2) note yellow "$(soap_problem 2)"; summary='authentication failed'; partial=1 ;;
        5) note yellow "$(soap_problem 5)"; [ -n "${summary}" ] || summary='run time budget exhausted'; partial=1 ;;
    esac
    [ -n "${summary}" ] || summary=${color}
    printf '%s\n%s\n%s\n%s\n' "${color}" "${partial}" "${col_title}" "${summary}" >"${cdir}/meta"
}

# hold_add COLOR TEXT - print a hold line "hold UNTIL COLOR TEXT" that
# keeps a finding for FRITZBOX_HOLD_MINUTES (callers append it).
hold_add() {
    printf 'hold %s %s %s\n' "$((now + hold_seconds))" "${1}" "${2}"
}

# holds_active FILE - print the still active "hold" lines of FILE.
holds_active() {
    [ -r "${1}" ] || return 0
    awk -v now="${now}" '$1 == "hold" && $2 + 0 > now + 0' "${1}"
}

# holds_note LINES - turn hold lines into notes with the time left.
holds_note() {
    printf '%s\n' "${1}" | while read -r h_kw h_until h_color h_text; do
        [ "${h_kw}" = hold ] || continue
        printf '%s %s (%d min left)\n' "${h_color}" "${h_text}" "$(((h_until - now + 59) / 60))"
    done >"${cdir}/holdnotes"
    while read -r h_color h_text; do
        finding "${h_color}" "${h_text}"
    done <"${cdir}/holdnotes"
}

# ----------------------------------------------------------------------
# Module dsl -> fritzdsl: WANDSLInterfaceConfig, plus the WAN uptime.
# Same RRD names and DS types as the former NCV extension, so the graph
# history continues.
# ----------------------------------------------------------------------
mod_dsl() {
    col_begin fritzdsl 'DSL line'
    d_svc=urn:dslforum-org:service:WANDSLInterfaceConfig:1
    if ! has_service "${d_svc}"; then
        col_clear 'no DSL interface' 'no WANDSLInterfaceConfig service in the TR-064 description - not a DSL box'
        col_end; return
    fi
    if ! need "${d_svc}" GetInfo; then
        [ "${host_abort}" != 0 ] || summary='TR-064 error'
        col_end; return
    fi
    d_status=$(field NewStatus | tr -cd 'A-Za-z0-9_-')
    if [ -z "${d_status}" ]; then
        note red 'the box returned an unexpected GetInfo response (no NewStatus field)'
        summary='unexpected response'; partial=1
        col_end; return
    fi
    d_path=$(field NewDataPath | tr -cd 'A-Za-z0-9_ -')
    d_rate_down=$(field NewDownstreamCurrRate); d_rate_up=$(field NewUpstreamCurrRate)
    d_max_down=$(field NewDownstreamMaxRate); d_max_up=$(field NewUpstreamMaxRate)
    # dB values are reported in tenths of a dB
    d_margin_down=$(db10 "$(field NewDownstreamNoiseMargin)")
    d_margin_up=$(db10 "$(field NewUpstreamNoiseMargin)")
    d_atten_down=$(db10 "$(field NewDownstreamAttenuation)")
    d_atten_up=$(db10 "$(field NewUpstreamAttenuation)")
    d_linecolor=green
    if [ "${d_status}" != Up ]; then
        d_linecolor=red
        note red "DSL line status: ${d_status}"
    else
        for d_dir in downstream upstream; do
            if [ "${d_dir}" = downstream ]; then d_m=${d_margin_down}; else d_m=${d_margin_up}; fi
            [ -n "${d_m}" ] || continue
            if [ "${FRITZBOX_DSL_MARGIN_CRIT}" != 0 ] && fbelow "${d_m}" "${FRITZBOX_DSL_MARGIN_CRIT}"; then
                note red "${d_dir} noise margin ${d_m} dB is below ${FRITZBOX_DSL_MARGIN_CRIT} dB"
            elif [ "${FRITZBOX_DSL_MARGIN_WARN}" != 0 ] && fbelow "${d_m}" "${FRITZBOX_DSL_MARGIN_WARN}"; then
                note yellow "${d_dir} noise margin ${d_m} dB is below ${FRITZBOX_DSL_MARGIN_WARN} dB"
            fi
        done
    fi
    metric rate_down "${d_rate_down}"; metric rate_up "${d_rate_up}"
    metric maxrate_down "${d_max_down}"; metric maxrate_up "${d_max_up}"
    metric margin_down "${d_margin_down}"; metric margin_up "${d_margin_up}"
    metric atten_down "${d_atten_down}"; metric atten_up "${d_atten_up}"

    # Error counters, cumulative since the last resync; DERIVE on the
    # server graphs them as rates. ATU-C = the far end (DSLAM side).
    d_crc='' d_fec='' d_hec='' d_es='' d_ses='' d_retrain='' d_fcrc='' d_ffec='' d_fhec=''
    if need "${d_svc}" GetStatisticsTotal; then
        d_crc=$(field NewCRCErrors); d_fec=$(field NewFECErrors); d_hec=$(field NewHECErrors)
        d_es=$(field NewErroredSecs); d_ses=$(field NewSeverelyErroredSecs)
        d_retrain=$(field NewLinkRetrain)
        d_fcrc=$(field NewATUCCRCErrors); d_ffec=$(field NewATUCFECErrors); d_fhec=$(field NewATUCHECErrors)
    fi
    metric crc "${d_crc}" DERIVE; metric fec "${d_fec}" DERIVE; metric hec "${d_hec}" DERIVE
    metric es "${d_es}" DERIVE; metric ses "${d_ses}" DERIVE; metric retrain "${d_retrain}" DERIVE
    metric atuc_crc "${d_fcrc}" DERIVE; metric atuc_fec "${d_ffec}" DERIVE; metric atuc_hec "${d_fhec}" DERIVE

    # Profile and modulation: text only, from the AVM extension.
    d_profile='' d_mod=''
    if [ "${host_abort}" = 0 ] && tr64 "${d_svc}" X_AVM-DE_GetDSLInfo; then
        d_profile=$(field NewCurrentProfile | tr -cd 'A-Za-z0-9_.-')
        d_mod=$(field NewModulationType | tr -cd 'A-Za-z0-9_.+ -')
    fi

    # WAN connection uptime (PPP or IP client mode)
    d_uptime='' d_conn=''
    case "${FRITZBOX_DSL_WAN_SERVICE}" in
        off) d_list='' ;;
        ppp) d_list='urn:dslforum-org:service:WANPPPConnection:1' ;;
        ip)  d_list='urn:dslforum-org:service:WANIPConnection:1' ;;
        *)   d_list='urn:dslforum-org:service:WANPPPConnection:1 urn:dslforum-org:service:WANIPConnection:1' ;;
    esac
    for d_wan in ${d_list}; do
        [ "${host_abort}" = 0 ] || break
        tr64 "${d_wan}" GetStatusInfo || continue
        d_u=$(field NewUptime)
        is_uint "${d_u}" || continue
        d_c=$(field NewConnectionStatus | tr -cd 'A-Za-z0-9_-')
        # A PPP service that is configured but unused reports 0 seconds
        # while the IP service carries the connection: prefer Connected.
        if [ "${d_c}" = Connected ] || [ -z "${d_uptime}" ]; then d_uptime=${d_u}; d_conn=${d_c}; fi
        [ "${d_c}" != Connected ] || break
    done
    if [ -n "${d_conn}" ] && [ "${d_conn}" != Connected ]; then
        note yellow "WAN connection status: ${d_conn}"
    fi
    metric uptime "${d_uptime}"

    # CRC rate and reconnect detection via the previous run's state.
    d_state=$(state_file dsl)
    d_pt='' d_pcrc='' d_pup=''
    [ ! -r "${d_state}" ] || read -r d_pt d_pcrc d_pup <"${d_state}" || :
    d_rate=''
    if is_uint "${d_crc}" && is_uint "${d_pt}" && is_uint "${d_pcrc}" \
        && [ "${now}" -gt "${d_pt}" ] && [ $((now - d_pt)) -ge 60 ] && [ "${d_crc}" -ge "${d_pcrc}" ]; then
        d_rate=$(awk -v d="$((d_crc - d_pcrc))" -v s="$((now - d_pt))" 'BEGIN { printf "%.1f", d * 60 / s }')
        if [ "${FRITZBOX_DSL_CRC_CRIT}" != 0 ] && ! fbelow "${d_rate}" "${FRITZBOX_DSL_CRC_CRIT}"; then
            note red "CRC errors: ${d_rate}/min since the last poll (limit ${FRITZBOX_DSL_CRC_CRIT}/min)"
        elif [ "${FRITZBOX_DSL_CRC_WARN}" != 0 ] && ! fbelow "${d_rate}" "${FRITZBOX_DSL_CRC_WARN}"; then
            note yellow "CRC errors: ${d_rate}/min since the last poll (limit ${FRITZBOX_DSL_CRC_WARN}/min)"
        fi
    fi
    if is_uint "${d_uptime}" && is_uint "${d_pup}" && [ "${d_uptime}" -lt "${d_pup}" ]; then
        plain 'Note: the connection was re-established since the last poll'
    fi
    # Unknown counters must invalidate the baseline: storing zero here
    # turns the next successful poll into a false CRC-rate alarm.
    printf '%s %s %s\n' "${now}" "${d_crc:-U}" "${d_uptime:-U}" | save_state dsl

    if [ "${d_status}" = Up ] && is_uint "${d_rate_down}" && is_uint "${d_rate_up}"; then
        summary="Up at ${d_rate_down}/${d_rate_up} kbit/s"
    else
        summary=${d_status}
    fi
    [ -s "${cdir}/notes" ] || plain 'DSL line is healthy'
    detail '&%s DSL line status: %s%s\n\n' "${d_linecolor}" "${d_status}" "${d_path:+ (path: ${d_path})}"
    [ -z "${d_mod}${d_profile}" ] || detail '    modulation       %s%s\n' "${d_mod:-?}" "${d_profile:+, profile ${d_profile}}"
    [ -z "${d_rate_down}${d_rate_up}" ] || detail '    sync rate        down=%s up=%s kbit/s\n' "${d_rate_down:-?}" "${d_rate_up:-?}"
    [ -z "${d_max_down}${d_max_up}" ] || detail '    attainable rate  down=%s up=%s kbit/s\n' "${d_max_down:-?}" "${d_max_up:-?}"
    [ -z "${d_margin_down}${d_margin_up}" ] || detail '    noise margin     down=%s up=%s dB\n' "${d_margin_down:-?}" "${d_margin_up:-?}"
    [ -z "${d_atten_down}${d_atten_up}" ] || detail '    attenuation      down=%s up=%s dB\n' "${d_atten_down:-?}" "${d_atten_up:-?}"
    [ -z "${d_crc}${d_fec}${d_hec}" ] || detail '    errors (total)   crc=%s%s fec=%s hec=%s es=%s ses=%s retrains=%s\n' \
        "${d_crc:-?}" "${d_rate:+ (${d_rate}/min)}" "${d_fec:-?}" "${d_hec:-?}" "${d_es:-?}" "${d_ses:-?}" "${d_retrain:-?}"
    [ -z "${d_fcrc}${d_ffec}${d_fhec}" ] || detail '    far end (ATU-C)  crc=%s fec=%s hec=%s\n' "${d_fcrc:-?}" "${d_ffec:-?}" "${d_fhec:-?}"
    ! is_uint "${d_uptime}" || detail '    connection       %s, up %s\n' "${d_conn:-?}" "$(fmt_duration "${d_uptime}")"
    col_end
}

# ----------------------------------------------------------------------
# Module wan -> fritzwan: link state, throughput, utilization.
# ----------------------------------------------------------------------

# counter_delta CURRENT PREVIOUS WIDTH - CURRENT - PREVIOUS. A negative
# delta of a 32-bit counter is a wrap only when the previous value was
# in the upper half of the range; anything else still negative (a reset
# after a reboot) fails, so the caller skips this round.
counter_delta() {
    awk -v c="${1}" -v p="${2}" -v w="${3}" 'BEGIN {
        d = c - p
        if (d < 0 && w == 32 && p >= 2147483648) d += 4294967296
        if (d < 0) exit 1
        printf "%.0f", d
    }'
}

mod_wan() {
    col_begin fritzwan 'WAN'
    w_tsvc=urn:dslforum-org:service:WANCommonInterfaceConfig:1
    w_isvc=urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1
    w_src=''
    # Link properties: the IGD values are the capacity the box's own
    # online monitor uses as 100% (the TR-064 ones are the attainable
    # DSL rate), so IGD is preferred when available.
    if [ "${FRITZBOX_WAN_MODE}" != tr064 ] && has_igd "${w_isvc}" && igd "${w_isvc}" GetCommonLinkProperties; then
        w_src=UPnP
    elif [ "${host_abort}" = 0 ] && [ "${FRITZBOX_WAN_MODE}" != igd ] && has_service "${w_tsvc}" && tr64 "${w_tsvc}" GetCommonLinkProperties; then
        w_src=TR-064
    fi
    if [ -z "${w_src}" ]; then
        if [ "${host_abort}" = 0 ]; then
            if [ "${FRITZBOX_WAN_MODE}" = igd ] && ! has_igd "${w_isvc}"; then
                col_clear 'UPnP status info disabled' "UPnP status information is not available - enable 'Transmit status information over UPnP' under Home Network > Network > Network Settings, or use FRITZBOX_WAN_MODE=auto"
            elif ! has_service "${w_tsvc}" && ! has_igd "${w_isvc}"; then
                col_clear 'no WAN service' 'no WANCommonInterfaceConfig service in the TR-064 or IGD description'
            else
                note red "GetCommonLinkProperties failed (HTTP ${HTTPCODE:-none}${ERRCODE:+, UPnP error ${ERRCODE}})"
                summary='TR-064 error'; partial=1
            fi
        fi
        col_end; return
    fi
    w_link=$(field NewPhysicalLinkStatus | tr -cd 'A-Za-z0-9_-')
    w_type=$(field NewWANAccessType | tr -cd 'A-Za-z0-9_-')
    w_max_down=$(field NewLayer1DownstreamMaxBitRate); w_max_up=$(field NewLayer1UpstreamMaxBitRate)
    if [ -z "${w_link}" ]; then
        note red 'the box returned an unexpected response (no NewPhysicalLinkStatus field)'
        summary='unexpected response'; partial=1
        col_end; return
    fi
    w_linkcolor=green
    if [ "${w_link}" != Up ]; then
        w_linkcolor=red
        note red "WAN link status: ${w_link}"
    fi
    metric maxbps_down "${w_max_down}"; metric maxbps_up "${w_max_up}"

    # Counters: IGD with AVM's 64-bit values first, else TR-064, whose
    # width is detected - FRITZ!OS 8 returns 64-bit values there too.
    w_rx='' w_tx='' w_width='' w_cnt=''
    if [ "${FRITZBOX_WAN_MODE}" != tr064 ] && has_igd "${w_isvc}" && igd "${w_isvc}" GetAddonInfos; then
        w_a=$(field NewX_AVM_DE_TotalBytesReceived64); w_b=$(field NewX_AVM_DE_TotalBytesSent64)
        if is_uint "${w_a}" && is_uint "${w_b}"; then
            w_rx=${w_a} w_tx=${w_b} w_width=64 w_cnt='UPnP 64-bit'
        else
            w_a=$(field NewTotalBytesReceived); w_b=$(field NewTotalBytesSent)
            if is_uint "${w_a}" && is_uint "${w_b}"; then w_rx=${w_a} w_tx=${w_b} w_width=32 w_cnt='UPnP 32-bit'; fi
        fi
    fi
    if [ -z "${w_rx}" ] && [ "${host_abort}" = 0 ] && [ "${FRITZBOX_WAN_MODE}" != igd ] && has_service "${w_tsvc}"; then
        if tr64 "${w_tsvc}" GetTotalBytesReceived; then
            w_a=$(field NewTotalBytesReceived)
            if tr64 "${w_tsvc}" GetTotalBytesSent; then
                w_b=$(field NewTotalBytesSent)
                if is_uint "${w_a}" && is_uint "${w_b}"; then
                    w_rx=${w_a} w_tx=${w_b} w_width=32
                    if [ "${#w_a}" -gt 10 ] || [ "${#w_b}" -gt 10 ] || [ "${w_a}" -gt 4294967295 ] || [ "${w_b}" -gt 4294967295 ]; then w_width=64; fi
                    w_cnt="TR-064 ${w_width}-bit"
                fi
            fi
        fi
    fi
    if [ -z "${w_rx}" ]; then
        [ "${host_abort}" != 0 ] || plain '&clear traffic counters unavailable - enable UPnP status information (Home Network > Network > Network Settings) for 64-bit counters'
    fi

    # Throughput as average rate since the previous poll.
    w_state=$(state_file wan)
    w_pt='' w_prx='' w_ptx='' w_pw=''
    [ ! -r "${w_state}" ] || read -r w_pt w_prx w_ptx w_pw <"${w_state}" || :
    w_bps_down='' w_bps_up=''
    if [ -n "${w_rx}" ] && is_uint "${w_pt}" && is_uint "${w_prx}" && is_uint "${w_ptx}" \
        && [ "${w_pw}" = "${w_width}" ] && [ "${now}" -gt "${w_pt}" ] && [ $((now - w_pt)) -ge 60 ]; then
        if w_drx=$(counter_delta "${w_rx}" "${w_prx}" "${w_width}") && w_dtx=$(counter_delta "${w_tx}" "${w_ptx}" "${w_width}"); then
            w_bps_down=$(awk -v d="${w_drx}" -v s="$((now - w_pt))" 'BEGIN { printf "%.0f", d * 8 / s }')
            w_bps_up=$(awk -v d="${w_dtx}" -v s="$((now - w_pt))" 'BEGIN { printf "%.0f", d * 8 / s }')
        fi
    fi
    [ -z "${w_rx}" ] || printf '%s %s %s %s\n' "${now}" "${w_rx}" "${w_tx}" "${w_width}" | save_state wan

    w_util_down='' w_util_up=''
    if is_uint "${w_bps_down}" && is_uint "${w_max_down}" && [ "${w_max_down}" -gt 0 ]; then
        w_util_down=$(awk -v b="${w_bps_down}" -v m="${w_max_down}" 'BEGIN { printf "%.1f", b * 100 / m }')
    fi
    if is_uint "${w_bps_up}" && is_uint "${w_max_up}" && [ "${w_max_up}" -gt 0 ]; then
        w_util_up=$(awk -v b="${w_bps_up}" -v m="${w_max_up}" 'BEGIN { printf "%.1f", b * 100 / m }')
    fi
    for w_dir in downstream upstream; do
        if [ "${w_dir}" = downstream ]; then w_u=${w_util_down}; else w_u=${w_util_up}; fi
        [ -n "${w_u}" ] || continue
        if [ "${FRITZBOX_WAN_UTIL_CRIT}" != 0 ] && ! fbelow "${w_u}" "${FRITZBOX_WAN_UTIL_CRIT}"; then
            note red "${w_dir} utilization ${w_u}% is above ${FRITZBOX_WAN_UTIL_CRIT}%"
        elif [ "${FRITZBOX_WAN_UTIL_WARN}" != 0 ] && ! fbelow "${w_u}" "${FRITZBOX_WAN_UTIL_WARN}"; then
            note yellow "${w_dir} utilization ${w_u}% is above ${FRITZBOX_WAN_UTIL_WARN}%"
        fi
    done
    metric bps_down "${w_bps_down}"; metric bps_up "${w_bps_up}"
    metric util_down "${w_util_down}"; metric util_up "${w_util_up}"

    if [ "${w_link}" = Up ]; then
        if [ -n "${w_bps_down}" ]; then summary="Up, $(mbit "${w_bps_down}")/$(mbit "${w_bps_up}") Mbit/s (down/up)"
        else summary=Up; fi
    else
        summary=${w_link}
    fi
    [ -s "${cdir}/notes" ] || plain 'WAN link is healthy'
    detail '&%s WAN link status: %s%s\n\n' "${w_linkcolor}" "${w_link}" "${w_type:+ (${w_type})}"
    if [ -n "${w_bps_down}" ]; then
        detail '    throughput       down=%s up=%s Mbit/s (average since the last poll)\n' "$(mbit "${w_bps_down}")" "$(mbit "${w_bps_up}")"
    elif [ -n "${w_rx}" ]; then
        detail '    throughput       not yet available (rates appear with the next poll)\n'
    fi
    if is_uint "${w_max_down}" && is_uint "${w_max_up}"; then
        detail '    link capacity    down=%s up=%s Mbit/s [%s]\n' "$(mbit "${w_max_down}")" "$(mbit "${w_max_up}")" "${w_src}"
    fi
    [ -z "${w_util_down}${w_util_up}" ] || detail '    utilization      down=%s%% up=%s%%\n' "${w_util_down:-?}" "${w_util_up:-?}"
    [ -z "${w_rx}" ] || detail '    traffic total    received=%s GiB sent=%s GiB [%s counters]\n' "$(gib "${w_rx}")" "$(gib "${w_tx}")" "${w_cnt}"
    col_end
}

# ----------------------------------------------------------------------
# Module sys -> fritzsys: model, firmware, updates, uptime, clock.
# ----------------------------------------------------------------------

# iso_epoch ISO8601 - epoch seconds of "YYYY-MM-DDThh:mm:ss[+-]hh:mm"
# (or "Z"), without date -d: days_from_civil() after H. Hinnant.
iso_epoch() {
    printf '%s\n' "${1}" | awk '
        /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ {
            y = substr($0, 1, 4) + 0; m = substr($0, 6, 2) + 0; d = substr($0, 9, 2) + 0
            hh = substr($0, 12, 2) + 0; mi = substr($0, 15, 2) + 0; ss = substr($0, 18, 2) + 0
            tz = substr($0, 20); off = 0
            if (tz ~ /^[+-][0-9][0-9]:[0-9][0-9]$/) {
                off = substr(tz, 2, 2) * 3600 + substr(tz, 5, 2) * 60
                if (substr(tz, 1, 1) == "-") off = -off
            } else if (tz != "" && tz != "Z") exit 1
            if (m <= 2) y--
            era = int(y / 400); yoe = y - era * 400
            mp = (m > 2) ? m - 3 : m + 9
            doy = int((153 * mp + 2) / 5) + d - 1
            doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
            days = era * 146097 + doe - 719468
            printf "%d\n", days * 86400 + hh * 3600 + mi * 60 + ss - off
            ok = 1
        }
        END { exit !ok }'
}

mod_sys() {
    col_begin fritzsys 'System'
    y_svc=urn:dslforum-org:service:DeviceInfo:1
    if ! need "${y_svc}" GetInfo; then
        [ "${host_abort}" != 0 ] || summary='TR-064 error'
        col_end; return
    fi
    y_model=$(clean "$(field NewModelName)")
    y_fw=$(clean "$(field NewSoftwareVersion)")
    y_up=$(field NewUpTime)
    is_uint "${y_up}" || y_up=''
    if [ -n "${y_up}" ] && [ "${y_up}" -lt "${hold_seconds}" ]; then
        note yellow "the box restarted $((y_up / 60)) minute(s) ago"
    fi
    metric uptime "${y_up}"

    # Firmware updates: "available" from GetInfo, the last result from
    # the AVM extension. A failed attempt may stay "failed" until the
    # next success, so it only colors when configured to.
    y_avail='' y_new='' y_state='' y_mode='' y_last='' y_result='' y_when=''
    y_ui=urn:dslforum-org:service:UserInterface:1
    if has_service "${y_ui}"; then
        if need "${y_ui}" GetInfo; then
            y_avail=$(field NewUpgradeAvailable)
            y_new=$(clean "$(field NewX_AVM-DE_Version)")
            y_state=$(clean "$(field NewX_AVM-DE_UpdateState)")
        fi
        if [ "${host_abort}" = 0 ] && tr64 "${y_ui}" X_AVM-DE_GetInfo; then
            y_mode=$(clean "$(field NewX_AVM-DE_AutoUpdateMode)")
            y_last=$(clean "$(field NewX_AVM-DE_LastFwVersion)")
            y_result=$(clean "$(field NewX_AVM-DE_UpdateSuccessful)")
            y_when=$(clean "$(field NewX_AVM-DE_UpdateTime)")
        fi
    fi
    if [ "${y_avail}" = 1 ]; then
        finding "${FRITZBOX_SYS_UPDATE_COLOR}" "FRITZ!OS update available${y_new:+: ${y_new}}"
    fi
    if [ "${y_result}" = failed ]; then
        finding "${FRITZBOX_SYS_UPDATE_FAILED_COLOR}" "the last FRITZ!OS update failed${y_when:+ (${y_when})}"
    fi

    # Clock offset: box time against this server's clock at the reply.
    y_offset='' y_ntp1='' y_ntp2='' y_time=''
    y_tsvc=urn:dslforum-org:service:Time:1
    if [ "${host_abort}" = 0 ] && has_service "${y_tsvc}" && need "${y_tsvc}" GetInfo; then
        y_ref=$(now_s)
        y_time=$(field NewCurrentLocalTime | tr -cd '0-9T:+Z-')
        y_ntp1=$(clean "$(field NewNTPServer1)"); y_ntp2=$(clean "$(field NewNTPServer2)")
        if y_box=$(iso_epoch "${y_time}"); then
            y_offset=$((y_box - y_ref))
            y_abs=${y_offset#-}
            if [ "${y_abs}" -gt "${FRITZBOX_SYS_CLOCK_CRIT}" ]; then
                note red "box clock is off by ${y_offset} s (limit ${FRITZBOX_SYS_CLOCK_CRIT} s)"
            elif [ "${y_abs}" -gt "${FRITZBOX_SYS_CLOCK_WARN}" ]; then
                note yellow "box clock is off by ${y_offset} s (limit ${FRITZBOX_SYS_CLOCK_WARN} s)"
            fi
        else
            note yellow "cannot parse the box time '${y_time}'"
        fi
    fi
    metric clock_offset "${y_offset}"

    # SoftwareVersion is HW.MAJOR.MINOR (271.08.26 = FRITZ!OS 8.26).
    y_os=$(printf '%s' "${y_fw}" | awk -F. 'NF == 3 && $0 ~ /^[0-9.]+$/ { printf "%d.%s", $2, $3 }')
    summary="${y_model:-FRITZ!Box}, FRITZ!OS ${y_os:-${y_fw:-?}}${y_up:+, up $(fmt_duration "${y_up}")}"
    [ -s "${cdir}/notes" ] || plain 'System is healthy'
    detail '    model            %s\n' "${y_model:-?}"
    detail '    firmware         %s%s\n' "${y_fw:-?}" "${y_last:+ (previous ${y_last})}"
    [ -z "${y_avail}${y_mode}" ] || detail '    updates          available=%s state=%s auto=%s last=%s%s\n' \
        "${y_avail:-?}" "${y_state:-?}" "${y_mode:-?}" "${y_result:-?}" "${y_when:+ ${y_when}}"
    [ -z "${y_up}" ] || detail '    uptime           %s\n' "$(fmt_duration "${y_up}")"
    [ -z "${y_time}" ] || detail '    box time         %s (offset %s s)\n' "${y_time}" "${y_offset:-?}"
    [ -z "${y_ntp1}${y_ntp2}" ] || detail '    NTP servers      %s %s\n' "${y_ntp1}" "${y_ntp2}"
    col_end
}

# ----------------------------------------------------------------------
# Module log -> fritzlog: new event log entries since the last poll,
# classified by the rules file. Unmatched entries are yellow on purpose:
# Xymon records the status change, and a rule can be added later.
# ----------------------------------------------------------------------

# log_entries FILE - the NewDeviceLog text of a response as lines
# "KEY|dd.mm.yy hh:mm:ss|message", newest first as the box sends them.
# KEY (yymmddhhmmss) sorts chronologically. Entries are found by their
# time stamps, so line breaks or blanks between them do not matter.
log_entries() {
    awk '
        { buf = buf " " $0 }
        END {
            b = index(buf, "<NewDeviceLog>"); e = index(buf, "</NewDeviceLog>")
            if (!b || e <= b) exit
            s = substr(buf, b + 14, e - b - 14)
            gsub(/[\r\t]/, " ", s)
            re = "[0-9][0-9]\\.[0-9][0-9]\\.[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]"
            n = 0
            while (match(s, re)) {
                if (n) msg[n] = msg[n] substr(s, 1, RSTART - 1)
                n++; ts[n] = substr(s, RSTART, RLENGTH); msg[n] = ""
                s = substr(s, RSTART + RLENGTH)
            }
            if (n) msg[n] = msg[n] s
            for (i = 1; i <= n; i++) {
                t = msg[i]; gsub(/  +/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t)
                k = substr(ts[i], 7, 2) substr(ts[i], 4, 2) substr(ts[i], 1, 2) \
                    substr(ts[i], 10, 2) substr(ts[i], 13, 2) substr(ts[i], 16, 2)
                print k "|" ts[i] "|" t
            }
        }' "${1}"
}

mod_log() {
    col_begin fritzlog 'Event log'
    l_svc=urn:dslforum-org:service:DeviceInfo:1
    if ! need "${l_svc}" GetDeviceLog; then
        [ "${host_abort}" != 0 ] || summary='TR-064 error'
        col_end; return
    fi
    log_entries "${hw}/resp" >"${cdir}/entries" || fail 'Cannot parse the event log'

    # Rules: "category color ERE", first match wins. Bad lines are
    # skipped with a warning that names the line number.
    : >"${cdir}/rules"
    if [ -r "${FRITZBOX_LOG_RULES}" ]; then
        awk '
            { sub(/\r$/, "") }
            /^[ \t]*$/ || /^[ \t]*#/ { next }
            {
                line = $0; sub(/^[ \t]+/, "", line)
                c = line; sub(/[ \t].*$/, "", c)
                rest = substr(line, length(c) + 1); sub(/^[ \t]+/, "", rest)
                k = rest; sub(/[ \t].*$/, "", k)
                re = substr(rest, length(k) + 1); sub(/^[ \t]+/, "", re); sub(/[ \t]+$/, "", re)
                if (c !~ /^[a-z0-9_]+$/ || length(c) > 16 || c == "unmatched" || k !~ /^(green|yellow|red)$/ || re == "") {
                    print "line " NR > "/dev/stderr"; next
                }
                print c, k, re
            }' "${FRITZBOX_LOG_RULES}" >"${cdir}/rules" 2>"${cdir}/rules.bad" || :
        while read -r l_bad; do
            log warning "${FRITZBOX_LOG_RULES} ${l_bad}: expected category (a-z0-9_), color and pattern - ignored"
        done <"${cdir}/rules.bad"
    else
        note yellow "rules file ${FRITZBOX_LOG_RULES} is not readable - every entry counts as unmatched"
    fi

    # New entries: newer than the newest key seen last time, or at that
    # key beyond the number of entries already seen there. The first
    # poll (no state) is the baseline: nothing is new.
    l_state=$(state_file log)
    l_lastkey='' l_lastcount=''
    if [ -r "${l_state}" ]; then
        read -r l_kw l_lastkey l_lastcount <"${l_state}" || :
        [ "${l_kw:-}" = last ] || l_lastkey=''
    fi
    l_newest=$(awk -F'|' 'NR == 1 { print $1 }' "${cdir}/entries")
    l_mode=normal
    if [ -z "${l_lastkey}" ]; then
        l_mode=baseline
    elif [ -n "${l_newest}" ] && [ "${l_newest}" -lt "${l_lastkey}" ]; then
        l_mode=reset
    fi
    awk -F'|' -v rules="${cdir}/rules" -v last="${l_lastkey:-0}" -v cnt="${l_lastcount:-0}" \
        -v mode="${l_mode}" -v unc="${FRITZBOX_LOG_UNMATCHED_COLOR}" '
        BEGIN {
            while ((getline line < rules) > 0) {
                n++; rc[n] = line; sub(/ .*/, "", rc[n])
                rest = substr(line, length(rc[n]) + 2)
                rk[n] = rest; sub(/ .*/, "", rk[n]); rr[n] = substr(rest, length(rk[n]) + 2)
            }
        }
        {
            if ($1 == last) atlast++
            new = 0
            if (mode == "normal") new = ($1 > last) || ($1 == last && atlast > cnt)
            # A message may contain "|": everything after the stamp is it.
            m = $0; sub(/^[^|]*\|[^|]*\|/, "", m)
            c = "unmatched"; k = unc
            for (i = 1; i <= n; i++) if (m ~ rr[i]) { c = rc[i]; k = rk[i]; break }
            print (new ? "new" : "old"), c, k, $2 "|" m
        }' "${cdir}/entries" >"${cdir}/classified" || fail 'Cannot classify the event log'
    l_count=$(awk -F'|' -v k="${l_newest}" '$1 == k { n++ } END { print n + 0 }' "${cdir}/entries")
    l_total=$(awk 'END { print NR }' "${cdir}/entries")
    l_new=$(awk '$1 == "new" { n++ } END { print n + 0 }' "${cdir}/classified")

    # Holds: every new non-green entry keeps its color for HOLD_MINUTES.
    holds_active "${l_state}" >"${cdir}/holds"
    awk '$1 == "new" && $3 != "green"' "${cdir}/classified" | while read -r l_n l_c l_k l_rest; do
        hold_add "${l_k}" "$(clean "$(mask "${l_rest%%|*} [${l_c}] ${l_rest#*|}")" 300)"
    done >>"${cdir}/holds"
    # Newest holds first, at most 50.
    awk '{ l[NR] = $0 } END { for (i = NR; i > 0 && i > NR - 50; i--) print l[i] }' "${cdir}/holds" >"${cdir}/holds.keep"
    holds_note "$(cat "${cdir}/holds.keep")"
    {
        if [ -n "${l_newest}" ]; then printf 'last %s %s\n' "${l_newest}" "${l_count}"
        elif [ -n "${l_lastkey}" ]; then printf 'last %s %s\n' "${l_lastkey}" "${l_lastcount:-0}"
        fi
        cat "${cdir}/holds.keep"
    } | save_state log

    # Per category: the new entries of this poll (U on the baseline).
    { awk '{ print $1 }' "${cdir}/rules"; printf '%s\n' unmatched; } | awk '!seen[$0]++' | while read -r l_c; do
        if [ "${l_mode}" = normal ]; then
            metric "${l_c}" "$(awk -v c="${l_c}" '$1 == "new" && $2 == c { n++ } END { print n + 0 }' "${cdir}/classified")"
        else
            metric "${l_c}" U
        fi
    done

    case "${l_mode}" in
        baseline) plain "baseline: ${l_total} existing entries, new ones are reported from the next poll"
                  summary="baseline of ${l_total} entries" ;;
        reset)    plain 'the event log was reset (newest entry older than the last one seen) - new baseline'
                  summary="new baseline of ${l_total} entries" ;;
        *)        summary="${l_new} new entr$([ "${l_new}" = 1 ] && printf y || printf ies)" ;;
    esac
    [ "${l_total}" != 0 ] || summary='event log empty'
    [ -s "${cdir}/notes" ] || plain 'No events that need attention'
    detail 'Latest entries (newest first, %s of %s):\n' \
        "$([ "${l_total}" -lt "${FRITZBOX_LOG_SHOW}" ] && printf '%s' "${l_total}" || printf '%s' "${FRITZBOX_LOG_SHOW}")" "${l_total}"
    # Only new entries carry a color icon: an old yellow entry must not
    # look like a current problem in a green column.
    head -n "${FRITZBOX_LOG_SHOW}" "${cdir}/classified" | while read -r l_n l_c l_k l_rest; do
        if [ "${l_n}" = new ]; then l_mark="&${l_k}"; else l_mark='  -'; fi
        detail '  %s %s [%s]%s %s\n' "${l_mark}" "${l_rest%%|*}" "${l_c}" "$([ "${l_n}" = new ] && printf ' (new)')" \
            "$(clean "$(mask "${l_rest#*|}")" 300)"
    done
    col_end
}

# ----------------------------------------------------------------------
# Module fw -> fritzfw: what is reachable from the internet. IPv6
# pinholes are not visible over TR-064.
# ----------------------------------------------------------------------
mod_fw() {
    col_begin fritzfw 'Exposure'
    f_wan='' f_ddns4='' f_ddns6='' f_mfstate=''
    # The port mappings belong to the connection that carries traffic.
    for f_s in urn:dslforum-org:service:WANPPPConnection:1 urn:dslforum-org:service:WANIPConnection:1; do
        [ "${host_abort}" = 0 ] || break
        has_service "${f_s}" || continue
        [ -n "${f_wan}" ] || f_wan=${f_s}
        if tr64 "${f_s}" GetStatusInfo && [ "$(field NewConnectionStatus)" = Connected ]; then
            f_wan=${f_s}; break
        fi
    done
    : >"${cdir}/maps"
    f_count=''
    if [ -z "${f_wan}" ]; then
        [ "${host_abort}" != 0 ] || plain 'no WAN connection service - port mappings unknown'
    elif need "${f_wan}" GetPortMappingNumberOfEntries; then
        f_count=$(field NewPortMappingNumberOfEntries)
        if ! is_uint "${f_count}"; then
            note yellow 'the box returned no usable port mapping count'; partial=1; f_count=''
        fi
        f_i=0
        while [ "${f_i}" -lt "${f_count:-0}" ] && [ "${f_i}" -lt "${max_entries}" ]; do
            tr64 "${f_wan}" GetGenericPortMappingEntry "<NewPortMappingIndex>${f_i}</NewPortMappingIndex>"
            f_rc=${?}
            [ "${f_rc}" = 0 ] || { fail_call "${f_rc}" "${f_wan}" GetGenericPortMappingEntry; break; }
            f_proto=$(field NewProtocol | tr -cd 'A-Za-z')
            f_ext=$(field NewExternalPort | tr -cd '0-9')
            f_cli=$(field NewInternalClient | tr -cd '0-9A-Za-z.:-')
            f_int=$(field NewInternalPort | tr -cd '0-9')
            f_en=$(field NewEnabled | tr -cd '0-9')
            f_desc=$(clean "$(field NewPortMappingDescription)")
            printf '%s %s:%s:%s:%s %s\n' "${f_en:-1}" "${f_proto}" "${f_ext}" "${f_cli}" "${f_int}" "${f_desc}" >>"${cdir}/maps"
            f_i=$((f_i + 1))
        done
        # Only the cap gets this note: a failed request already has its
        # own (or col_end reports the unreachable box).
        if [ "${partial}" = 0 ] && [ "${host_abort}" = 0 ] && [ "${f_i}" -lt "${f_count:-0}" ]; then
            note yellow "port mapping list incomplete: read ${f_i} of ${f_count} entries (limit ${max_entries})"
            partial=1
        fi
    fi
    f_enabled=$(awk '$1 == "1"' "${cdir}/maps" | wc -l | tr -d ' ')

    # Settings that open the box: UPnP port changes by applications,
    # remote access to the user interface, MyFRITZ, DynDNS.
    f_settings=''
    f_s=urn:dslforum-org:service:X_AVM-DE_UPnP:1
    if [ "${host_abort}" = 0 ] && has_service "${f_s}" && tr64 "${f_s}" GetInfo; then
        f_settings="${f_settings} upnp=$(field NewEnable | tr -cd '0-9')"
    fi
    f_s=urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1
    if [ "${host_abort}" = 0 ] && has_igd "${f_s}" && igd "${f_s}" GetAddonInfos; then
        f_v=$(field NewUpnpControlEnabled | tr -cd '0-9')
        f_settings="${f_settings} upnp_portmapping=${f_v:-?}"
    fi
    f_s=urn:dslforum-org:service:X_AVM-DE_RemoteAccess:1
    if [ "${host_abort}" = 0 ] && has_service "${f_s}"; then
        if tr64 "${f_s}" GetInfo; then
            f_settings="${f_settings} remote_access=$(field NewEnabled | tr -cd '0-9')"
            f_settings="${f_settings} remote_port=$(field NewPort | tr -cd '0-9')"
            f_settings="${f_settings} letsencrypt=$(field NewLetsEncryptEnabled | tr -cd '0-9')"
        fi
        if [ "${host_abort}" = 0 ] && tr64 "${f_s}" GetDDNSInfo; then
            f_settings="${f_settings} dyndns=$(field NewEnabled | tr -cd '0-9')"
            f_ddns4=$(clean "$(field NewStatusIPv4)"); f_ddns6=$(clean "$(field NewStatusIPv6)")
        fi
    fi
    f_s=urn:dslforum-org:service:X_AVM-DE_MyFritz:1
    if [ "${host_abort}" = 0 ] && has_service "${f_s}" && tr64 "${f_s}" GetInfo; then
        f_settings="${f_settings} myfritz=$(field NewEnabled | tr -cd '0-9')"
        f_settings="${f_settings} myfritz_registered=$(field NewDeviceRegistered | tr -cd '0-9')"
        f_mfstate=$(clean "$(field NewState)")
    fi
    f_settings=${f_settings# }
    case " ${f_settings} " in *" upnp_portmapping=1 "*)
        plain 'Note: devices in the LAN may open ports themselves (UPnP "permit independent port sharing")' ;;
    esac

    # Compare: mappings against FRITZBOX_FW_EXPECTED when set, else and
    # for the settings against the last poll (first poll = baseline).
    f_state=$(state_file fw)
    holds_active "${f_state}" >"${cdir}/holds"
    f_maps=$(awk '$1 == "1" { print $2 }' "${cdir}/maps" | sort | tr '\n' ' ')
    f_maps=${f_maps% }
    f_prev_maps='' f_prev_set='' f_have_prev=0
    if [ -r "${f_state}" ]; then
        f_have_prev=1
        f_prev_maps=$(awk '$1 == "maps" { sub(/^maps ?/, ""); print; exit }' "${f_state}")
        f_prev_set=$(awk '$1 == "settings" { sub(/^settings ?/, ""); print; exit }' "${f_state}")
    fi
    if [ "${partial}" = 0 ] && [ "${host_abort}" = 0 ]; then
        if [ -n "${FRITZBOX_FW_EXPECTED}" ]; then
            for f_m in ${f_maps}; do
                case " ${FRITZBOX_FW_EXPECTED} " in *" ${f_m} "*) ;; *) finding "${FRITZBOX_FW_COLOR}" "port mapping ${f_m} is not in FRITZBOX_FW_EXPECTED" ;; esac
            done
            for f_m in ${FRITZBOX_FW_EXPECTED}; do
                case " ${f_maps} " in *" ${f_m} "*) ;; *) finding "${FRITZBOX_FW_COLOR}" "expected port mapping ${f_m} is missing" ;; esac
            done
        elif [ "${f_have_prev}" = 1 ] && [ "${f_maps}" != "${f_prev_maps}" ]; then
            hold_add "${FRITZBOX_FW_COLOR}" "port mappings changed: now '${f_maps:-none}', before '${f_prev_maps:-none}'" >>"${cdir}/holds"
        fi
        if [ "${f_have_prev}" = 1 ] && [ "${f_settings}" != "${f_prev_set}" ]; then
            hold_add "${FRITZBOX_FW_COLOR}" "exposure settings changed: now '${f_settings}', before '${f_prev_set}'" >>"${cdir}/holds"
        fi
        [ "${f_have_prev}" = 1 ] || plain 'baseline: changes are reported from the next poll'
        { printf 'maps %s\n' "${f_maps}"; printf 'settings %s\n' "${f_settings}"; cat "${cdir}/holds"; } | save_state fw
    elif [ -r "${f_state}" ]; then
        # Incomplete poll: keep the previous baseline unchanged.
        save_state fw <"${f_state}"
    fi
    holds_note "$(cat "${cdir}/holds")"
    if [ "${partial}" = 0 ] && [ "${host_abort}" = 0 ]; then
        metric portmaps "${f_count:+${f_enabled}}"
    else
        metric portmaps U
    fi

    if [ "${partial}" = 1 ]; then summary='port mapping list incomplete'
    else summary="${f_enabled} port mapping(s)"; fi
    case " ${f_settings} " in *" remote_access=1 "*) summary="${summary}, remote access on" ;; esac
    [ -s "${cdir}/notes" ] || plain 'No unexpected exposure'
    detail 'Port mappings (enabled, protocol:external port:client:internal port):\n'
    if [ -s "${cdir}/maps" ]; then
        while read -r f_en f_m f_desc; do
            detail '    %s %s %s\n' "$([ "${f_en}" = 1 ] && printf 'on ' || printf 'off')" "${f_m}" "${f_desc}"
        done <"${cdir}/maps"
    else
        detail '    none\n'
    fi
    detail '\nSettings: %s\n' "${f_settings:-unknown}"
    [ -z "${f_ddns4}${f_ddns6}" ] || detail 'DynDNS status: IPv4 %s, IPv6 %s\n' "${f_ddns4:-?}" "${f_ddns6:-?}"
    [ -z "${f_mfstate}" ] || detail 'MyFRITZ state: %s\n' "${f_mfstate}"
    detail 'IPv6 port sharing (pinholes) is not visible over TR-064.\n'
    col_end
}

# ----------------------------------------------------------------------
# Module lan -> fritzlan: LAN throughput and the host list (one GET of
# the box's session URL instead of one request per host).
# ----------------------------------------------------------------------
mod_lan() {
    col_begin fritzlan 'LAN'
    a_svc=urn:dslforum-org:service:LANEthernetInterfaceConfig:1
    a_status='' a_rx='' a_tx=''
    if has_service "${a_svc}"; then
        need "${a_svc}" GetInfo && a_status=$(field NewStatus | tr -cd 'A-Za-z0-9_-')
        if [ "${host_abort}" = 0 ] && need "${a_svc}" GetStatistics; then
            a_rx=$(field NewBytesReceived); a_tx=$(field NewBytesSent)
            if ! is_uint "${a_rx}" || ! is_uint "${a_tx}"; then a_rx='' a_tx=''; fi
        fi
    fi
    [ -z "${a_status}" ] || [ "${a_status}" = Up ] || note red "LAN interface status: ${a_status}"

    # The counters are 64-bit; a backwards step is a reset (reboot).
    a_state=$(state_file lan)
    a_pt='' a_prx='' a_ptx=''
    [ ! -r "${a_state}" ] || read -r a_pt a_prx a_ptx <"${a_state}" || :
    a_in='' a_out=''
    if [ -n "${a_rx}" ] && is_uint "${a_pt}" && is_uint "${a_prx}" && is_uint "${a_ptx}" \
        && [ "${now}" -gt "${a_pt}" ] && [ $((now - a_pt)) -ge 60 ]; then
        if a_d1=$(counter_delta "${a_rx}" "${a_prx}" 64) && a_d2=$(counter_delta "${a_tx}" "${a_ptx}" 64); then
            a_in=$(awk -v d="${a_d1}" -v s="$((now - a_pt))" 'BEGIN { printf "%.0f", d * 8 / s }')
            a_out=$(awk -v d="${a_d2}" -v s="$((now - a_pt))" 'BEGIN { printf "%.0f", d * 8 / s }')
        fi
    fi
    [ -z "${a_rx}" ] || printf '%s %s %s\n' "${now}" "${a_rx}" "${a_tx}" | save_state lan
    metric bps_in "${a_in}"; metric bps_out "${a_out}"

    # Hosts: the list path carries a session ID, valid for this request.
    h_svc=urn:dslforum-org:service:Hosts:1
    a_hosts=0
    : >"${cdir}/hosts"
    if [ "${host_abort}" = 0 ] && has_service "${h_svc}" && need "${h_svc}" X_AVM-DE_GetHostListPath; then
        a_path=$(field NewX_AVM-DE_HostListPath | sed 's/&amp;/\&/g')
        case "${a_path}" in
            /*) ;;
            *) a_path='' ;;
        esac
        case "${a_path}" in *[!A-Za-z0-9_./?=\&-]*) a_path='' ;; esac
        if [ -z "${a_path}" ]; then
            note yellow 'the box returned no usable host list path'; partial=1
        else
            fetch "${a_path}"
            a_rc=${?}
            case "${a_rc}" in
                0)  # "MAC active interface guest" per <Item>, MAC upper case.
                    tr '\n' ' ' <"${hw}/resp" | sed 's#<Item>#\n<Item>#g' | awk '
                        function val(n,   s) {
                            if (match($0, "<" n ">[^<]*</" n ">")) { s = substr($0, RSTART + length(n) + 2, RLENGTH - 2 * length(n) - 5); return s }
                            return ""
                        }
                        /^<Item>/ {
                            mac = toupper(val("MACAddress")); a = val("Active"); t = val("InterfaceType"); g = val("X_AVM-DE_Guest")
                            gsub(/[^A-Za-z0-9.]/, "", t)
                            if (mac !~ /^[0-9A-F][0-9A-F](:[0-9A-F][0-9A-F])+$/) mac = "-"
                            print mac, (a == "1" ? 1 : 0), (t == "" ? "-" : t), (g == "1" ? 1 : 0)
                        }' >"${cdir}/hosts"
                    a_hosts=1 ;;
                1) host_abort=1 ;;
                5) host_abort=5 ;;
                *) note yellow "host list download failed (HTTP ${HTTPCODE:-none})"; partial=1 ;;
            esac
        fi
    fi
    if [ "${a_hosts}" = 1 ]; then
        eval "$(awk '
            { total++ }
            $2 == 1 { act++; if ($3 == "Ethernet") e++; else if ($3 == "802.11") w++; else if ($3 == "HomePlug") p++; else o++; if ($4 == 1) g++ }
            END { printf "a_total=%d a_act=%d a_eth=%d a_wlan=%d a_plc=%d a_oth=%d a_guest=%d\n", total, act, e, w, p, o, g }' "${cdir}/hosts")"
    else
        a_total='' a_act='' a_eth='' a_wlan='' a_plc='' a_oth='' a_guest=''
    fi
    metric hosts_total "${a_total}"; metric hosts_active "${a_act}"
    metric active_eth "${a_eth}"; metric active_wlan "${a_wlan}"; metric active_plc "${a_plc}"
    metric active_other "${a_oth}"; metric guests_active "${a_guest}"

    # Required devices: "MAC" or "MAC=label", must be active.
    for a_req in ${FRITZBOX_LAN_REQUIRED}; do
        [ "${a_hosts}" = 1 ] || break
        a_mac=$(printf '%s' "${a_req%%=*}" | tr 'a-f-' 'A-F:')
        a_label=${a_req#*=}; [ "${a_label}" != "${a_req}" ] || a_label=''
        a_on=$(awk -v m="${a_mac}" '$1 == m && $2 == 1 { print 1; exit }' "${cdir}/hosts")
        if [ "${a_on}" != 1 ]; then
            finding "${FRITZBOX_LAN_REQUIRED_COLOR}" "required device ${a_mac}${a_label:+ (${a_label})} is not active"
        else
            plain "required device ${a_mac}${a_label:+ (${a_label})} is active"
        fi
    done

    # Unknown MACs (off by default: phones and VMs use random MACs).
    if [ "${FRITZBOX_LAN_NEW_MAC}" = 1 ] && [ "${a_hosts}" = 1 ]; then
        a_known=$(state_file lanmacs)
        holds_active "${a_known}" >"${cdir}/holds"
        if [ -r "${a_known}" ]; then
            awk -v known="${a_known}" 'BEGIN { while ((getline l < known) > 0) if (l !~ /^hold /) k[l] = 1 }
                $1 != "-" && !($1 in k) { print $1 }' "${cdir}/hosts" | sort -u | while read -r a_mac; do
                hold_add yellow "new device ${a_mac} in the host list"
            done >>"${cdir}/holds"
        else
            plain 'baseline of known MACs: new devices are reported from the next poll'
        fi
        { awk '$1 != "-" { print $1 }' "${cdir}/hosts"; [ ! -r "${a_known}" ] || awk '!/^hold /' "${a_known}"; } | sort -u >"${cdir}/macs"
        cat "${cdir}/macs" "${cdir}/holds" | save_state lanmacs
        holds_note "$(cat "${cdir}/holds")"
    fi

    if [ "${a_hosts}" = 1 ]; then summary="${a_act} of ${a_total} hosts active"
    else summary="${a_status:-status unknown}"; fi
    [ -z "${a_in}" ] || summary="${summary}, $(mbit "${a_out}")/$(mbit "${a_in}") Mbit/s to/from LAN"
    [ -s "${cdir}/notes" ] || plain 'LAN is healthy'
    [ -z "${a_status}" ] || detail '    interface        %s\n' "${a_status}"
    if [ -n "${a_in}" ]; then
        detail '    throughput       to LAN=%s from LAN=%s Mbit/s (average since the last poll)\n' "$(mbit "${a_out}")" "$(mbit "${a_in}")"
    elif [ -n "${a_rx}" ]; then
        detail '    throughput       not yet available (rates appear with the next poll)\n'
    fi
    [ -z "${a_rx}" ] || detail '    traffic total    to LAN=%s GiB from LAN=%s GiB\n' "$(gib "${a_tx}")" "$(gib "${a_rx}")"
    [ "${a_hosts}" != 1 ] || detail '    hosts            %s known, %s active (Ethernet %s, Wi-Fi %s, powerline %s, other %s), %s active guest(s)\n' \
        "${a_total}" "${a_act}" "${a_eth}" "${a_wlan}" "${a_plc}" "${a_oth}" "${a_guest}"
    col_end
}

# ----------------------------------------------------------------------
# Module tel -> fritztel: SIP account registration and DECT handsets.
# GetVoIPAccount and GetClient* return passwords and are never called.
# ----------------------------------------------------------------------
mod_tel() {
    col_begin fritztel 'Telephony'
    t_svc=urn:dslforum-org:service:X_VoIP:1
    if ! has_service "${t_svc}"; then
        col_clear 'no telephony' 'no X_VoIP service in the TR-064 description'
        col_end; return
    fi
    : >"${cdir}/accounts"
    if ! need "${t_svc}" X_AVM-DE_GetVoIPAccounts; then
        metric sip_total U; metric sip_registered U
        summary='SIP account list unavailable'
        col_end; return
    else
        # The list is escaped XML inside the response element.
        awk 'index($0, "NewX_AVM-DE_VoIPAccountList>") == 1 { print substr($0, 29); exit }' "${hw}/resp.lines" |
            sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e 's/&amp;/\&/g' | sed 's#<Account>#\n<Account>#g' | awk '
            function val(n,   s) {
                if (match($0, "<" n ">[^<]*</" n ">")) { s = substr($0, RSTART + length(n) + 2, RLENGTH - 2 * length(n) - 5); return s }
                return ""
            }
            /^<Account>/ {
                i = val("VoIPAccountIndex"); r = val("VoIPRegistrar"); nu = val("VoIPNumber"); st = val("X_AVM-DE_VoIPStatus")
                gsub(/[^0-9]/, "", i); gsub(/[^A-Za-z0-9._-]/, "", r); gsub(/[^0-9+#*]/, "", nu); gsub(/[^A-Za-z0-9_ -]/, "", st); gsub(/^ +| +$/, "", st)
                if (i != "") print i, (r == "" ? "-" : r), (nu == "" ? "-" : nu), (st == "" ? "-" : st)
            }' >"${cdir}/accounts"
    fi
    t_total=0 t_reg=0
    while read -r t_i t_reg_host t_num t_code <&4; do
        [ "${host_abort}" = 0 ] || break
        t_st=''
        if tr64 "${t_svc}" X_AVM-DE_GetVoIPStatus "<NewVoIPAccountIndex>${t_i}</NewVoIPAccountIndex>"; then
            # "not registered" contains a blank (TR-064_VoIP.pdf, table 53).
            t_st=$(field NewX_AVM-DE_VoIPStatus | tr -cd 'A-Za-z0-9_ -' | sed 's/^ *//; s/ *$//')
        fi
        # The documented account list contains text statuses. FRITZ!OS
        # 8.26 also returns numeric code 2 for registered on the reference
        # box; keep that fallback when the per-account action is absent.
        # The code is not documented, so no other number is interpreted.
        if [ -z "${t_st}" ]; then
            if [ "${t_code}" = 2 ]; then t_st=registered; else t_st=${t_code}; fi
        fi
        t_show="$(mask "${t_num}") via ${t_reg_host}"
        # Documented values (TR-064_VoIP.pdf, table 53): disabled, not
        # registered, registered, connected (a call is active), unknown.
        # A disabled account is switched off on purpose: listed, but
        # neither counted nor an alarm.
        case "${t_st}" in
            registered|connected)
                t_total=$((t_total + 1)) t_reg=$((t_reg + 1))
                detail '  &green SIP account %s: %s (%s)\n' "${t_i}" "${t_show}" "${t_st}" ;;
            disabled)
                detail '    SIP account %s: %s (disabled)\n' "${t_i}" "${t_show}" ;;
            *)
                t_total=$((t_total + 1))
                finding "${FRITZBOX_TEL_COLOR}" "SIP account ${t_i} (${t_show}) is not registered, status: ${t_st}"
                detail '  &%s SIP account %s: %s (%s)\n' "${FRITZBOX_TEL_COLOR}" "${t_i}" "${t_show}" "${t_st}" ;;
        esac
    done 4<"${cdir}/accounts"
    if [ "${host_abort}" = 0 ]; then
        metric sip_total "${t_total}"; metric sip_registered "${t_reg}"
    else
        metric sip_total U; metric sip_registered U
    fi
    if [ "${partial}" = 1 ] && [ "${t_total}" = 0 ]; then
        : # the failed request is already noted
    elif [ "${t_total}" = 0 ]; then
        col_clear 'no SIP accounts' 'no enabled SIP account is configured'
    fi

    # DECT handsets: information only. Active is 1 while the handset is
    # connected to the box, 0 while it is not (TR-064_DECT.pdf, ch. 5).
    d_svc=urn:dslforum-org:service:X_AVM-DE_Dect:1
    if [ "${host_abort}" = 0 ] && has_service "${d_svc}" && tr64 "${d_svc}" GetNumberOfDectEntries; then
        t_n=$(field NewNumberOfEntries)
        is_uint "${t_n}" || t_n=0
        t_i=0
        while [ "${t_i}" -lt "${t_n}" ] && [ "${t_i}" -lt "${max_entries}" ]; do
            tr64 "${d_svc}" GetGenericDectEntry "<NewIndex>${t_i}</NewIndex>" || break
            t_model=$(clean "$(field NewModel)")
            # Only explicit 0/1 establish a state. Missing values must
            # stay unknown; stripping characters could turn invalid1
            # into a fabricated connected state.
            case "$(field NewActive)" in
                1) t_conn=connected ;;
                0) t_conn='not connected' ;;
                *) t_conn='connection state unknown' ;;
            esac
            detail '    DECT %s: "%s"%s %s, update available=%s\n' "$(field NewID | tr -cd '0-9')" \
                "$(clean "$(field NewName)")" "${t_model:+ ${t_model}}" "${t_conn}" \
                "$(field NewUpdateAvailable | tr -cd '0-9')"
            t_i=$((t_i + 1))
        done
    fi
    [ "${color}" = clear ] || summary="${t_reg}/${t_total} SIP account(s) registered"
    [ -s "${cdir}/notes" ] || plain 'Telephony is healthy'
    col_end
}

# ----------------------------------------------------------------------
# Module plc -> no column: the box's powerline adapter list for
# powerline.sh, written to STATE_DIR/HOST.homeplug after delivery:
#   # fritzbox homeplug HOST EPOCH
#   MAC|active|update_available|update_result|model|name
# ----------------------------------------------------------------------
mod_plc() {
    p_svc=urn:dslforum-org:service:X_AVM-DE_Homeplug:1
    [ "${host_abort}" = 0 ] && has_service "${p_svc}" || return 0
    tr64 "${p_svc}" GetNumberOfDeviceEntries || return 0
    p_n=$(field NewNumberOfEntries)
    is_uint "${p_n}" || return 0
    printf '# fritzbox homeplug %s %s\n' "${host}" "${now}" >"${hw}/homeplug"
    p_i=0
    while [ "${p_i}" -lt "${p_n}" ] && [ "${p_i}" -lt "${max_entries}" ]; do
        tr64 "${p_svc}" GetGenericDeviceEntry "<NewIndex>${p_i}</NewIndex>"
        p_rc=${?}
        [ "${p_rc}" = 0 ] || { rm -f "${hw}/homeplug"; return 0; }
        printf '%s|%s|%s|%s|%s|%s\n' "$(field NewMACAddress | tr -cd '0-9A-Fa-f:' | tr 'a-f' 'A-F')" \
            "$(field NewActive | tr -cd '0-9')" "$(field NewUpdateAvailable | tr -cd '0-9')" \
            "$(field NewUpdateSuccessful | tr -cd 'A-Za-z_-')" "$(clean "$(field NewModel)")" \
            "$(clean "$(field NewName)")" >>"${hw}/homeplug"
        p_i=$((p_i + 1))
    done
    # A capped or interrupted enumeration is not a fresh complete list.
    # Leave the old hand-over file aging instead of hiding missing peers.
    if [ "${p_i}" -lt "${p_n}" ]; then
        log warning "${host}: homeplug list incomplete (${p_i}/${p_n}); keeping the previous list"
        rm -f "${hw}/homeplug"
    fi
}

# ----------------------------------------------------------------------
# Deliver one message, or print it for --dry-run.
# ----------------------------------------------------------------------
deliver() {
    if [ "${FRITZBOX_DRY_RUN}" = 1 ]; then printf '%s\n\n' "${1}"
    else "${XYMON}" "${XYMSRV}" "${1}"; fi
}

# column_of MODULE - the column a module reports (plc: none).
column_of() {
    case "${1}" in
        dsl) printf fritzdsl ;; wan) printf fritzwan ;; sys) printf fritzsys ;;
        log) printf fritzlog ;; fw) printf fritzfw ;; lan) printf fritzlan ;;
        tel) printf fritztel ;;
    esac
}

# title_of COLUMN - the status headline label.
title_of() {
    case "${1}" in
        fritzdsl) printf 'DSL line' ;; fritzwan) printf WAN ;; fritzsys) printf System ;;
        fritzlog) printf 'Event log' ;; fritzfw) printf Exposure ;; fritzlan) printf LAN ;;
        fritztel) printf Telephony ;;
    esac
}

# deliver_column COLUMN - status and trends of one column, then its
# state. After any failure the RRDs of the last clean run that got no
# value now are set to U: rrdtool would bridge a single missing update
# (heartbeat 600 s) with the next value and hide the outage.
deliver_column() {
    cdir="${hw}/col.${1}"
    { read -r c_color; read -r c_partial; read -r c_title; read -r c_summary; } <"${cdir}/meta"
    c_names="$(state_file "${1}").names"
    if [ "${c_partial}" = 1 ] && [ -r "${c_names}" ]; then
        # FILENAME, not NR == FNR: the metrics file may well be empty.
        awk -v m="${cdir}/metrics" 'FILENAME == m { have[$1] = 1; next }
             $1 ~ /^[a-z0-9_]+$/ && $2 ~ /^(GAUGE|DERIVE)$/ && !($1 in have) { have[$1] = 1; print $1, "U", $2 }' \
            "${cdir}/metrics" "${c_names}" >"${cdir}/unknown" || fail 'Cannot read the saved RRD names'
        cat "${cdir}/unknown" >>"${cdir}/metrics" || fail 'Cannot build the RRD values'
    fi
    [ "${c_color}" != red ] || log error "${host} ${1}: $(head -n 1 "${cdir}/notes" | sed 's/^&[a-z]* //')"
    [ "${c_color}" != yellow ] || log warning "${host} ${1}: $(head -n 1 "${cdir}/notes" | sed 's/^&[a-z]* //')"
    {
        printf 'status+%s %s.%s %s %s - %s: %s\n\n' "${FRITZBOX_LIFETIME}" "${wirehost}" "${1}" \
            "${c_color}" "$(date)" "${c_title}" "${c_summary}"
        cat "${cdir}/notes"
        if [ -s "${cdir}/details" ]; then printf '\n'; cat "${cdir}/details"; fi
        printf '\nPolled via TR-064 from %s by fritzbox.sh %s\n' "${base_url}" "${SCRIPT_VERSION}"
    } >"${cdir}/status" || fail 'Cannot build the status message'
    c_sent=1
    deliver "$(cat "${cdir}/status")" || c_sent=0
    if [ -s "${cdir}/metrics" ]; then
        deliver "data ${wirehost}.trends
$(awk -v c="${1}" '{ printf "[%s,%s.rrd]\nDS:lambda:%s:600:%s:U %s\n", c, $1, $3, ($3 == "DERIVE" ? "0" : "U"), $2 }' "${cdir}/metrics")" || c_sent=0
    fi
    if [ "${c_sent}" = 0 ]; then
        log error "${host} ${1}: Xymon delivery failed; state not updated"
        sent_all=0
        return
    fi
    [ "${FRITZBOX_DRY_RUN}" = 0 ] || return 0
    # Remember the names: a clean run replaces the list, a failed one
    # keeps the old names too.
    if [ "${c_partial}" = 1 ] && [ -r "${c_names}" ]; then
        { awk '{ print $1, $3 }' "${cdir}/metrics"; awk '$1 ~ /^[a-z0-9_]+$/' "${c_names}"; } | awk '!seen[$1]++'
    else
        awk '{ print $1, $3 }' "${cdir}/metrics"
    fi >"${cdir}/names"
    mv "${cdir}/names" "${c_names}" || log error "${host}: cannot write ${c_names}"
    for c_save in "${cdir}"/save.*; do
        [ -e "${c_save}" ] || continue
        mv "${c_save}" "$(state_file "${c_save##*/save.}")" || log error "${host}: cannot write the ${1} state"
    done
}

# ----------------------------------------------------------------------
# poll_host NAME IP - poll, render, deliver and remember one box.
# ----------------------------------------------------------------------
sent_all=1
poll_host() {
    host=${1} ip=${2}
    hw="${work}/host"
    rm -rf "${hw}"
    mkdir "${hw}" || fail 'Cannot create the per-host work directory'
    : >"${hw}/columns"; : >"${hw}/services"; : >"${hw}/igd"
    host_abort=0 igd_loaded=0
    now=$(now_s)
    case "${ip}" in ''|0.0.0.0) target=${host} ;; *) target=${ip} ;; esac
    base_url="http://${target}:${FRITZBOX_PORT}"
    wirehost=$(printf '%s' "${host}" | tr . ,)
    log debug "Polling ${host} at ${base_url}"
    h_problem='' h_color='' h_summary=''

    # Credentials: prompt > FRITZPASSWORT > password file; user:
    # FRITZBOX_USER > password file column > "xymon".
    c_user='' c_pass='' cred_config=''
    if [ "${curl_ok}" = 0 ]; then
        h_color=clear h_summary='not checked'
        h_problem="curl (${FRITZBOX_CURL}) not found - install curl to enable this test"
    elif [ "${ask_password}" = 1 ]; then
        c_pass=${asked_password}
    elif [ -n "${env_password}" ]; then
        c_pass=${env_password}
    elif [ "${passfile_ok}" = 1 ] && c_entry=$(lookup_password "${host}" "${ip}"); then
        c_user=${c_entry%%"${NL}"*}
        c_pass=${c_entry#*"${NL}"}
    else
        h_color=yellow h_summary='no password'
        if [ "${passfile_ok}" = 1 ]; then
            h_problem="no password for ${host}${ip:+ or ${ip}} in ${FRITZBOX_PASSFILE}${passfile_malformed:+ (${passfile_malformed})}"
        else
            h_problem="no password for ${host}: ${passfile_problem}"
        fi
    fi
    if [ -z "${h_problem}" ]; then
        [ "${c_user}" != - ] || c_user=''
        [ -z "${FRITZBOX_USER}" ] || c_user=${FRITZBOX_USER}
        [ -n "${c_user}" ] || c_user=xymon
        cred_config="user = \"$(curl_quote "${c_user}"):$(curl_quote "${c_pass}")\""
    fi
    c_pass='' c_entry=''

    # The device description lists the services; it needs no login.
    if [ -z "${h_problem}" ]; then
        fetch /tr64desc.xml
        case "${?}" in
            0) parse_desc "${hw}/resp" >"${hw}/services" ;;
            1) h_color=red h_summary=unreachable h_problem=$(soap_problem 1) ;;
            5) h_color=yellow h_summary='run time budget exhausted' h_problem=$(soap_problem 5) ;;
            *) h_color=yellow h_summary='TR-064 error'
               h_problem="TR-064 device description not available at ${base_url}/tr64desc.xml (HTTP ${HTTPCODE}) - is TR-064 enabled?" ;;
        esac
    fi
    # Probe the login once, so a wrong password costs one refused
    # request and not one per module (the box delays repeated failures).
    # Not GetSecurityPort: TR-064 answers that one without a login.
    if [ -z "${h_problem}" ]; then
        tr64 urn:dslforum-org:service:DeviceInfo:1 GetInfo
        case "${?}" in
            1) h_color=red h_summary=unreachable h_problem=$(soap_problem 1) ;;
            2) h_color=yellow h_summary='authentication failed' h_problem=$(soap_problem 2) ;;
            6) h_color=yellow h_summary='TR-064 error' h_problem='no DeviceInfo service in the TR-064 description - not a FRITZ!Box?' ;;
        esac
    fi

    for m in ${FRITZBOX_MODULES}; do
        if [ -n "${h_problem}" ]; then
            [ "${m}" != plc ] || continue
            col_begin "$(column_of "${m}")" "$(title_of "$(column_of "${m}")")"
            if [ "${h_color}" = clear ]; then col_clear "${h_summary}" "${h_problem}"
            else note "${h_color}" "${h_problem}"; summary=${h_summary}; partial=1; fi
            col_end
            continue
        fi
        case "${m}" in
            dsl) mod_dsl ;; wan) mod_wan ;; sys) mod_sys ;; log) mod_log ;;
            fw) mod_fw ;; lan) mod_lan ;; tel) mod_tel ;; plc) mod_plc ;;
        esac
    done
    cred_config=''

    while read -r d_col <&5; do
        deliver_column "${d_col}"
    done 5<"${hw}/columns"

    # Hand-over file for powerline.sh: replaced atomically, kept as it is
    # (and so aging) when this poll could not read the adapter list.
    if [ -s "${hw}/homeplug" ] && [ "${FRITZBOX_DRY_RUN}" = 0 ]; then
        mv "${hw}/homeplug" "$(state_file homeplug)" || log error "${host}: cannot write the homeplug file"
    elif [ -s "${hw}/homeplug" ]; then
        log debug "${host}: homeplug list (dry run, not saved): $(awk 'NR > 1' "${hw}/homeplug" | wc -l | tr -d ' ') adapter(s)"
    fi
}

# Hosts one after another (few boxes; a dead one costs at most the
# connect timeout). fd 3 keeps the list away from curl's stdin.
while read -r t_host t_ip <&3; do
    poll_host "${t_host}" "${t_ip:-}"
done 3<"${work}/targets"
[ "${sent_all}" = 1 ] || exit 1
log debug 'Collection complete'
exit 0
