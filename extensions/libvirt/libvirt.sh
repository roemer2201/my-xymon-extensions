#!/bin/sh
#
# Report QEMU/KVM guest states and performance metrics to Xymon.
#
# Program flow:
#   1. Load the list of guests that must be running and the query timeout.
#   2. Read the numeric states of all guests over a read-only connection.
#   3. Compare states with the required guest list and send one status.
#   4. Compare counters with the last snapshot and send RRD updates.
#
# Usage: libvirt.sh [-h|--help]
# Version: 1.1.0 (2026-11-13)

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
Report CPU, QEMU RSS, network and disk I/O for running guests.
Print the status and any RRD updates to stdout when the Xymon sender is unset.

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

# Send a complete message via stdin, including large VM lists.
send_message() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "${XYMON}" "${XYMSRV}" @ < "$1"
    else
        cat "$1"
    fi
}

# send_report COLOR SUMMARY [FILE] formats the libvirt status message.
send_report() {
    {
        printf 'status %s.libvirt %s %s - %s\n' "${MACHINE}" "$1" "$(date)" "$2"
        if [ "$#" -eq 3 ]; then
            printf '\n'
            cat "$3"
        fi
    } > "${WORKDIR}/message" || return 1
    send_message "${WORKDIR}/message"
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
        domstats --state --raw --cpu-total --balloon --interface --block \
        </dev/null >"${WORKDIR}/stats" 2>"${WORKDIR}/error"; then
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
    /^  (cpu|balloon|net|block)\.[[:alnum:]_.-]+=/ && name != "" { next }
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
    send_report "${report%% *}" "${report#* }" "${WORKDIR}/details" || exit 1
else
    send_report red "Unexpected output from virsh domstats"
    exit "$?"
fi

# Use an atomic, private snapshot in Xymon's temporary directory. The Linux
# boot ID prevents rate calculation across a hypervisor reboot.
state_file="${XYMONTMP}/libvirt.${MACHINE}.state"
previous="${state_file}"
[ -r "${previous}" ] || previous=/dev/null
boot_id=unknown
if [ -r /proc/sys/kernel/random/boot_id ]; then
    IFS= read -r boot_id < /proc/sys/kernel/random/boot_id || boot_id=unknown
fi
now=$(date +%s) || exit 1
(
    umask 077
    {
        printf '%s %s\n' "${now}" "${boot_id}"
        cat "${WORKDIR}/stats"
    } > "${WORKDIR}/snapshot"
) || exit 1

# Read only the fields needed for graphs. Derive rates per device before
# summing, so a reset or topology change cannot appear as a traffic spike.
if ! awk '
    BEGIN {
        for (i = 1; i < 256; i++) byte[sprintf("%c", i)] = i
    }
    FNR == 1 {
        poll = FILENAME == ARGV[1] ? "old" : "new"
        stamp[poll] = $1
        boot[poll] = $2
        next
    }
    /^Domain: / {
        name = substr($0, 10, length($0) - 10)
        guests[name] = 1
        next
    }
    /^  (state\.state|cpu\.time|balloon\.rss|net\.count|block\.count|net\.[0-9]+\.(name|rx\.bytes|tx\.bytes)|block\.[0-9]+\.(name|path|rd\.bytes|wr\.bytes))=/ {
        separator = index($0, "=")
        values[poll, name, substr($0, 3, separator - 3)] = substr($0, separator + 1)
    }
    # Keep familiar VM names in the legend and encode other bytes injectively.
    function graph_id(name,    result, pos, ch) {
        for (pos = 1; pos <= length(name); pos++) {
            ch = substr(name, pos, 1)
            result = result (ch ~ /^[A-Za-z0-9-]$/ ? ch : sprintf("_%02x", byte[ch]))
        }
        return result
    }
    function number(poll, name, key) {
        return ((poll, name, key) in values) && values[poll, name, key] ~ /^[0-9]+$/
    }
    function running(poll, name) {
        return ((poll, name, "state.state") in values) && values[poll, name, "state.state"] == 1
    }
    function gauge(poll, name, key) {
        if (!running(poll, name) || !number(poll, name, key)) return "U"
        return values[poll, name, key]
    }
    function devices(poll, name, group, field,    count, n, key) {
        if (!running(poll, name) || !number(poll, name, group ".count")) return 0
        count = values[poll, name, group ".count"] + 0
        for (n = 0; n < count; n++) {
            key = group "." n
            if (!number(poll, name, key "." field) || values[poll, name, key ".name"] == "") return 0
        }
        return count
    }
    function device_rate(name, id, metric, group, field, scale,    count, old_count, i, key, delta, total) {
        count = devices("new", name, group, field)
        old_count = devices("old", name, group, field)
        if (!count && !old_count) return
        if (!interval_ok || !count || count != old_count) { emit(id, metric, "U"); return }
        for (i = 0; i < count; i++) {
            key = group "." i
            delta = values["new", name, key "." field] - values["old", name, key "." field]
            if (delta < 0 || values["new", name, key ".name"] != values["old", name, key ".name"] ||
                (group == "block" && values["new", name, key ".path"] != values["old", name, key ".path"])) {
                emit(id, metric, "U")
                return
            }
            total += delta
        }
        emit(id, metric, sprintf("%.3f", total * scale / elapsed))
    }
    function emit(id, metric, value) {
        printf "[libvirt,%s_%s.rrd]\nDS:lambda:GAUGE:600:0:U %s\n", id, metric, value
    }
    END {
        elapsed = stamp["new"] - stamp["old"]
        interval_ok = boot["new"] == boot["old"] && elapsed > 0 && elapsed < 600
        for (name in guests) {
            id = graph_id(name)
            if (length(id) > 200) continue
            current = gauge("new", name, "balloon.rss")
            previous = gauge("old", name, "balloon.rss")
            if (current != "U" || previous != "U")
                emit(id, "rss", current == "U" ? "U" : sprintf("%.3f", current / 1024))
            current = gauge("new", name, "cpu.time")
            previous = gauge("old", name, "cpu.time")
            if (current != "U" || previous != "U") {
                rate = "U"
                if (interval_ok && current != "U" && previous != "U" && current + 0 >= previous + 0)
                    rate = sprintf("%.3f", (current - previous) / elapsed / 10000000)
                emit(id, "cpu", rate)
            }
            device_rate(name, id, "rx", "net", "rx.bytes", 0.008)
            device_rate(name, id, "tx", "net", "tx.bytes", 0.008)
            device_rate(name, id, "read", "block", "rd.bytes", 1 / 1048576)
            device_rate(name, id, "write", "block", "wr.bytes", 1 / 1048576)
        }
    }' "${previous}" "${WORKDIR}/snapshot" > "${WORKDIR}/metrics"; then
    printf '%s\n' 'Cannot calculate libvirt metrics' >&2
    exit 1
fi

if [ -s "${WORKDIR}/metrics" ]; then
    {
        printf 'data %s.trends\n' "${MACHINE}"
        cat "${WORKDIR}/metrics"
    } > "${WORKDIR}/message" || exit 1
    send_message "${WORKDIR}/message" || exit 1
fi
mv -f "${WORKDIR}/snapshot" "${state_file}"
