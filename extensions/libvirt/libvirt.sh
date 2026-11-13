#!/bin/sh
#
# Report QEMU/KVM guest states in the Xymon libvirt column.
#
# Program flow:
#   1. Load the list of guests that must be running and the query timeout.
#   2. Read the numeric states of all guests over a read-only connection.
#   3. Compare the states with the required guest list and send one status.
#
# Usage: libvirt.sh [-h|--help]
# Version: 1.0.0 (2026-11-13)

set -u

case "${1:-}" in
    -h|--help)
        if [ "$#" -ne 1 ]; then
            printf '%s\n' 'Usage: libvirt.sh [-h|--help]' >&2
            exit 2
        fi
        cat <<'HELP'
Usage: libvirt.sh [-h|--help]

Check local QEMU/KVM guests through the read-only libvirt system socket.
Print the status to stdout when the Xymon sender is unset.

  LIBVIRT_CFG       Config file (default: $XYMONHOME/etc/my-xymon-extensions/libvirt.cfg)
  LIBVIRT_REQUIRED  Space-separated guest names that must be running (default: empty)
  LIBVIRT_TIMEOUT   Query timeout in seconds (default: 10)

Exported settings override values from the config file.
Example: LIBVIRT_REQUIRED="vm01 vm02" libvirt.sh
HELP
        exit 0
        ;;
esac
if [ "$#" -ne 0 ]; then
    printf '%s\n' 'Usage: libvirt.sh [-h|--help]' >&2
    exit 2
fi

# Keep the virsh record format predictable and use Xymon's paths when set.
LC_ALL=C
export LC_ALL
XYMONHOME="${XYMONHOME:-${XYMONCLIENTHOME:-}}"
XYMONTMP="${XYMONTMP:-${TMPDIR:-/tmp}}"
MACHINE="${MACHINE:-$(uname -n | tr '.' ',')}"

# send_report COLOR SUMMARY [FILE] uses stdin for potentially long VM lists.
send_report() {
    {
        printf 'status %s.libvirt %s %s - %s\n' "${MACHINE}" "$1" "$(date)" "$2"
        if [ "$#" -eq 3 ]; then
            printf '\n'
            cat "$3"
        fi
    } > "${WORKDIR}/message" || return 1
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "${XYMON}" "${XYMSRV}" @ < "${WORKDIR}/message"
    else
        cat "${WORKDIR}/message"
    fi
}

# Keep query errors separate from successful output, even on a partial failure.
WORKDIR=$(mktemp -d "${XYMONTMP}/libvirt.XXXXXX") || exit 1
trap 'rm -rf "${WORKDIR}"' EXIT
trap 'exit 1' INT TERM

# Preserve explicit environment overrides, including an empty required list.
required_override="${LIBVIRT_REQUIRED-}"
required_set="${LIBVIRT_REQUIRED+x}"
timeout_override="${LIBVIRT_TIMEOUT-}"
timeout_set="${LIBVIRT_TIMEOUT+x}"
CFGFILE="${LIBVIRT_CFG:-}"
if [ -z "${CFGFILE}" ] && [ -n "${XYMONHOME}" ]; then
    CFGFILE="${XYMONHOME}/etc/my-xymon-extensions/libvirt.cfg"
fi
if [ -n "${LIBVIRT_CFG:-}" ] || [ -e "${CFGFILE}" ]; then
    if [ ! -f "${CFGFILE}" ] || [ ! -r "${CFGFILE}" ]; then
        send_report red "Cannot read libvirt config file"
        printf 'Cannot read config file: %s\n' "${CFGFILE}" >&2
        exit 1
    fi
    case "${CFGFILE}" in
        */*) ;;
        *) CFGFILE="./${CFGFILE}" ;;
    esac
    # shellcheck disable=SC1090  # Installed or explicitly selected shell config.
    . "${CFGFILE}"
fi
if [ -n "${required_set}" ]; then LIBVIRT_REQUIRED="${required_override}"; fi
if [ -n "${timeout_set}" ]; then LIBVIRT_TIMEOUT="${timeout_override}"; fi
LIBVIRT_REQUIRED="${LIBVIRT_REQUIRED:-}"
LIBVIRT_TIMEOUT="${LIBVIRT_TIMEOUT-10}"
export LIBVIRT_REQUIRED

# A missing tool makes the check inapplicable. A failed query is an error.
for tool in virsh timeout; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        send_report clear "Required tool not found: ${tool}"
        exit "$?"
    fi
done
case "${LIBVIRT_TIMEOUT}" in
    ''|*[!0-9]*) valid_timeout=no ;;
    *) valid_timeout=yes ;;
esac
if [ "${valid_timeout}" = no ] || ! [ "${LIBVIRT_TIMEOUT}" -gt 0 ] 2>/dev/null; then
    send_report red "LIBVIRT_TIMEOUT must be a positive integer"
    exit "$?"
fi

if timeout -k 2 "${LIBVIRT_TIMEOUT}" virsh --readonly --connect qemu:///system \
        domstats --state --raw </dev/null >"${WORKDIR}/stats" 2>"${WORKDIR}/error"; then
    :
else
    rc=$?
    case "${rc}" in
        124|137|143) summary="libvirt query timed out after ${LIBVIRT_TIMEOUT}s" ;;
        *) summary="libvirt query failed (exit ${rc})" ;;
    esac
    sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        "${WORKDIR}/error" > "${WORKDIR}/details" || exit 1
    send_report red "${summary}" "${WORKDIR}/details"
    exit "$?"
fi

# Parse one snapshot. Keep libvirt's order, match required names literally,
# and escape VM names before showing them on the Xymon status page.
if awk '
    function html(text) {
        gsub(/&/, "\\&amp;", text)
        gsub(/</, "\\&lt;", text)
        gsub(/>/, "\\&gt;", text)
        return text
    }
    BEGIN {
        split("no state,running,blocked,paused,shutting down,shut off,crashed,suspended", label, ",")
        count = split(ENVIRON["LIBVIRT_REQUIRED"], names, /[[:space:]]+/)
        for (i = 1; i <= count; i++)
            if (names[i] != "" && !(names[i] in required)) {
                required[names[i]] = 1
                expected[++total] = names[i]
            }
        quote = sprintf("%c", 39)
    }
    /^[[:space:]]*$/ { next }
    index($0, "Domain: " quote) == 1 && substr($0, length($0)) == quote && length($0) > 10 {
        name = substr($0, 10, length($0) - 10)
        if (name in seen) { invalid = 1; next }
        seen[name] = 1
        guests[++guest_count] = name
        next
    }
    /^[[:space:]]+state\.state=[0-9]+$/ && name != "" && !(name in state) {
        sub(/^[[:space:]]+state\.state=/, "")
        state[name] = $0 + 0
        next
    }
    /^[[:space:]]+state\.reason=[0-9]+$/ && name != "" { next }
    { invalid = 1 }
    END {
        if (invalid) exit 1
        for (i = 1; i <= total; i++)
            if (expected[i] in state && state[expected[i]] == 1) running++
        color = running + 0 == total + 0 ? "green" : "red"
        if (total)
            printf "%s %d/%d required VMs running; %d VMs found\n", color, running, total, guest_count
        else
            printf "green %d VMs found; no required VMs configured\n", guest_count
        for (i = 1; i <= guest_count; i++) {
            name = guests[i]
            if (!(name in state)) status = "state unavailable"
            else if ((state[name] + 1) in label) status = label[state[name] + 1]
            else status = "unknown state (" state[name] ")"
            if (!(name in required)) mark = "optional"
            else if (state[name] == 1) mark = "&green required"
            else mark = "&red required"
            printf "%s: %s (%s)\n", html(name), status, mark
        }
        for (i = 1; i <= total; i++)
            if (!(expected[i] in seen))
                printf "%s: missing (&red required)\n", html(expected[i])
    }' "${WORKDIR}/stats" > "${WORKDIR}/report"; then
    IFS= read -r report < "${WORKDIR}/report" || exit 1
    sed '1d' "${WORKDIR}/report" > "${WORKDIR}/details" || exit 1
    send_report "${report%% *}" "${report#* }" "${WORKDIR}/details"
else
    send_report red "Unexpected output from virsh domstats"
fi
