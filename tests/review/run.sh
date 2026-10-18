#!/bin/sh
# Reproduce cross-extension regressions found during the full code review.
# Program flow: create isolated tools/state, exercise failure and collision
# cases, then verify messages, exit statuses and on-disk state.
# Usage: run.sh [--help]; TESTSH selects the shell (default: sh).
# Version: 1.0.0 (2026-10-18)
set -u
case "${1:-}" in -h|--help) printf '%s\n' 'Usage: run.sh; TESTSH selects the shell under test. No hardware/network access.'; exit 0 ;; esac
REPO=$(CDPATH='' cd -- "$(dirname -- "${0}")/../.." && pwd) || exit 1
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "${TMP}"' 0
trap 'exit 1' 1 2 15
TESTSH=${TESTSH:-sh}
FAIL=0
mkdir -p "${TMP}/bin" "${TMP}/state" "${TMP}/cwd" || exit 1
# Discard inherited fixture/config settings from tests/run.sh.
for var in $(env | sed -n 's/^\([A-Z_][A-Z_0-9]*\)=.*/\1/p'); do
    case "${var}" in SMART_*|FAKE*|TEMP_*|LA_*|MEM_*|DISK_*|OPKG_*|WIFI_*|IF_LINK_*|LXC_*|CLAUDE_*|SYSD_*|BTRFS_*|XYMON*) unset "${var}" ;; esac
done
XYMONTMP=${TMP}/state MACHINE=reviewhost
export XYMONTMP MACHINE

# Record an assertion without aborting the remaining independent cases.
ok() {
    if "${@}"; then printf 'ok: review %s\n' "${*}"
    else printf 'FAIL: review %s\n' "${*}"; FAIL=1; fi
}
# Execute an extension with the selected POSIX shell; capture both streams.
run() {
    r_script=${1}; shift
    # shellcheck disable=SC2086 # TESTSH supports multiword shell commands.
    ${TESTSH} "${REPO}/${r_script}" "${@}" >"${TMP}/out" 2>"${TMP}/err"
    rc=$?
}
# shellcheck disable=SC2317,SC2329 # Called by ok.
has() { grep -Eq -- "${1}" "${TMP}/out"; }
# shellcheck disable=SC2317,SC2329 # Called by ok.
exit_is() { [ "${rc}" -eq "${1}" ]; }

# A failed status send must not disappear behind an empty data branch or exit 0.
printf '#!/bin/sh\nexit 1\n' >"${TMP}/bin/fail"
chmod +x "${TMP}/bin/fail"
XYMON=${TMP}/bin/fail XYMSRV=127.0.0.1
TEMP_CFG=/dev/null LA_CFG=/dev/null MEM_CFG=/dev/null DISK_CFG=/dev/null
OPKG_CFG=/dev/null WIFI_CFG=/dev/null IF_LINK_CFG=/dev/null LXC_CFG=/dev/null
CLAUDE_CFG=/dev/null SYSD_CFG=/dev/null BTRFS_CFG=/dev/null
export XYMON XYMSRV TEMP_CFG LA_CFG MEM_CFG DISK_CFG OPKG_CFG WIFI_CFG IF_LINK_CFG
export LXC_CFG CLAUDE_CFG SYSD_CFG BTRFS_CFG
for ext in temp la memory disk opkg wifi if_link lxc claude systemd btrfs; do
    run "extensions/${ext}/${ext}.sh"
    ok exit_is 1
done
SMART_CFG=${TMP}/smart.cfg
printf 'SMARTCTL=/nonexistent\nMMC_DEVICES=none\n' >"${SMART_CFG}"
export SMART_CFG
run extensions/smart/smart.sh
ok exit_is 1
unset XYMON XYMSRV

# A wildcard whitelist/exclusion must have the same meaning in any cwd.
touch "${TMP}/cwd/lan-unrelated" "${TMP}/cwd/ct-unrelated"
IF_LINK_SYSNET=${REPO}/tests/if_link/sysnet IF_LINK_INTERFACES='lan*'
export IF_LINK_SYSNET IF_LINK_INTERFACES
cd "${TMP}/cwd" || exit 1
run extensions/if_link/if_link.sh
ok has 'lan1  link='
IF_LINK_INTERFACES=lan1 IF_LINK_EXCLUDE='lan*'
export IF_LINK_INTERFACES
export IF_LINK_EXCLUDE
run extensions/if_link/if_link.sh
ok has '^status reviewhost\.if_link clear '
unset IF_LINK_EXCLUDE

# Per-interface threshold specifications also contain wildcard patterns.
touch "${TMP}/cwd/lan-unrelated:1:2"
IF_LINK_SYSNET=${TMP}/sysnet
mkdir -p "${IF_LINK_SYSNET}/lan1"
printf '5\n' >"${IF_LINK_SYSNET}/lan1/carrier_changes"
printf '1\n' >"${IF_LINK_SYSNET}/lan1/carrier"
export IF_LINK_SYSNET
IF_LINK_THRESHOLDS='lan*:1:2'
export IF_LINK_THRESHOLDS
printf 'IF lan1 %s 0\n' "$(date +%s)" >"${XYMONTMP}/if_link.${MACHINE}.state"
run extensions/if_link/if_link.sh
ok has '^status reviewhost\.if_link red '
unset IF_LINK_THRESHOLDS

# The old predictable PID temporary path must never be opened/truncated.
printf 'preserve me\n' >"${TMP}/victim"
VICTIM=${TMP}/victim
export VICTIM
# shellcheck disable=SC2086,SC2016 # The driver expands its own variables; both driver and exec use the selected shell.
${TESTSH} -c 'ln -s "${VICTIM}" "${XYMONTMP}/if_link.${MACHINE}.state.$$"; exec "$@"' review ${TESTSH} "${REPO}/extensions/if_link/if_link.sh" >"${TMP}/out" 2>"${TMP}/err"
ok grep -qx 'preserve me' "${VICTIM}"
ok test -n "$(find "${XYMONTMP}/if_link.${MACHINE}.state" -prune -perm 0600 -print)"

# Short container name "ca" is also a substring of its parent ca-parent.slice.
mkdir -p "${TMP}/proc/123" "${TMP}/cg/ca-parent.slice/lxc.payload.ca"
printf '0::/ca-parent.slice/lxc.payload.ca/init.scope\n' >"${TMP}/proc/123/cgroup"
printf '1048576\n' >"${TMP}/cg/ca-parent.slice/lxc.payload.ca/memory.current"
# Container "cb" got the retry name lxc.payload.cb-1 while a stale
# lxc.payload.cb still existed.
mkdir -p "${TMP}/proc/124" "${TMP}/cg/lxc.payload.cb" "${TMP}/cg/lxc.payload.cb-1"
printf '0::/lxc.payload.cb-1\n' >"${TMP}/proc/124/cgroup"
printf '3145728\n' >"${TMP}/cg/lxc.payload.cb/memory.current"
printf '2097152\n' >"${TMP}/cg/lxc.payload.cb-1/memory.current"
printf 'NAME STATE PID AUTOSTART\nca RUNNING 123 0\ncb RUNNING 124 0\nct-off STOPPED - 1\n' >"${TMP}/inventory"
# shellcheck disable=SC2016 # The fixture expands INVENTORY when executed.
printf '#!/bin/sh\ncat "${INVENTORY}"\n' >"${TMP}/bin/lxc-ls"
chmod +x "${TMP}/bin/lxc-ls"
INVENTORY=${TMP}/inventory LXC_LS=${TMP}/bin/lxc-ls LXC_INFO=/nonexistent
LXC_AUTOSTART=/nonexistent LXC_UCI_AUTO=/nonexistent LXC_RAM=cgroup
LXC_CGROUPFS=${TMP}/cg LXC_PROC=${TMP}/proc LXC_IGNORE='ct*'
export INVENTORY LXC_LS LXC_INFO LXC_AUTOSTART LXC_UCI_AUTO LXC_RAM
export LXC_CGROUPFS LXC_PROC LXC_IGNORE
run extensions/lxc/lxc.sh
ok has '^ca_ram : 1\.0$'
ok has '^cb_ram : 2\.0$'
ok has '^status reviewhost\.lxc green '
# A failed inventory query cannot prove that no containers exist.
LXC_LS=${TMP}/bin/fail
export LXC_LS
run extensions/lxc/lxc.sh
ok has '^status reviewhost\.lxc yellow '
ok has 'container status unknown'

# One newly refreshed opkg feed cannot make another stale feed fresh.
mkdir "${TMP}/lists"
touch "${TMP}/lists/fresh" "${TMP}/lists/stale"
touch -t 202001010000 "${TMP}/lists/stale"
OPKG_BIN=${REPO}/tests/opkg/fakeopkg OPKG_LISTSDIR=${TMP}/lists OPKG_UPDATE=never
export OPKG_BIN OPKG_LISTSDIR OPKG_UPDATE
run extensions/opkg/opkg.sh
ok has '^status reviewhost\.opkg yellow '
ok has 'package lists are older'

# Partial df output with a failure still lists useful filesystems, but warns.
cat >"${TMP}/bin/df" <<'EOF'
#!/bin/sh
printf 'Device 1024-blocks Used Available Capacity Mounted\n/dev/a 100 10 90 10%% /\n'
printf 'df: remote filesystem: Input/output error\n' >&2
exit 1
EOF
chmod +x "${TMP}/bin/df"
DISK_DF=${TMP}/bin/df
export DISK_DF
run extensions/disk/disk.sh
ok has '^status reviewhost\.disk yellow '
ok has 'Input/output error'

# SMART errors and entirely skipped polls must not claim healthy disks.
printf 'SMARTCTL="%s"\nUSE_SUDO=no\nMMC_DEVICES=none\ndevice /dev/test\n' "${TMP}/bin/fail" >"${SMART_CFG}"
run extensions/smart/smart.sh
ok has '^status reviewhost\.smart yellow '
ok has '^&yellow /dev/test: cannot read SMART data$'
printf '#!/bin/sh\necho "Device is in STANDBY mode"\nexit 2\n' >"${TMP}/bin/standby"
chmod +x "${TMP}/bin/standby"
sed "s|${TMP}/bin/fail|${TMP}/bin/standby|" "${SMART_CFG}" >"${TMP}/smart-new"
mv "${TMP}/smart-new" "${SMART_CFG}"
run extensions/smart/smart.sh
ok has '^status reviewhost\.smart clear '
ok has 'No usable disk health measurements'

# Data-only send failures must also propagate after a successful status.
cat >"${TMP}/bin/data-fail" <<'EOF'
#!/bin/sh
case "${2}" in data\ *) exit 1 ;; esac
exit 0
EOF
chmod +x "${TMP}/bin/data-fail"
XYMON=${TMP}/bin/data-fail XYMSRV=127.0.0.1
export XYMON XYMSRV
run extensions/if_link/if_link.sh
ok exit_is 1
unset XYMON XYMSRV

# The measurement wrapper must atomically replace a state symlink while
# preserving the measured extension's own exit status.
XYMONHOME=${TMP}/home XYMONEXT_CFG=/dev/null XYMONEXT_STATEDIR=${TMP}/measure
export XYMONHOME XYMONEXT_CFG XYMONEXT_STATEDIR
mkdir -p "${XYMONHOME}/ext" "${XYMONEXT_STATEDIR}"
printf '#!/bin/sh\nexit 7\n' >"${XYMONHOME}/ext/demo.sh"
chmod +x "${XYMONHOME}/ext/demo.sh"
ln -s "${VICTIM}" "${XYMONEXT_STATEDIR}/demo"
run extensions/xymonext/xymonext.sh demo
ok exit_is 7
ok grep -qx 'preserve me' "${VICTIM}"
ok test ! -L "${XYMONEXT_STATEDIR}/demo"

# Standalone names are used for both executable paths and log paths.
XYMONHOME=${TMP}/home STANDALONE_CFG=/dev/null XYMONEXT_ENABLE=no
export XYMONHOME STANDALONE_CFG XYMONEXT_ENABLE
mkdir -p "${XYMONHOME}/ext"
cat >"${XYMONHOME}/escape.sh" <<'EOF'
#!/bin/sh
printf 'executed\n' >"${XYMONHOME}/escaped"
EOF
chmod +x "${XYMONHOME}/escape.sh"
# shellcheck disable=SC2086 # Selected shell may be multiword.
${TESTSH} "${REPO}/standalone/xymon-run.sh" -n ../escape >"${TMP}/out" 2>"${TMP}/err"
rc=$?
ok exit_is 1
ok test ! -e "${XYMONHOME}/escaped"
# shellcheck disable=SC2086
${TESTSH} "${REPO}/standalone/xymon-send.sh" '   ' message >"${TMP}/out" 2>"${TMP}/err"
rc=$?
ok exit_is 2

# OpenBSD nc requires -N to shut down the writing side at stdin EOF.
cat >"${TMP}/bin/nc" <<'EOF'
#!/bin/sh
case "${1:-}" in -h) printf '%s\n' 'nc [-N] [-w timeout] destination port'; exit 1 ;; esac
[ "${1:-}" = -N ] || exit 99
cat >"${NC_MESSAGE}"
EOF
chmod +x "${TMP}/bin/nc"
PATH=${TMP}/bin:${PATH} NC_MESSAGE=${TMP}/sent
export PATH NC_MESSAGE
# shellcheck disable=SC2086
${TESTSH} "${REPO}/standalone/xymon-send.sh" localhost 'complete message' >"${TMP}/out" 2>"${TMP}/err"
rc=$?
ok exit_is 0
ok grep -qx 'complete message' "${NC_MESSAGE}"
exit "${FAIL}"
