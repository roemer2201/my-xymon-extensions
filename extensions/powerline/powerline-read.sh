#!/bin/sh
# Restrict privileged PLC access to three fixed, read-only requests.
# Program flow: validate operation/interface/MACs, then exec a bounded tool.
# Usage: powerline-read.sh topology eth0
#        powerline-read.sh rates eth0 DEVICE
#        powerline-read.sh stats eth0 DEVICE PEER
# Security exception to env-config conventions: sudo arguments ONLY; never
# accept executable paths, shell fragments, or option overrides from env.
set -u
PATH=/usr/bin:/bin
export PATH
LC_ALL=C
export LC_ALL

# Help is available without root; the helper never writes PLC settings.
case "${1:-}" in
    -h|--help)
        printf '%s\n' 'Usage: powerline-read.sh topology IFACE | rates IFACE DEVICE | stats IFACE DEVICE PEER' \
            'DEVICE and PEER are PLC MAC addresses (not BDA). No environment overrides.' \
            'Only fixed read-only commands are permitted; each has a 15-second timeout.'
        exit 0 ;;
esac

# Reject extra arguments, option injection and malformed Ethernet addresses.
bad() { printf '%s\n' "powerline-read: ${*}" >&2; exit 2; }
mac() {
    case "${1}" in
        [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]) return 0 ;;
        *) bad 'Expected a colon-separated PLC MAC address' ;;
    esac
}
[ "${#}" -ge 2 ] || bad 'Missing operation/interface; see --help'
case "${2}" in ''|-*|*[!a-zA-Z0-9_.:-]*) bad 'Invalid interface' ;; esac
[ "${#2}" -le 15 ] || bad 'Interface name too long'
case "${1}" in
    topology)
        [ "${#}" -eq 2 ] || bad 'topology takes only IFACE'
        exec /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/timeout -k 2 15 /usr/bin/plcstat -t -i "${2}" ;;
    rates)
        [ "${#}" -eq 3 ] || bad 'rates takes IFACE DEVICE'
        mac "${3}"
        exec /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/timeout -k 2 15 /usr/bin/plcrate -n -i "${2}" "${3}" ;;
    stats)
        [ "${#}" -eq 4 ] || bad 'stats takes IFACE DEVICE PEER'
        mac "${3}"; mac "${4}"
        exec /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/timeout -k 2 15 /usr/bin/plcstat -i "${2}" -d both -s 0xF8 -p "${4}" "${3}" ;;
    *) bad 'Unknown operation; see --help' ;;
esac
