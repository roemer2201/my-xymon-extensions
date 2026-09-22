#!/bin/sh
# Server-side, read-only PLC monitoring. Reports one powerline column per
# adapter, plus collector health on the Xymon server; never edits hosts.cfg.
# Program flow:
# 1. Resolve config (defaults < config < environment < CLI), validate inputs.
# 2. Lock persistent state, read effective hosts and passive neighbor cache.
# 3. Discover topology, query each adapter/link through the restricted helper.
# 4. Calculate identity, interval metrics and persistent change/flap timers.
# 5. Deliver status and native trends data, then atomically commit state.
# Usage: powerline.sh --config /path/powerline.cfg --verbose --dry-run
# Version: 1.0.0 (2026-09-22)
set -u
CONFIG_NAME=powerline.cfg
BASE=$(CDPATH='' cd -- "$(dirname -- "${0}")" && pwd) || exit 1

# All collector settings also accept --set POWERLINE_NAME=VALUE. Runtime
# Xymon variables are supplied by xymonlaunch/xymoncmd, not guessed paths.
usage() {
    cat <<'EOF'
Usage: powerline.sh [--config FILE] [--interface IFACE] [--set KEY=VALUE]
                    [--silent | --verbose] [--dry-run] [--help]
  --config FILE       POWERLINE_CONFIG; default XYMONHOME/etc/
                      my-xymon-extensions-server/powerline.cfg
  --interface IFACE   POWERLINE_IFACE (eth0)
  -s, --silent        POWERLINE_SILENT=1; suppress normal console output
  -v, --verbose       POWERLINE_VERBOSE=1; diagnostic logging
  --dry-run           POWERLINE_DRY_RUN=1; read PLC, print messages, no delivery
                      or persistent snapshot change (lock/temp files only)
  --set KEY=VALUE     Any of the following environment/config settings:
    POWERLINE_ENABLED (1), POWERLINE_IFACE (eth0), POWERLINE_LIFETIME (15)
    POWERLINE_CHANGE_MINUTES (60), POWERLINE_FLAP_MINUTES (180)
    POWERLINE_MAX_SAMPLE_GAP (900 seconds)
    POWERLINE_STATE_DIR (XYMONVAR/powerline)
    POWERLINE_MAPPING (optional file; a missing file just means no mapping)
    POWERLINE_HOSTS (HOSTSCFG), POWERLINE_XYMONCFG (XYMONHOME/bin/xymoncfg)
    POWERLINE_HELPER (adjacent powerline-read.sh), POWERLINE_SUDO (sudo)
    POWERLINE_IP (ip), POWERLINE_COLLECTOR_HOST (MACHINEDOTS/MACHINE)
    POWERLINE_TX_PHY_WARN/CRIT, POWERLINE_RX_PHY_WARN/CRIT (off; minimum Mbps)
    POWERLINE_TX_PB_WARN/CRIT, POWERLINE_RX_PB_WARN/CRIT (off; maximum percent)
    POWERLINE_SILENT, POWERLINE_VERBOSE, POWERLINE_DRY_RUN (0)
    POWERLINE_NOW (epoch seconds; replay tests only, normally system clock)
  -h, --help          Show this help without accessing devices or state.
Precedence: CLI > exported environment > trusted shell config > defaults.
Silent and verbose are mutually exclusive. Automated runs log via syslog.
An empty POWERLINE_SUDO executes the helper directly (unprivileged fixtures
or an already privileged manual run); it grants no extra permission.
Requires Linux iproute2/flock, POSIX sh/awk and configured Xymon environment.
Example: powerline.sh --interface eth0 --set POWERLINE_TX_PHY_WARN=100 --dry-run
EOF
}

# Restrict configurable names; use export with a single argument, never eval.
setting() {
    # shellcheck disable=SC2163 # Export a validated NAME=VALUE, not positional $1.
    case "${1%%=*}" in
        POWERLINE_ENABLED|POWERLINE_IFACE|POWERLINE_LIFETIME|POWERLINE_CHANGE_MINUTES|POWERLINE_FLAP_MINUTES|POWERLINE_MAX_SAMPLE_GAP|POWERLINE_STATE_DIR|POWERLINE_MAPPING|POWERLINE_HOSTS|POWERLINE_XYMONCFG|POWERLINE_HELPER|POWERLINE_SUDO|POWERLINE_IP|POWERLINE_COLLECTOR_HOST|POWERLINE_TX_PHY_WARN|POWERLINE_TX_PHY_CRIT|POWERLINE_RX_PHY_WARN|POWERLINE_RX_PHY_CRIT|POWERLINE_TX_PB_WARN|POWERLINE_TX_PB_CRIT|POWERLINE_RX_PB_WARN|POWERLINE_RX_PB_CRIT|POWERLINE_SILENT|POWERLINE_VERBOSE|POWERLINE_DRY_RUN|POWERLINE_NOW) export "${1}" ;;
        *) printf 'Unknown setting: %s\n' "${1%%=*}" >&2; exit 2 ;;
    esac
}

# Parse without touching the filesystem so help is always usable.
cli=''
config=${POWERLINE_CONFIG:-${XYMONHOME:-}/etc/my-xymon-extensions-server/${CONFIG_NAME}}
explicit_config=0
[ -z "${POWERLINE_CONFIG:-}" ] || explicit_config=1
while [ "${#}" -gt 0 ]; do
    case "${1}" in
        -h|--help) usage; exit 0 ;;
        --config|--interface|--set)
            [ "${#}" -ge 2 ] || { printf '%s requires a value\n' "${1}" >&2; exit 2; }
            case "${1}" in
                --config) config=${2}; explicit_config=1 ;;
                --interface) cli="${cli}
POWERLINE_IFACE=${2}" ;;
                --set) case "${2}" in POWERLINE_*=*) cli="${cli}
${2}" ;; *) printf '%s\n' 'Expected POWERLINE_KEY=VALUE' >&2; exit 2 ;; esac ;;
            esac
            shift 2 ;;
        -s|--silent) cli="${cli}
POWERLINE_SILENT=1"; shift ;;
        -v|--verbose) cli="${cli}
POWERLINE_VERBOSE=1"; shift ;;
        --dry-run) cli="${cli}
POWERLINE_DRY_RUN=1"; shift ;;
        *) printf 'Unknown option: %s\n' "${1}" >&2; exit 2 ;;
    esac
done
saved_env=$(env | LC_ALL=C sort | awk '/^POWERLINE_/ && !/^POWERLINE_CONFIG=/')
POWERLINE_ENABLED=1 POWERLINE_IFACE=eth0 POWERLINE_LIFETIME=15
POWERLINE_CHANGE_MINUTES=60 POWERLINE_FLAP_MINUTES=180 POWERLINE_MAX_SAMPLE_GAP=900
POWERLINE_STATE_DIR=${XYMONVAR:-}/powerline
POWERLINE_MAPPING='' POWERLINE_HOSTS=${HOSTSCFG:-${XYMONHOME:-}/etc/hosts.cfg}
POWERLINE_XYMONCFG=${XYMONHOME:-}/bin/xymoncfg
POWERLINE_HELPER=${BASE}/powerline-read.sh POWERLINE_SUDO=sudo POWERLINE_IP=ip
POWERLINE_COLLECTOR_HOST=${MACHINEDOTS:-${MACHINE:-}}
POWERLINE_TX_PHY_WARN=off POWERLINE_TX_PHY_CRIT=off POWERLINE_RX_PHY_WARN=off POWERLINE_RX_PHY_CRIT=off
POWERLINE_TX_PB_WARN=off POWERLINE_TX_PB_CRIT=off POWERLINE_RX_PB_WARN=off POWERLINE_RX_PB_CRIT=off
POWERLINE_SILENT=0 POWERLINE_VERBOSE=0 POWERLINE_DRY_RUN=0 POWERLINE_NOW=$(date +%s)
if [ -r "${config}" ]; then
    # Trusted admin-owned file; separate server package path is intentional.
    set -a
    # shellcheck source=/dev/null
    . "${config}"
    set +a
elif [ "${explicit_config}" -eq 1 ]; then
    printf 'Cannot read config: %s\n' "${config}" >&2; exit 1
fi
while IFS= read -r assignment; do
    [ -z "${assignment}" ] || setting "${assignment}"
done <<EOF
${saved_env}
${cli}
EOF
export POWERLINE_NOW POWERLINE_CHANGE_MINUTES POWERLINE_FLAP_MINUTES POWERLINE_MAX_SAMPLE_GAP
export POWERLINE_TX_PHY_WARN POWERLINE_TX_PHY_CRIT POWERLINE_RX_PHY_WARN POWERLINE_RX_PHY_CRIT
export POWERLINE_TX_PB_WARN POWERLINE_TX_PB_CRIT POWERLINE_RX_PB_WARN POWERLINE_RX_PB_CRIT
LC_ALL=C
export LC_ALL
umask 077
work=''

# Explicit logging was requested for this server task. Keep tool diagnostics
# on stderr; normal helper progress is verbose-only, never parsed as samples.
log() {
    level=${1}; shift
    [ "${level}" != debug ] || [ "${POWERLINE_VERBOSE}" = 1 ] || return 0
    if command -v logger >/dev/null 2>&1; then logger -t powerline -- "${level}: ${*}" || :; fi
    if [ "${level}" = error ]; then printf 'powerline: %s\n' "${*}" >&2
    elif [ "${POWERLINE_SILENT}" = 0 ] && { [ -t 1 ] || [ "${POWERLINE_VERBOSE}" = 1 ]; }; then
        printf 'powerline: %s\n' "${*}" >&2
    fi
}

# A collector failure is not a presence change. Leave the saved inventory
# untouched, and mark every previously resolved adapter and collector red.
fail() {
    log error "${*}"
    if [ -n "${work}" ] && [ "${POWERLINE_DRY_RUN}" = 0 ]; then
        { printf '%s\n' "${POWERLINE_COLLECTOR_HOST}";
          if [ -r "${POWERLINE_STATE_DIR}/state" ]; then
              awk -F '|' '$1=="state" {print $4}' "${POWERLINE_STATE_DIR}/state"
          fi;
        } | sort -u | while IFS= read -r failedhost; do
            case "${failedhost}" in ''|*[!a-zA-Z0-9_.-]*) continue ;; esac
            failedhost=$(printf '%s' "${failedhost}" | tr . ,)
            "${XYMON}" "${XYMSRV}" "status+${POWERLINE_LIFETIME} ${failedhost}.powerline red $(date)
Powerline collector failed. See the powerline task log; inventory not updated." || :
        done
    fi
    exit 1
}

# Validate numeric settings before arithmetic, path use or packet delivery.
for n in "${POWERLINE_LIFETIME}" "${POWERLINE_CHANGE_MINUTES}" "${POWERLINE_FLAP_MINUTES}" "${POWERLINE_MAX_SAMPLE_GAP}" "${POWERLINE_NOW}"; do
    case "${n}" in ''|*[!0-9]*) fail 'Expected positive integer timer' ;; esac
    [ "${n}" -gt 0 ] || fail 'Timer must be positive'
done
for n in "${POWERLINE_ENABLED}" "${POWERLINE_SILENT}" "${POWERLINE_VERBOSE}" "${POWERLINE_DRY_RUN}"; do
    case "${n}" in 0|1) ;; *) fail 'Boolean settings must be 0 or 1' ;; esac
done
[ "${POWERLINE_FLAP_MINUTES}" -ge "${POWERLINE_CHANGE_MINUTES}" ] || fail 'Flap duration must not be shorter than hold duration'
[ "${POWERLINE_SILENT}${POWERLINE_VERBOSE}" != 11 ] || fail 'Silent and verbose are mutually exclusive'
awk 'BEGIN {
    split("TX_PHY RX_PHY TX_PB RX_PB", a, " ")
    for (i in a) {
        w=ENVIRON["POWERLINE_" a[i] "_WARN"]; c=ENVIRON["POWERLINE_" a[i] "_CRIT"]
        if ((w!="off" && w !~ /^[0-9]+([.][0-9]+)?$/) || (c!="off" && c !~ /^[0-9]+([.][0-9]+)?$/)) exit 1
        if (a[i] ~ /PB/ && ((w!="off" && w+0>100) || (c!="off" && c+0>100))) exit 1
        if (w!="off" && c!="off" && ((a[i]~/PHY/ && c+0>w+0) || (a[i]~/PB/ && c+0<w+0))) exit 1
    }
}' || fail 'Invalid threshold or warning/critical ordering'
[ "${POWERLINE_ENABLED}" = 1 ] || exit 0
case "${POWERLINE_IFACE}" in ''|-*|*[!a-zA-Z0-9_.:-]*) fail 'Invalid PLC interface' ;; esac
case "${POWERLINE_COLLECTOR_HOST}" in ''|*[!a-zA-Z0-9_.-]*) fail 'Set POWERLINE_COLLECTOR_HOST to the canonical server host' ;; esac
case "${POWERLINE_STATE_DIR}" in /*) ;; *) fail 'State directory must be absolute' ;; esac
[ "${POWERLINE_STATE_DIR}" != /powerline ] || fail 'Set XYMONVAR or POWERLINE_STATE_DIR to a persistent writable directory'
if [ -z "${XYMON:-}" ] || [ -z "${XYMSRV:-}" ]; then
    fail 'Use the Xymon server environment (XYMON/XYMSRV)'
fi
command -v "${XYMON}" >/dev/null 2>&1 || fail 'Xymon sender is not executable'
command -v flock >/dev/null 2>&1 || fail 'flock is required'
mkdir -p "${POWERLINE_STATE_DIR}" || fail 'Cannot create persistent state directory'
exec 9>"${POWERLINE_STATE_DIR}/lock"
flock -n 9 || { log debug 'Another collector holds the lock'; exit 0; }
work=$(mktemp -d "${POWERLINE_STATE_DIR}/run.XXXXXX") || fail 'Cannot create temporary directory'
trap 'rm -rf "${work}"' 0
trap 'exit 1' 1 2 15
log info "Collecting on ${POWERLINE_IFACE}"

# Flatten Xymon includes with Xymon's own parser, never a partial reimplementation.
if [ -x "${POWERLINE_XYMONCFG}" ]; then
    "${POWERLINE_XYMONCFG}" "${POWERLINE_HOSTS}" >"${work}/hosts" || fail 'Cannot load effective hosts.cfg'
else
    [ -r "${POWERLINE_HOSTS}" ] || fail 'Cannot read hosts.cfg'
    if grep -E '^[[:space:]]*(optional[[:space:]]+)?(include|directory|netinclude|dispinclude)[[:space:]]' "${POWERLINE_HOSTS}" >/dev/null; then
        fail 'hosts.cfg contains includes; configure POWERLINE_XYMONCFG'
    fi
    cp "${POWERLINE_HOSTS}" "${work}/hosts" || fail 'Cannot copy hosts.cfg'
fi
awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $2!=".default." {
    alias=""; for(i=3;i<=NF;i++) if($i~/^CLIENT:/) alias=substr($i,8)
    print "host|" $1 "|" $2 "|" alias
}' "${work}/hosts" >"${work}/identity" || fail 'Cannot parse hosts'
"${POWERLINE_IP}" -4 neigh show dev "${POWERLINE_IFACE}" >"${work}/neighbors" || fail 'Cannot read neighbor cache'
awk '{for(i=2;i<NF;i++) if($i=="lladdr") {
    mac=tolower($(i+1)); gsub(/:/,"",mac)
    if(length(mac)==12 && mac~/^[0-9a-f]+$/) print "neighbor|" $1 "|" mac
}}' "${work}/neighbors" >>"${work}/identity" || fail 'Cannot parse neighbors'
# The shipped config names a mapping file the package installs as a conffile.
# An absent file means "no static mapping", not a broken collector - only an
# existing but unusable one is an error worth turning every adapter red.
if [ -n "${POWERLINE_MAPPING}" ] && [ -e "${POWERLINE_MAPPING}" ]; then
    [ -r "${POWERLINE_MAPPING}" ] || fail 'Static mapping exists but is not readable'
    awk 'NF && $1!~/^#/ {if(NF!=2) exit 1; m=tolower($1); gsub(/:/,"",m); print "map|" m "|" $2}' \
        "${POWERLINE_MAPPING}" >>"${work}/identity" || fail 'Cannot parse static mapping'
elif [ -n "${POWERLINE_MAPPING}" ]; then
    log debug "No static mapping file at ${POWERLINE_MAPPING}; using discovery only"
fi

# Execute fixed operations through sudo -n; argv cannot contain extra options.
query() {
    if [ -n "${POWERLINE_SUDO}" ]; then
        "${POWERLINE_SUDO}" -n "${POWERLINE_HELPER}" "${@}" >"${work}/stdout" 2>"${work}/stderr"
    else
        "${POWERLINE_HELPER}" "${@}" >"${work}/stdout" 2>"${work}/stderr"
    fi
    rc=${?}
    if [ "${rc}" -ne 0 ]; then log error "PLC request failed: ${*}: $(cat "${work}/stderr")"
    elif [ -s "${work}/stderr" ]; then log debug "${*}: $(cat "${work}/stderr")"; fi
    return "${rc}"
}
# Convert validated compact inventory MACs back to tool syntax.
colon_mac() { printf '%s\n' "${1}" | sed 's/../&:/g;s/:$//'; }
query topology "${POWERLINE_IFACE}" || fail 'Topology query failed'
awk -v mode=topology -f "${BASE}/powerline-parse.awk" "${work}/stdout" >"${work}/topology.raw" || fail 'Empty or malformed topology response'
sort -u "${work}/topology.raw" >"${work}/topology" || fail 'Cannot normalize topology'
: >"${work}/samples"
awk -F '|' '$1=="node"{print $2}' "${work}/topology" | sort -u >"${work}/adapters"
while IFS= read -r adapter; do
    # A healthy lone local adapter has no peer rate rows to return.
    grep -q "^edge|${adapter}|" "${work}/topology" || continue
    if query rates "${POWERLINE_IFACE}" "$(colon_mac "${adapter}")" &&
        awk -v mode=rates -v adapter="${adapter}" -f "${BASE}/powerline-parse.awk" "${work}/stdout" >"${work}/parsed"; then
        cat "${work}/parsed" >>"${work}/samples" || fail 'Cannot append rates'
    else
        printf 'fault|%s|Empty or invalid PHY response\n' "${adapter}" >>"${work}/samples"
    fi
done <"${work}/adapters"
while IFS='|' read -r kind adapter peer; do
    [ "${kind}" = edge ] || continue
    if query stats "${POWERLINE_IFACE}" "$(colon_mac "${adapter}")" "$(colon_mac "${peer}")" &&
        awk -v mode=stats -v adapter="${adapter}" -v peer="${peer}" -f "${BASE}/powerline-parse.awk" "${work}/stdout" >"${work}/parsed"; then
        cat "${work}/parsed" >>"${work}/samples" || fail 'Cannot append statistics'
    else
        printf 'fault|%s|Empty or invalid statistics response for peer %s\n' "${adapter}" "${peer}" >>"${work}/samples"
    fi
done <"${work}/topology"

# Compute only after an entirely valid topology. State is never shell-sourced.
: >"${work}/old"
if [ -f "${POWERLINE_STATE_DIR}/state" ]; then
    grep -q '^baseline|1$' "${POWERLINE_STATE_DIR}/state" || fail 'Invalid saved state: baseline marker missing'
    cp "${POWERLINE_STATE_DIR}/state" "${work}/old" || fail 'Cannot read state'
fi
awk -v outdir="${work}" -v snapshot="${work}/newstate" -v manifest="${work}/manifest" \
    -f "${BASE}/powerline-state.awk" "${work}/old" "${work}/identity" "${work}/topology" "${work}/samples" || fail 'State/identity calculation failed'
[ -s "${work}/manifest" ] || fail 'No adapter status produced'

# Deliver distinct status and trends messages. Missing values are RRD U, not
# zero; each metric has a stable pair/slot filename. No status sent by nc client.
deliver() {
    if [ "${POWERLINE_DRY_RUN}" = 1 ]; then printf '%s\n\n' "${1}"
    else "${XYMON}" "${XYMSRV}" "${1}"; fi
}
sent=1
collector_seen=0
while IFS='|' read -r host color summary; do
    [ "${host}" != "${POWERLINE_COLLECTOR_HOST}" ] || collector_seen=1
    wirehost=$(printf '%s' "${host}" | tr . ,)
    details=''
    [ ! -f "${work}/${host}.details" ] || details=$(cat "${work}/${host}.details")
    deliver "status+${POWERLINE_LIFETIME} ${wirehost}.powerline ${color} $(date) ${summary}
${details}
$(cat "${work}/${host}.metrics")" || sent=0
    deliver "data ${wirehost}.trends
$(cat "${work}/${host}.trends")" || sent=0
done <"${work}/manifest"
if [ "${collector_seen}" = 0 ]; then
    wirehost=$(printf '%s' "${POWERLINE_COLLECTOR_HOST}" | tr . ,)
    deliver "status+${POWERLINE_LIFETIME} ${wirehost}.powerline green $(date) Powerline collector OK" || sent=0
fi
[ "${sent}" = 1 ] || fail 'Xymon delivery failed; state not committed'
if [ "${POWERLINE_DRY_RUN}" = 0 ]; then
    mv "${work}/newstate" "${POWERLINE_STATE_DIR}/state" || fail 'Cannot commit state'
fi
log info 'Collection complete'
