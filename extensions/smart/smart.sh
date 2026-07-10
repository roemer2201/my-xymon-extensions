#!/bin/sh
#
# smart.sh -- Xymon client extension: S.M.A.R.T. disk health monitoring
#
# Collects SMART data for all local disks (SATA/ATA, NVMe, basic SAS)
# using smartctl(8), plus eMMC health data (Linux) using mmc(1) from
# mmc-utils, maps the vendor-specific attributes to a small set
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
MMC_UTILS=""           # path to mmc(1) from mmc-utils; empty = search $PATH
MMC_DEVICES=""         # eMMC devices; empty = auto-scan, "none" = disable

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
# When a drive is NOT in smartctl's drive database (common on OpenWrt/
# TurrisOS, whose smartmontools build ships without drivedb updates),
# smartctl falls back to generic names: vendor attributes show up as
# Unknown_Attribute, and 241/242 get the generic Total_LBAs_Written/
# _Read labels even on drives that count in other units. The
# model-specific entries at the top of the map recover the correct
# interpretation for known drive families by attribute *ID*; they are
# listed first so they win over the generic name matches.
#
# source: raw     = first number of the RAW_VALUE column
#         norm    = normalized VALUE column
#         invnorm = 100 - VALUE (for "percent life left" style values)
#         gib     = RAW_VALUE already in GiB
#         lba     = RAW_VALUE in 512-byte sectors, converted to GiB
#         mib32   = RAW_VALUE in 32-MiB units, converted to GiB
# ----------------------------------------------------------------------
DEFAULTMAP="\
KINGSTON SKC600*|231|wear|invnorm
KINGSTON SKC600*|241|written|mib32
KINGSTON SKC600*|242|read|mib32
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
*|Remaining_Lifetime_Perc|wear|invnorm
*|Percent_Lifetime_Remain|wear|invnorm
*|Percent_Life_Remaining|wear|invnorm
*|Percentage_Used|wear|raw
*|Perc_Rated_Life_Used|wear|raw
*|Host_Writes_GiB|written|gib
*|Lifetime_Writes_GiB|written|gib
*|Total_Writes_GiB|written|gib
*|Host_Writes_32MiB|written|mib32
*|Total_LBAs_Written|written|lba
*|Host_Reads_GiB|read|gib
*|Lifetime_Reads_GiB|read|gib
*|Total_Reads_GiB|read|gib
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

# --- locate smartctl and mmc --------------------------------------------
if [ -z "$SMARTCTL" ]; then
    SMARTCTL=$(command -v smartctl || true)
fi
if [ -n "$SMARTCTL" ] && [ ! -x "$SMARTCTL" ]; then
    SMARTCTL=""
fi
if [ -z "$MMC_UTILS" ]; then
    MMC_UTILS=$(command -v mmc || true)
fi
if [ -n "$MMC_UTILS" ] && [ ! -x "$MMC_UTILS" ]; then
    MMC_UTILS=""
fi

# --- eMMC discovery ------------------------------------------------------
# eMMC health is not covered by smartctl; it lives in the EXT_CSD
# register, read with mmc(1) from mmc-utils. Only whole eMMC devices
# qualify (sysfs type "MMC"); SD cards ("SD") have no EXT_CSD and are
# skipped. Linux only - other platforms expose no such interface.
MMCLIST=""
if [ "$MMC_DEVICES" = "none" ]; then
    :
elif [ -n "$MMC_DEVICES" ]; then
    MMCLIST=$MMC_DEVICES
elif [ "$(uname -s)" = "Linux" ]; then
    for d in /dev/mmcblk[0-9] /dev/mmcblk[0-9][0-9]; do
        [ -e "$d" ] || continue
        mtype=$(cat "/sys/block/${d#/dev/}/device/type" 2>/dev/null)
        [ "$mtype" = "MMC" ] || continue
        MMCLIST="$MMCLIST $d"
    done
    MMCLIST=${MMCLIST# }
fi
if [ -n "$MMCLIST" ] && [ -n "$EXCLUDE" ]; then
    mkeep=""
    for d in $MMCLIST; do
        printf '%s\n' "$d" | grep -Eq "$EXCLUDE" && continue
        mkeep="$mkeep $d"
    done
    MMCLIST=${mkeep# }
fi

if [ -z "$SMARTCTL" ]; then
    if [ -z "$MMCLIST" ]; then
        clear_report "smartctl not found - install smartmontools to enable this test"
    fi
    if [ -z "$MMC_UTILS" ]; then
        clear_report "eMMC device present but mmc-utils is not installed (OpenWrt: opkg install mmc-utils), and smartctl not found - install smartmontools; nothing can be checked"
    fi
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
            if [ -z "$SMARTCTL" ]; then
                :   # eMMC only: try without sudo; failures show as clear
            elif sudo -n "$SMARTCTL" --version >/dev/null 2>&1; then
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
if [ -z "$SMARTCTL" ]; then
    # eMMC-only mode: no smartctl, so no SMART devices can be checked.
    # Hint if disk device nodes exist that would need smartmontools
    # (same logic as the mmc-utils hint for eMMC devices below).
    : > "$WORKDIR/devices"
    ndisk=0
    for d in /dev/sd[a-z] /dev/sd[a-z][a-z] /dev/nvme[0-9] \
             /dev/ada[0-9] /dev/da[0-9]; do
        [ -e "$d" ] && ndisk=$((ndisk + 1))
    done
    if [ "$ndisk" -gt 0 ]; then
        printf '&clear %s disk device(s) present but smartctl is not installed - install smartmontools to enable SMART checks\n\n' \
            "$ndisk" >> "$STATUS"
    fi
elif [ -z "$DEVLIST" ]; then
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

if [ ! -s "$WORKDIR/devices" ] && [ -z "$MMCLIST" ]; then
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

    # Unknown to smartctl's drive database: vendor attributes keep their
    # generic (sometimes wrong) default names, so mappings may be
    # incomplete for models the built-in map does not cover by ID.
    dbnote=""
    case "$out" in
        *"Not in smartctl database"*) dbnote=" (not in smartctl drive database)" ;;
    esac

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
        printf '%s\n' "$dbnote"
        [ -n "$pairs" ] && printf '    %s\n' "${pairs# }"
        printf '\n'
    } >> "$STATUS"

    OVERALL=$(worst "$OVERALL" "$devcolor")
done 3< "$WORKDIR/devices"

# --- per-eMMC-device checks ----------------------------------------------
# JEDEC eMMC 5.0+ exposes three standardized health fields in EXT_CSD:
#   DEVICE_LIFE_TIME_EST_TYP_A/B: rated life used in 10% steps
#     (0x01 = 0-10% ... 0x0A = 90-100%, 0x0B = exceeded; 0x00 = not
#     reported). Mapped to the "wear" metric as the upper bound of the
#     worse of the two estimates (A and B cover different flash regions,
#     typically SLC and MLC).
#   PRE_EOL_INFO: reserved-block based end-of-life verdict
#     (0x01 Normal, 0x02 Warning = 80% of reserved blocks consumed,
#     0x03 Urgent = 90%). Treated like the SMART overall-health verdict.

mmcrun() {
    # shellcheck disable=SC2086  # $SUDO is intentionally word-split
    $SUDO "$MMC_UTILS" "$@" </dev/null 2>&1
}

# hexval <0xNN> -- prints the decimal value, nothing if unparsable
hexval() {
    case "${1:-}" in
        0x[0-9a-fA-F]|0x[0-9a-fA-F][0-9a-fA-F]) printf '%d\n' "$(($1))" ;;
    esac
}

for dev in $MMCLIST; do
    NDEV=$((NDEV + 1))
    name=$(printf '%s' "$(basename "$dev")" | tr -c 'A-Za-z0-9' '_')

    if [ -z "$MMC_UTILS" ]; then
        printf '&clear %s: eMMC device present but mmc-utils is not installed (OpenWrt: opkg install mmc-utils) - eMMC health not checked\n\n' \
            "$dev" >> "$STATUS"
        continue
    fi

    out=$(mmcrun extcsd read "$dev")

    if ! printf '%s\n' "$out" | grep -q "Extended CSD rev"; then
        {
            printf '&clear %s: cannot read eMMC EXT_CSD:\n' "$dev"
            printf '%s\n' "$out" | tail -n 2 | sed -e 's/^/    /'
            printf '\n'
        } >> "$STATUS"
        continue
    fi

    mname=$(cat "/sys/block/${dev#/dev/}/device/name" 2>/dev/null)
    csdver=$(printf '%s\n' "$out" | sed -n \
        -e 's/.*Extended CSD rev [0-9.]* (\(MMC [0-9.]*\)).*/\1/p' | head -n 1)
    model="eMMC${mname:+ $mname}${csdver:+, $csdver}"

    lifea=$(hexval "$(printf '%s\n' "$out" | sed -n \
        -e 's/.*\[EXT_CSD_DEVICE_LIFE_TIME_EST_TYP_A\]: *//p' | head -n 1)")
    lifeb=$(hexval "$(printf '%s\n' "$out" | sed -n \
        -e 's/.*\[EXT_CSD_DEVICE_LIFE_TIME_EST_TYP_B\]: *//p' | head -n 1)")
    preeol=$(hexval "$(printf '%s\n' "$out" | sed -n \
        -e 's/.*\[EXT_CSD_PRE_EOL_INFO\]: *//p' | head -n 1)")

    devcolor=green
    health=""
    case "${preeol:-0}" in
        1)  health="Normal" ;;
        2)  health="Warning"
            devcolor=yellow
            printf '&yellow %s: eMMC pre-EOL: Warning - 80%% of reserved blocks consumed\n' \
                "$dev" >> "$NOTES"
            ;;
        3)  health="Urgent"
            devcolor=red
            printf '&red %s: eMMC pre-EOL: Urgent - 90%% of reserved blocks consumed\n' \
                "$dev" >> "$NOTES"
            ;;
    esac

    wear=""
    w=0
    [ -n "$lifea" ] && [ "$lifea" -gt "$w" ] && w=$lifea
    [ -n "$lifeb" ] && [ "$lifeb" -gt "$w" ] && w=$lifeb
    if [ "$w" -gt 0 ]; then
        wear=$((w * 10))
        [ "$wear" -gt 100 ] && wear=100
    fi

    if [ -z "$wear" ] && [ -z "$health" ]; then
        printf '&clear %s (%s): no usable eMMC health data\n\n' \
            "$dev" "$model" >> "$STATUS"
        continue
    fi

    pairs=""
    if [ -n "$wear" ]; then
        c=$(metric_color wear "$wear")
        if [ "$c" != "green" ]; then
            devcolor=$(worst "$devcolor" "$c")
            printf '&%s %s: wear=%s\n' "$c" "$dev" "$wear" >> "$NOTES"
        fi
        pairs=" wear=$wear"
        printf '%s_wear : %s\n' "$name" "$wear" >> "$DATA"
    fi

    {
        printf '&%s %s - %s' "$devcolor" "$dev" "$model"
        [ -n "$health" ] && printf ' - health: %s' "$health"
        printf '\n'
        [ -n "$pairs" ] && printf '    %s\n' "${pairs# }"
        printf '\n'
    } >> "$STATUS"

    OVERALL=$(worst "$OVERALL" "$devcolor")
done

{
    if [ -s "$NOTES" ]; then
        cat "$NOTES"
    else
        printf 'All monitored disks are healthy\n'
    fi
    printf '\n'
    cat "$STATUS"
    printf 'Checked %s device(s), smartctl: %s' "$NDEV" "${SMARTCTL:-not found}"
    [ -n "$MMCLIST" ] && printf ', mmc: %s' "${MMC_UTILS:-not found}"
    printf '\n'
} > "$WORKDIR/final"

send_report "$OVERALL" "$WORKDIR/final" "$DATA"
exit 0
