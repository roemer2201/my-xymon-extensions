#!/bin/sh
#
# smart.sh -- Xymon client extension: S.M.A.R.T. disk health monitoring
#
# Collects SMART data for all local disks (SATA/ATA, NVMe, basic SAS)
# using smartctl(8), maps the vendor-specific attributes to a small set
# of canonical metrics and reports:
#
#   - one "smart" status column (green/yellow/red/clear), and
#   - a "data" message with "NAME : VALUE" lines for RRD graphing
#     (split-NCV on the Xymon server, see server/README.md).
#
# Runs unmodified on Ubuntu, Rocky Linux (EL) and FreeBSD.
# Configuration: $XYMONHOME/etc/smart.cfg (see the shipped smart.cfg).

set -u

COLUMN="smart"

# ----------------------------------------------------------------------
# Xymon environment (xymonlaunch provides these; fallbacks allow running
# the script manually for testing: output then goes to stdout)
# ----------------------------------------------------------------------
XYMONHOME="${XYMONHOME:-${XYMONCLIENTHOME:-}}"
XYMONTMP="${XYMONTMP:-${TMPDIR:-/tmp}}"
MACHINE="${MACHINE:-$(uname -n | tr '.' ',')}"

# ----------------------------------------------------------------------
# Defaults -- every value can be overridden in smart.cfg
# ----------------------------------------------------------------------
SMARTCTL=""            # path to smartctl; empty = search $PATH
USE_SUDO="auto"        # auto | yes | no
NOSPINUP="yes"         # yes = do not wake up disks in standby
EXCLUDE=""             # ERE of devices to skip, e.g. '^/dev/da[5-9]'

# Thresholds; setting a value to 0 disables that check.
TEMP_WARN=55       TEMP_CRIT=65       # degrees Celsius
WEAR_WARN=80       WEAR_CRIT=90       # percent of rated life used
REALLOC_WARN=1     REALLOC_CRIT=50    # reallocated sectors
PENDING_WARN=1     PENDING_CRIT=10    # current pending sectors
UNCORR_WARN=1      UNCORR_CRIT=10     # offline uncorrectable sectors
CRC_WARN=1         CRC_CRIT=100       # interface CRC errors (cabling!)
MEDIAERR_WARN=1    MEDIAERR_CRIT=10   # NVMe media/data integrity errors
SPARE_WARN=50      SPARE_CRIT=10      # NVMe available spare, percent LEFT

DEVLIST=""             # filled by device() from smart.cfg, else auto-scan
USERMAP=""             # filled by attrmap() from smart.cfg

# device <path> [smartctl-options] [alias]
# Explicitly declare a device to check (disables auto-discovery).
# shellcheck disable=SC2317  # called indirectly from the sourced config
device() {
    DEVLIST="${DEVLIST}${1}|${2:-}|${3:-}
"
}

# attrmap <model-glob> <attr-id-or-name-glob> <metric|none> [raw|norm|invnorm|gib|lba|mib32]
# Map an ATA SMART attribute to a canonical metric, overriding the
# built-in map below. Matched before the built-in map, first hit wins.
# shellcheck disable=SC2317  # called indirectly from the sourced config
attrmap() {
    USERMAP="${USERMAP}${1}|${2}|${3}|${4:-raw}
"
}

CFGFILE="${SMART_CFG:-${XYMONHOME:+${XYMONHOME}/etc/smart.cfg}}"
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi

# ----------------------------------------------------------------------
# Built-in attribute map: <model-glob>|<id-or-name-glob>|<metric>|<source>
#
# smartmontools' drive database already translates most vendor-specific
# attribute IDs into meaningful names, so matching on the *name* gives
# us vendor normalization for free. Drives that still deviate are
# handled with attrmap overrides in smart.cfg (matched first).
#
# source: raw     = first number of the RAW_VALUE column
#         norm    = normalized VALUE column
#         invnorm = 100 - VALUE (for "percent life left" style values)
#         gib     = RAW_VALUE already in GiB
#         lba     = RAW_VALUE in 512-byte sectors, converted to GiB
#         mib32   = RAW_VALUE in 32-MiB units, converted to GiB
# ----------------------------------------------------------------------
DEFAULTMAP="\
*|Temperature_Celsius|temp|raw
*|Temperature_Cel*|temp|raw
*|Airflow_Temperature_Cel|temp|raw
*|Drive_Temperature|temp|raw
*|Reallocated_Sector_Ct|realloc|raw
*|Retired_Block_Count|realloc|raw
*|Current_Pending_Sector|pending|raw
*|Offline_Uncorrectable|uncorr|raw
*|UDMA_CRC_Error_Count|crc|raw
*|CRC_Error_Count|crc|raw
*|SATA_CRC_Error_Count|crc|raw
*|Power_On_Hours|hours|raw
*|Power_Cycle_Count|cycles|raw
*|Wear_Leveling_Count|wear|invnorm
*|Media_Wearout_Indicator|wear|invnorm
*|SSD_Life_Left|wear|invnorm
*|Percent_Lifetime_Remain|wear|invnorm
*|Percent_Life_Remaining|wear|invnorm
*|Percentage_Used|wear|raw
*|Perc_Rated_Life_Used|wear|raw
*|Host_Writes_GiB|written|gib
*|Lifetime_Writes_GiB|written|gib
*|Host_Writes_32MiB|written|mib32
*|Total_LBAs_Written|written|lba
*|Host_Reads_GiB|read|gib
*|Lifetime_Reads_GiB|read|gib
*|Host_Reads_32MiB|read|mib32
*|Total_LBAs_Read|read|lba"

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# resolve_metric <model> <attr-id> <attr-name>
# Prints "metric source" for the first matching map entry (user map
# first, then built-in map); prints nothing for unmapped attributes.
resolve_metric() {
    printf '%s\n%s\n' "$USERMAP" "$DEFAULTMAP" | \
    while IFS='|' read -r r_mglob r_aglob r_metric r_src; do
        [ -n "$r_metric" ] || continue
        # shellcheck disable=SC2254  # globs must stay unquoted here
        case "$1" in
            $r_mglob) ;;
            *) continue ;;
        esac
        # shellcheck disable=SC2254
        case "$2" in
            $r_aglob) ;;
            *)  case "$3" in
                    $r_aglob) ;;
                    *) continue ;;
                esac ;;
        esac
        printf '%s %s\n' "$r_metric" "$r_src"
        break
    done
}

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

# check_hi <value> <warn> <crit>  (higher is worse)
check_hi() {
    if [ "$3" -gt 0 ] && [ "$1" -ge "$3" ]; then echo red
    elif [ "$2" -gt 0 ] && [ "$1" -ge "$2" ]; then echo yellow
    else echo green
    fi
}

# check_lo <value> <warn> <crit>  (lower is worse)
check_lo() {
    if [ "$3" -gt 0 ] && [ "$1" -le "$3" ]; then echo red
    elif [ "$2" -gt 0 ] && [ "$1" -le "$2" ]; then echo yellow
    else echo green
    fi
}

# metric_color <metric> <value>
metric_color() {
    case "$1" in
        temp)     check_hi "$2" "$TEMP_WARN" "$TEMP_CRIT" ;;
        wear)     check_hi "$2" "$WEAR_WARN" "$WEAR_CRIT" ;;
        realloc)  check_hi "$2" "$REALLOC_WARN" "$REALLOC_CRIT" ;;
        pending)  check_hi "$2" "$PENDING_WARN" "$PENDING_CRIT" ;;
        uncorr)   check_hi "$2" "$UNCORR_WARN" "$UNCORR_CRIT" ;;
        crc)      check_hi "$2" "$CRC_WARN" "$CRC_CRIT" ;;
        mediaerr) check_hi "$2" "$MEDIAERR_WARN" "$MEDIAERR_CRIT" ;;
        spare)    check_lo "$2" "$SPARE_WARN" "$SPARE_CRIT" ;;
        *)        echo green ;;
    esac
}

# send_report <color> <status-body-file> [data-body-file]
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - SMART is $1

$(cat "$2")"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            "$XYMON" "$XYMSRV" "data ${MACHINE}.${COLUMN}
$(cat "$3")"
        fi
    else
        # No Xymon environment: print the messages (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - SMART is $1"
        echo ""
        cat "$2"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            echo ""
            echo "data ${MACHINE}.${COLUMN}"
            cat "$3"
        fi
    fi
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

WORKDIR=$(mktemp -d "${XYMONTMP}/smart.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

STATUS="$WORKDIR/status"
DATA="$WORKDIR/data"
NOTES="$WORKDIR/notes"
: > "$STATUS"
: > "$DATA"
: > "$NOTES"

clear_report() {
    printf '%s\n' "$1" > "$STATUS"
    send_report clear "$STATUS"
    exit 0
}

# --- locate smartctl ---------------------------------------------------
if [ -z "$SMARTCTL" ]; then
    SMARTCTL=$(command -v smartctl || true)
fi
if [ -z "$SMARTCTL" ] || [ ! -x "$SMARTCTL" ]; then
    clear_report "smartctl not found - install smartmontools to enable this test"
fi

# --- privileges ---------------------------------------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    case "$USE_SUDO" in
        no)
            ;;  # try without sudo (works in test setups / with caps)
        yes)
            SUDO="sudo -n"
            ;;
        *)
            if sudo -n "$SMARTCTL" --version >/dev/null 2>&1; then
                SUDO="sudo -n"
            else
                clear_report "not running as root and passwordless sudo for smartctl is not configured (see sudoers.example)"
            fi
            ;;
    esac
fi

smartrun() {
    # shellcheck disable=SC2086  # $SUDO is intentionally word-split
    $SUDO "$SMARTCTL" "$@" </dev/null 2>&1
}

# --- device discovery ---------------------------------------------------
if [ -z "$DEVLIST" ]; then
    # Take only the device path from "smartctl --scan" and let smartctl
    # autodetect the type; exotic setups (RAID controllers, USB bridges)
    # are declared explicitly with device() in smart.cfg.
    smartrun --scan | sed -e 's/#.*//' | awk 'NF > 0 { print $1 "||" }' \
        > "$WORKDIR/devices"
else
    printf '%s' "$DEVLIST" > "$WORKDIR/devices"
fi

if [ -n "$EXCLUDE" ]; then
    grep -Ev "$EXCLUDE" "$WORKDIR/devices" > "$WORKDIR/devices.tmp" || true
    mv "$WORKDIR/devices.tmp" "$WORKDIR/devices"
fi

if [ ! -s "$WORKDIR/devices" ]; then
    clear_report "no SMART-capable devices found (smartctl --scan returned nothing)"
fi

# --- per-device checks --------------------------------------------------
OVERALL=green
NDEV=0

while IFS='|' read -r dev opts alias <&3; do
    [ -n "$dev" ] || continue
    NDEV=$((NDEV + 1))

    if [ -n "$alias" ]; then
        name=$alias
    else
        name=$(basename "$dev")
    fi
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')

    nsopt=""
    [ "$NOSPINUP" = "yes" ] && nsopt="-n standby"

    # shellcheck disable=SC2086  # $nsopt/$opts are intentionally word-split
    out=$(smartrun -i -H -A $nsopt $opts "$dev")

    case "$out" in
        *"Device is in STANDBY"*|*"Device is in SLEEP"*)
            printf '&clear %s: in standby, skipped (NOSPINUP=yes)\n\n' "$dev" >> "$STATUS"
            continue
            ;;
    esac

    if ! printf '%s\n' "$out" | grep -q "=== START OF"; then
        {
            printf '&clear %s: cannot read SMART data:\n' "$dev"
            printf '%s\n' "$out" | tail -n 2 | sed -e 's/^/    /'
            printf '\n'
        } >> "$STATUS"
        continue
    fi

    model=$(printf '%s\n' "$out" | sed -n -e 's/^Device Model: *//p' | head -n 1)
    [ -n "$model" ] || model=$(printf '%s\n' "$out" | sed -n -e 's/^Model Number: *//p' | head -n 1)
    [ -n "$model" ] || model=$(printf '%s\n' "$out" | sed -n -e 's/^Product: *//p' | head -n 1)
    [ -n "$model" ] || model="unknown model"

    health=$(printf '%s\n' "$out" | sed -n \
        -e 's/^SMART overall-health self-assessment test result: *//p' \
        -e 's/^SMART Health Status: *//p' | head -n 1)

    critwarn=""
    : > "$WORKDIR/metrics.raw"

    # ATA/SATA: attribute table lines look like
    # ID# ATTRIBUTE_NAME FLAG VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW
    printf '%s\n' "$out" | awk '
        $1 ~ /^[0-9]+$/ && $3 ~ /^0x/ && NF >= 10 {
            printf "%d %s %d %.0f\n", $1, $2, $4, $10
        }' > "$WORKDIR/attrs"

    if [ -s "$WORKDIR/attrs" ]; then
        while read -r a_id a_name a_value a_raw; do
            ms=$(resolve_metric "$model" "$a_id" "$a_name")
            [ -n "$ms" ] || continue
            m=${ms% *}
            src=${ms#* }
            [ "$m" = "none" ] && continue
            case "$src" in
                norm)    v=$a_value ;;
                invnorm) v=$((100 - a_value)); [ "$v" -lt 0 ] && v=0 ;;
                # totals can exceed 32-bit shell arithmetic - use awk
                lba)     v=$(awk -v r="$a_raw" 'BEGIN { printf "%.0f", r * 512 / 1073741824 }') ;;
                mib32)   v=$(awk -v r="$a_raw" 'BEGIN { printf "%.0f", r / 32 }') ;;
                *)       v=$a_raw ;;   # raw and gib
            esac
            printf '%s %s\n' "$m" "$v" >> "$WORKDIR/metrics.raw"
        done < "$WORKDIR/attrs"
    elif printf '%s\n' "$out" | grep -q "NVMe Log"; then
        # NVMe: SMART/Health Information log, already vendor-neutral
        printf '%s\n' "$out" | awk -F': *' '
            function num(s) { gsub(/[ ,%]/, "", s); return s + 0 }
            /^Temperature:/                     { printf "temp %.0f\n", num($2) }
            /^Percentage Used:/                 { printf "wear %.0f\n", num($2) }
            /^Available Spare:/                 { printf "spare %.0f\n", num($2) }
            /^Power On Hours:/                  { printf "hours %.0f\n", num($2) }
            /^Power Cycles:/                    { printf "cycles %.0f\n", num($2) }
            /^Unsafe Shutdowns:/                { printf "unsafeshut %.0f\n", num($2) }
            /^Media and Data Integrity Errors:/ { printf "mediaerr %.0f\n", num($2) }
            # data units are 1000x 512 bytes each; report GiB
            /^Data Units Written:/              { printf "written %.0f\n", num($2) * 512000 / 1073741824 }
            /^Data Units Read:/                 { printf "read %.0f\n", num($2) * 512000 / 1073741824 }
        ' > "$WORKDIR/metrics.raw"
        critwarn=$(printf '%s\n' "$out" | sed -n -e 's/^Critical Warning: *//p' | head -n 1)
    else
        # SCSI/SAS: no attribute table; grab what is there
        printf '%s\n' "$out" | awk -F': *' '
            /^Current Drive Temperature:/     { printf "temp %.0f\n", $2 + 0 }
            /^Elements in grown defect list:/ { printf "realloc %.0f\n", $2 + 0 }
        ' > "$WORKDIR/metrics.raw"
    fi

    # Deduplicate: when several attributes map to the same metric, the
    # worst value wins (highest; lowest for spare). Vendors misuse
    # attributes: Kingston's Media_Wearout_Indicator sits at VALUE 100
    # (wear 0) forever while SSD_Life_Left carries the real wear - the
    # optimistic reading must not mask the real one. Use attrmap in
    # smart.cfg to ignore an attribute that reports garbage.
    awk '
        $1 == "spare" { if (!($1 in v) || $2 + 0 < v[$1] + 0) v[$1] = $2; next }
                      { if (!($1 in v) || $2 + 0 > v[$1] + 0) v[$1] = $2 }
        END { for (m in v) print m, v[m] }' \
        "$WORKDIR/metrics.raw" | sort > "$WORKDIR/metrics"

    if [ ! -s "$WORKDIR/metrics" ] && [ -z "$health" ]; then
        printf '&clear %s (%s): no usable SMART data\n\n' "$dev" "$model" >> "$STATUS"
        continue
    fi

    devcolor=green
    case "$health" in
        ""|PASSED|OK)
            ;;
        *)
            devcolor=red
            printf '&red %s: SMART health reports "%s"\n' "$dev" "$health" >> "$NOTES"
            ;;
    esac
    if [ -n "$critwarn" ] && [ "$critwarn" != "0x00" ] && [ "$critwarn" != "0" ]; then
        devcolor=$(worst "$devcolor" yellow)
        printf '&yellow %s: NVMe critical warning flags set (%s)\n' "$dev" "$critwarn" >> "$NOTES"
    fi

    pairs=""
    while read -r m v; do
        [ -n "$m" ] || continue
        c=$(metric_color "$m" "$v")
        if [ "$c" != "green" ]; then
            devcolor=$(worst "$devcolor" "$c")
            printf '&%s %s: %s=%s\n' "$c" "$dev" "$m" "$v" >> "$NOTES"
        fi
        pairs="$pairs $m=$v"
        printf '%s_%s : %s\n' "$name" "$m" "$v" >> "$DATA"
    done < "$WORKDIR/metrics"

    {
        printf '&%s %s - %s' "$devcolor" "$dev" "$model"
        [ -n "$health" ] && printf ' - health: %s' "$health"
        printf '\n'
        [ -n "$pairs" ] && printf '    %s\n' "${pairs# }"
        printf '\n'
    } >> "$STATUS"

    OVERALL=$(worst "$OVERALL" "$devcolor")
done 3< "$WORKDIR/devices"

{
    if [ -s "$NOTES" ]; then
        cat "$NOTES"
    else
        printf 'All monitored disks are healthy\n'
    fi
    printf '\n'
    cat "$STATUS"
    printf 'Checked %s device(s), smartctl: %s\n' "$NDEV" "$SMARTCTL"
} > "$WORKDIR/final"

send_report "$OVERALL" "$WORKDIR/final" "$DATA"
exit 0
