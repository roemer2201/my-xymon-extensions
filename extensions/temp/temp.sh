#!/bin/sh
#
# temp.sh -- Xymon client extension: hardware temperature sensors
#
# Reads every temperature sensor the Linux kernel exposes under
# /sys/class/hwmon (fallback: /sys/class/thermal) and reports one
# "temp" status column: each sensor is checked against shared
# thresholds, the worst sensor color wins. The status text carries
# "NAME : VALUE" lines (hidden in an HTML comment) for NCV graphing
# on the Xymon server - see README.md for the server-side setup.
#
# Written for clientless hosts driven by the standalone runner, e.g.
# the Turris Omnia (armada_thermal = CPU/SoC, several mv88e6xxx
# switch sensors), but works on any Linux. Platforms without a
# hwmon/thermal sysfs report "clear".
#
# Configuration: environment variables and/or $XYMONHOME/etc/temp.cfg
# (see the shipped temp.cfg; the config file wins over the environment).

set -u

# ----------------------------------------------------------------------
# Xymon environment (xymonlaunch or standalone/xymon-run.sh provide
# these; fallbacks allow running the script manually for testing:
# output then goes to stdout)
# ----------------------------------------------------------------------
XYMONHOME="${XYMONHOME:-${XYMONCLIENTHOME:-}}"
XYMONTMP="${XYMONTMP:-${TMPDIR:-/tmp}}"
MACHINE="${MACHINE:-$(uname -n | tr '.' ',')}"

# ----------------------------------------------------------------------
# Defaults -- every value can be set in the environment or in temp.cfg
# ----------------------------------------------------------------------
TEMP_COLUMN="${TEMP_COLUMN:-temp}"  # Xymon column name
TEMP_WARN="${TEMP_WARN:-80}"        # yellow at/above, degrees Celsius
TEMP_CRIT="${TEMP_CRIT:-90}"        # red at/above, degrees Celsius
TEMP_HWMON_DIR="${TEMP_HWMON_DIR:-/sys/class/hwmon}"
TEMP_THERMAL_DIR="${TEMP_THERMAL_DIR:-/sys/class/thermal}"

# Plausibility bounds: some sensors (e.g. mt7915/mt76 wifi radio hwmon)
# report an uncalibrated raw value for a while after boot, before the
# driver's thermal calibration completes. Readings outside this range
# are ignored rather than scored, since they are not real temperatures.
TEMP_PLAUSIBLE_MIN="${TEMP_PLAUSIBLE_MIN:--40}"
TEMP_PLAUSIBLE_MAX="${TEMP_PLAUSIBLE_MAX:-150}"

CFGFILE="${TEMP_CFG:-${XYMONHOME:+${XYMONHOME}/etc/temp.cfg}}"
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi
COLUMN="$TEMP_COLUMN"

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# worst <color1> <color2> -> prints the more severe of the two
worst() {
    for w_c in red yellow green clear; do
        if [ "$1" = "$w_c" ] || [ "$2" = "$w_c" ]; then
            echo "$w_c"
            return
        fi
    done
    echo green
}

# ge <a> <b> -> true if a >= b (values may be fractional; BusyBox sh
# has no float arithmetic, so compare in awk)
ge() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

# color_hi <value> <warn> <crit>  (higher is worse)
color_hi() {
    if ge "$1" "$3"; then echo red
    elif ge "$1" "$2"; then echo yellow
    else echo green
    fi
}

# plausible <value> -> true if within TEMP_PLAUSIBLE_MIN..TEMP_PLAUSIBLE_MAX
plausible() {
    awk -v v="$1" -v lo="$TEMP_PLAUSIBLE_MIN" -v hi="$TEMP_PLAUSIBLE_MAX" \
        'BEGIN { exit !(v + 0 >= lo + 0 && v + 0 <= hi + 0) }'
}

# sanitize <text> -> lowercase, [a-z0-9_] only, squeezed and trimmed
sanitize() {
    s_out=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | tr -s '_')
    s_out=${s_out#_}
    printf '%s' "${s_out%_}"
}

# send_report <color> <body-file>
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - temperature is $1

$(cat "$2")"
    else
        # No Xymon environment: print the message (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - temperature is $1"
        echo ""
        cat "$2"
    fi
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

WORKDIR=$(mktemp -d "${XYMONTMP}/temp.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

STATUS="$WORKDIR/status"
NCV="$WORKDIR/ncv"
: > "$STATUS"
: > "$NCV"

OVERALL=green
NSENSORS=0
SEEN=" "

# add_sensor <name> <value-in-millidegrees-celsius>
add_sensor() {
    case "${2:-}" in
        ''|-|*[!0-9-]*) return ;;   # sensor unreadable or non-numeric
    esac
    # Make the sensor name unique: identical chips can appear several
    # times (e.g. the mv88e6xxx switch sensors on the Turris Omnia).
    a_name=$1
    a_i=2
    while :; do
        case "$SEEN" in
            *" $a_name "*) a_name="${1}_$a_i"; a_i=$((a_i + 1)) ;;
            *) break ;;
        esac
    done
    SEEN="$SEEN$a_name "

    a_c=$(awk -v m="$2" 'BEGIN { printf "%.1f", m / 1000 }')
    NSENSORS=$((NSENSORS + 1))

    if ! plausible "$a_c"; then
        # Uncalibrated/garbage reading (e.g. mt7915 wifi radio hwmon
        # shortly after boot) - do not score it, and keep it out of
        # the NCV data so it cannot spike the RRD graph.
        OVERALL=$(worst "$OVERALL" clear)
        printf '&clear %s = %s C (ignored: outside plausible range %s..%s C, sensor still initializing?)\n' \
            "$a_name" "$a_c" "$TEMP_PLAUSIBLE_MIN" "$TEMP_PLAUSIBLE_MAX" >> "$STATUS"
        return
    fi

    a_color=$(color_hi "$a_c" "$TEMP_WARN" "$TEMP_CRIT")
    OVERALL=$(worst "$OVERALL" "$a_color")
    # "=" on purpose: a "name : value" line here would be picked up
    # by the server's NCV parser (those lines live in the comment)
    printf '&%s %s = %s C\n' "$a_color" "$a_name" "$a_c" >> "$STATUS"
    printf '%s : %s\n' "$a_name" "$a_c" >> "$NCV"
}

# hwmon: one directory per chip; the chip name is in "name", each
# sensor is a tempN_input file (millidegrees Celsius) with an optional
# tempN_label. Older kernels put the files one level down in device/.
for hw in "$TEMP_HWMON_DIR"/hwmon*; do
    [ -d "$hw" ] || continue
    chip=$(cat "$hw/name" 2>/dev/null)
    [ -n "$chip" ] || chip=$(basename "$hw")
    for f in "$hw"/temp*_input "$hw"/device/temp*_input; do
        [ -r "$f" ] || continue
        base=$(basename "$f")
        base=${base%_input}
        label=$(cat "${f%_input}_label" 2>/dev/null)
        [ -n "$label" ] || label=$base
        add_sensor "$(sanitize "${chip}_${label}")" "$(cat "$f" 2>/dev/null)"
    done
done

# Fallback: thermal zones (some SoCs expose no hwmon device)
if [ "$NSENSORS" -eq 0 ]; then
    for tz in "$TEMP_THERMAL_DIR"/thermal_zone*; do
        [ -r "$tz/temp" ] || continue
        ztype=$(cat "$tz/type" 2>/dev/null)
        [ -n "$ztype" ] || ztype=$(basename "$tz")
        add_sensor "$(sanitize "$ztype")" "$(cat "$tz/temp" 2>/dev/null)"
    done
fi

if [ "$NSENSORS" -eq 0 ]; then
    {
        printf 'No temperature sensors found (nothing readable under\n'
        printf '%s or %s).\n' "$TEMP_HWMON_DIR" "$TEMP_THERMAL_DIR"
        case "$(uname -s)" in
            Linux) printf 'The kernel exposes no hwmon/thermal sensors on this host.\n' ;;
            *)     printf 'This interface exists on Linux only - test not applicable here.\n' ;;
        esac
    } >> "$STATUS"
    send_report clear "$STATUS"
    exit 0
fi

{
    cat "$STATUS"
    printf '\nChecked %s sensor(s). Thresholds per sensor: yellow >= %s C, red >= %s C\n' \
        "$NSENSORS" "$TEMP_WARN" "$TEMP_CRIT"
    printf '\n<!--\n'
    cat "$NCV"
    printf '%s\n' '-->'
} > "$WORKDIR/final"

send_report "$OVERALL" "$WORKDIR/final"
exit 0
