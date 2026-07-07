#!/bin/sh
#
# diskio.sh -- Xymon client extension: local disk I/O metrics
#
# Measures per-device I/O activity -- read/write throughput, per-op
# latency, IOPS, utilization and queue depth -- for physical disks and
# aggregated volumes (md-RAID, LVM, dm-crypt, ZFS pools, GEOM mirror)
# and reports:
#
#   - one "diskio" status column (green unless configured thresholds
#     are violated; clear without a usable data source), and
#   - a "data" message with "NAME : VALUE" lines for RRD graphing
#     (split-NCV on the Xymon server, see server/README.md).
#
# Linux: true interval averages computed from /proc/diskstats counter
# deltas kept in a state file. FreeBSD: one gstat batch sample per run.
# ZFS pools (both OSes): one zpool iostat sample per run.
#
# Runs unmodified on Ubuntu, Rocky Linux (EL) and FreeBSD.
# Configuration: $XYMONHOME/etc/diskio.cfg (see the shipped diskio.cfg).

set -u
set -f      # no pathname expansion; EXCLUDE/INCLUDE hold glob patterns

LC_ALL=C
export LC_ALL

COLUMN="diskio"

# ----------------------------------------------------------------------
# Xymon environment (xymonlaunch provides these; fallbacks allow running
# the script manually for testing: output then goes to stdout)
# ----------------------------------------------------------------------
XYMONHOME="${XYMONHOME:-${XYMONCLIENTHOME:-}}"
XYMONTMP="${XYMONTMP:-${TMPDIR:-/tmp}}"
MACHINE="${MACHINE:-$(uname -n | tr '.' ',')}"

# ----------------------------------------------------------------------
# Defaults -- every value can be overridden in diskio.cfg
# ----------------------------------------------------------------------
LAYERS="pd md lv cr dm zp gm"   # device layers to report
EXCLUDE="loop* ram* sr* fd* cd* zram* zd* nbd* pass*"
INCLUDE=""                      # empty = everything not excluded
SAMPLE_SECONDS=10               # gstat / zpool iostat sampling window
GSTAT="${GSTAT:-gstat}"         # FreeBSD only
ZPOOL="${ZPOOL:-zpool}"

THRESHOLDS=""                   # filled by threshold() from diskio.cfg

# threshold <instance-pattern> <metric> <warn> <crit>
# Turn the column yellow/red when a metric exceeds a limit. "-"
# disables that level. The first matching line wins per value.
# shellcheck disable=SC2317  # called indirectly from the sourced config
threshold() {
    THRESHOLDS="${THRESHOLDS}${1}|${2}|${3:--}|${4:--}
"
}

CFGFILE="${DISKIO_CFG:-${XYMONHOME:+${XYMONHOME}/etc/diskio.cfg}}"
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi

# ----------------------------------------------------------------------
# Test hooks (only used by tests/diskio/, keep the defaults otherwise)
# ----------------------------------------------------------------------
PROCDIR="${DISKIO_PROC:-/proc}"
SYSDIR="${DISKIO_SYS:-/sys}"
OS="${DISKIO_OS:-$(uname -s)}"
NOW="${DISKIO_NOW:-$(date +%s)}"
STATEFILE="${DISKIO_STATE:-${XYMONTMP}/diskio.state}"

# Sanity-clamp the sampling window (gstat/zpool block for this long)
case "$SAMPLE_SECONDS" in
    ''|*[!0-9]*) SAMPLE_SECONDS=10 ;;
esac
[ "$SAMPLE_SECONDS" -lt 1 ] && SAMPLE_SECONDS=1
[ "$SAMPLE_SECONDS" -gt 60 ] && SAMPLE_SECONDS=60

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# sanitize <name> -> instance-safe name ([a-z0-9_] only, for split-NCV)
sanitize() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_'
}

# excluded <bare-device-name> -> 0 if the device must be skipped
excluded() {
    # shellcheck disable=SC2086  # patterns are intentionally word-split
    for e_pat in $EXCLUDE; do
        # shellcheck disable=SC2254  # globs must stay unquoted here
        case "$1" in
            $e_pat) return 0 ;;
        esac
    done
    if [ -n "$INCLUDE" ]; then
        # shellcheck disable=SC2086
        for e_pat in $INCLUDE; do
            # shellcheck disable=SC2254
            case "$1" in
                $e_pat) return 1 ;;
            esac
        done
        return 0
    fi
    return 1
}

# layer_enabled <layer> -> 0 if the layer is in $LAYERS
layer_enabled() {
    case " $LAYERS " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

# fge <a> <b> -> 0 if a >= b (floating point)
fge() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

# send_report <color> <status-body-file> [data-body-file]
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - disk I/O is $1

$(cat "$2")"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            "$XYMON" "$XYMSRV" "data ${MACHINE}.${COLUMN}
$(cat "$3")"
        fi
    else
        # No Xymon environment: print the messages (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - disk I/O is $1"
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
# Workspace
# ----------------------------------------------------------------------
WORKDIR=$(mktemp -d "${XYMONTMP}/diskio.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

VALUES="$WORKDIR/values"       # "<instance> <metric> <value>" triples
SKNOTES="$WORKDIR/sknotes"     # "<instance> <reason>" (baseline/reset)
SRCNOTES="$WORKDIR/srcnotes"   # data source problems (plain text)
SRCINFO="$WORKDIR/srcinfo"     # footer lines describing the sources
: > "$VALUES"
: > "$SKNOTES"
: > "$SRCNOTES"
: > "$SRCINFO"

clear_report() {
    printf '%s\n' "$1" > "$WORKDIR/final"
    send_report clear "$WORKDIR/final"
    exit 0
}

# ----------------------------------------------------------------------
# Linux: /proc/diskstats counter deltas against the state file
# ----------------------------------------------------------------------
collect_linux() {
    if [ ! -r "$PROCDIR/diskstats" ]; then
        printf '%s/diskstats is not readable\n' "$PROCDIR" >> "$SRCNOTES"
        return 0
    fi

    # Snapshot the current counters of every monitored whole device.
    # /proc/diskstats fields (kernels >= 4.18 append discard/flush
    # fields -- parse by position, the trailing "_" swallows them):
    #  1 major 2 minor 3 name 4 reads 5 rmerged 6 rsectors 7 ms_reading
    #  8 writes 9 wmerged 10 wsectors 11 ms_writing 12 inflight
    #  13 ms_doing_io 14 weighted_ms_io
    : > "$WORKDIR/current"
    while read -r _ _ d_name c_r _ c_rs c_rms c_w _ c_ws c_wms _ c_io c_wio _ <&3; do
        [ -n "$c_wio" ] || continue                  # malformed/short line
        [ -e "$SYSDIR/block/$d_name" ] || continue   # partitions have no entry
        d_layer=pd
        d_inst=$d_name
        case "$d_name" in
            md[0-9]*)
                d_layer=md
                ;;
            dm-[0-9]*)
                # dm-N numbering is not boot-stable: key the instance by
                # the resolved mapper name, classify by the dm uuid.
                d_inst=$(cat "$SYSDIR/block/$d_name/dm/name" 2>/dev/null || true)
                [ -n "$d_inst" ] || d_inst=$d_name
                case "$(cat "$SYSDIR/block/$d_name/dm/uuid" 2>/dev/null || true)" in
                    LVM-*)   d_layer=lv ;;
                    CRYPT-*) d_layer=cr ;;
                    *)       d_layer=dm ;;
                esac
                ;;
        esac
        excluded "$d_name" && continue
        if [ "$d_inst" != "$d_name" ]; then
            excluded "$d_inst" && continue
        fi
        layer_enabled "$d_layer" || continue
        printf '%s_%s %s %s %s %s %s %s %s %s %s\n' \
            "$d_layer" "$(sanitize "$d_inst")" "$NOW" \
            "$c_r" "$c_rs" "$c_rms" "$c_w" "$c_ws" "$c_wms" "$c_io" "$c_wio" \
            >> "$WORKDIR/current"
    done 3< "$PROCDIR/diskstats"

    PREV="$STATEFILE"
    [ -f "$PREV" ] || PREV=/dev/null

    # Delta computation. State line format (10 fields):
    # <instance> <epoch> <reads> <rsect> <rms> <writes> <wsect> <wms>
    # <io_ms> <weighted_ms>
    awk -v sf="$PREV" -v sk="$SKNOTES" '
        FILENAME == sf { prev[$1] = $0; next }
        {
            inst = $1
            if (!(inst in prev)) { print inst, "new" >> sk; next }
            split(prev[inst], p, " ")
            dt = $2 - p[2]
            if (dt < 30 || dt > 3600) { print inst, "interval" >> sk; next }
            dr  = $3 - p[3];  dsr = $4 - p[4];  dmsr = $5 - p[5]
            dw  = $6 - p[6];  dsw = $7 - p[7];  dmsw = $8 - p[8]
            dio = $9 - p[9];  dwm = $10 - p[10]
            if (dr < 0 || dsr < 0 || dmsr < 0 || dw < 0 || dsw < 0 || \
                dmsw < 0 || dio < 0 || dwm < 0) {
                print inst, "reset" >> sk
                next
            }
            printf "%s rbps %.0f\n",  inst, dsr * 512 / dt
            printf "%s wbps %.0f\n",  inst, dsw * 512 / dt
            printf "%s riops %.1f\n", inst, dr / dt
            printf "%s wiops %.1f\n", inst, dw / dt
            printf "%s rlat %.2f\n",  inst, (dr > 0 ? dmsr / dr : 0)
            printf "%s wlat %.2f\n",  inst, (dw > 0 ? dmsw / dw : 0)
            u = dio / (dt * 10); if (u > 100) u = 100
            printf "%s util %.1f\n",  inst, u
            printf "%s qlen %.2f\n",  inst, dwm / (dt * 1000)
        }
    ' "$PREV" "$WORKDIR/current" >> "$VALUES"

    # Always rewrite the full state from the current counters (atomic:
    # temp file + mv, the portable substitute for sed -i)
    if [ -s "$WORKDIR/current" ]; then
        newstate=$(mktemp "${XYMONTMP}/diskio.state.XXXXXX") || return 0
        if cat "$WORKDIR/current" > "$newstate"; then
            mv "$newstate" "$STATEFILE"
        else
            rm -f "$newstate"
        fi
        printf 'Linux: /proc/diskstats deltas since the previous run\n' \
            >> "$SRCINFO"
    fi
}

# ----------------------------------------------------------------------
# FreeBSD: one gstat batch sample (no shell-readable cumulative
# counters exist, so this measures a window, not the whole interval)
# ----------------------------------------------------------------------
collect_freebsd() {
    if ! command -v "$GSTAT" >/dev/null 2>&1; then
        printf 'gstat not found - disk statistics unavailable\n' >> "$SRCNOTES"
        return 0
    fi
    if ! "$GSTAT" -b -I "${SAMPLE_SECONDS}s" > "$WORKDIR/gstat.out" 2>/dev/null; then
        printf 'gstat failed (no access to /dev/devstat?)\n' >> "$SRCNOTES"
        return 0
    fi
    printf 'FreeBSD: gstat batch sample, %ss window per run\n' \
        "$SAMPLE_SECONDS" >> "$SRCINFO"

    # Batch rows: L(q) ops/s r/s kBps ms/r w/s kBps ms/w %busy name
    awk 'NF >= 10 && $1 ~ /^[0-9]/' "$WORKDIR/gstat.out" > "$WORKDIR/gstat.rows"
    while read -r g_ql _ g_rs g_rkb g_msr g_ws g_wkb g_msw g_busy g_name <&3; do
        g_layer=pd
        g_base=$g_name
        case "$g_name" in
            mirror/*|raid/*|raid3/*|stripe/*|concat/*)
                g_layer=gm
                g_base=${g_name#*/}
                ;;
            ada[0-9]*|da[0-9]*|nda[0-9]*|nvd[0-9]*|vtbd[0-9]*|mmcsd[0-9]*|ad[0-9]*)
                case "$g_name" in
                    *p[0-9]*|*s[0-9]*) continue ;;   # partition/slice
                esac
                ;;
            *) continue ;;                           # labels, gpt/*, cd*, ...
        esac
        excluded "$g_base" && continue
        layer_enabled "$g_layer" || continue
        awk -v i="${g_layer}_$(sanitize "$g_base")" \
            -v ql="$g_ql" -v rs="$g_rs" -v rkb="$g_rkb" -v msr="$g_msr" \
            -v ws="$g_ws" -v wkb="$g_wkb" -v msw="$g_msw" -v busy="$g_busy" '
            BEGIN {
                printf "%s rbps %.0f\n",  i, rkb * 1024
                printf "%s wbps %.0f\n",  i, wkb * 1024
                printf "%s riops %.1f\n", i, rs + 0
                printf "%s wiops %.1f\n", i, ws + 0
                printf "%s rlat %.2f\n",  i, msr + 0
                printf "%s wlat %.2f\n",  i, msw + 0
                u = busy + 0; if (u > 100) u = 100
                printf "%s util %.1f\n",  i, u
                printf "%s qlen %.2f\n",  i, ql + 0
            }
        ' >> "$VALUES"
    done 3< "$WORKDIR/gstat.rows"
}

# ----------------------------------------------------------------------
# ZFS pools (Linux and FreeBSD): one zpool iostat sample. No cumulative
# counters are exposed at pool level; util/qlen do not exist there.
# ----------------------------------------------------------------------
collect_zfs() {
    layer_enabled zp || return 0
    command -v "$ZPOOL" >/dev/null 2>&1 || return 0
    z_pools=$("$ZPOOL" list -H -o name 2>/dev/null) || z_pools=""
    [ -n "$z_pools" ] || return 0

    z_lat=yes
    if ! "$ZPOOL" iostat -Hpl "$SAMPLE_SECONDS" 2 > "$WORKDIR/zpool.out" 2>/dev/null; then
        z_lat=no   # very old ZFS without -l: throughput/IOPS only
        if ! "$ZPOOL" iostat -Hp "$SAMPLE_SECONDS" 2 > "$WORKDIR/zpool.out" 2>/dev/null; then
            printf 'zpool iostat failed - ZFS pools not monitored this run\n' \
                >> "$SRCNOTES"
            return 0
        fi
    fi
    if [ "$z_lat" = yes ]; then
        printf 'ZFS: zpool iostat sample, %ss window per run\n' \
            "$SAMPLE_SECONDS" >> "$SRCINFO"
    else
        printf 'ZFS: zpool iostat sample, %ss window per run (no -l support, latency omitted)\n' \
            "$SAMPLE_SECONDS" >> "$SRCINFO"
    fi

    # Two reports per pool; only the second is a real interval sample
    # (the first is the average since boot). Last line per pool wins.
    # Columns (-Hpl): name alloc free ops_r ops_w bw_r bw_w
    #                 total_wait_r total_wait_w ... (nanoseconds)
    awk -v lat="$z_lat" '
        NF >= 7 { last[$1] = $0 }
        END {
            for (p in last) {
                n = split(last[p], f, "[ \t]+")
                printf "%s riops %.1f\n", p, f[4] + 0
                printf "%s wiops %.1f\n", p, f[5] + 0
                printf "%s rbps %.0f\n",  p, f[6] + 0
                printf "%s wbps %.0f\n",  p, f[7] + 0
                if (lat == "yes" && n >= 9) {
                    printf "%s rlat %.2f\n", p, (f[8] == "-" ? 0 : f[8] / 1000000)
                    printf "%s wlat %.2f\n", p, (f[9] == "-" ? 0 : f[9] / 1000000)
                }
            }
        }
    ' "$WORKDIR/zpool.out" > "$WORKDIR/zfs.raw"

    while read -r z_name z_metric z_value <&3; do
        excluded "$z_name" && continue
        printf 'zp_%s %s %s\n' "$(sanitize "$z_name")" "$z_metric" "$z_value" \
            >> "$VALUES"
    done 3< "$WORKDIR/zfs.raw"
}

# ----------------------------------------------------------------------
# Collect
# ----------------------------------------------------------------------
case "$OS" in
    Linux)   collect_linux ;;
    FreeBSD) collect_freebsd ;;
    *)       printf 'platform %s is not supported by this extension\n' "$OS" \
                 >> "$SRCNOTES" ;;
esac
collect_zfs

if [ ! -s "$VALUES" ] && [ ! -s "$SKNOTES" ]; then
    if [ -s "$SRCNOTES" ]; then
        clear_report "$(cat "$SRCNOTES")"
    fi
    clear_report "no supported block devices found (check EXCLUDE/INCLUDE/LAYERS in diskio.cfg)"
fi

# ----------------------------------------------------------------------
# Thresholds (optional; without threshold lines the column stays green)
# ----------------------------------------------------------------------
: > "$WORKDIR/colorlog"
: > "$WORKDIR/viol"
if [ -n "$THRESHOLDS" ] && [ -s "$VALUES" ]; then
    printf '%s' "$THRESHOLDS" > "$WORKDIR/thr"
    while read -r v_inst v_metric v_value <&4; do
        while IFS='|' read -r t_pat t_metric t_warn t_crit <&5; do
            [ -n "$t_pat" ] || continue
            [ "$v_metric" = "$t_metric" ] || continue
            # shellcheck disable=SC2254  # globs must stay unquoted here
            case "$v_inst" in
                $t_pat) ;;
                *) continue ;;
            esac
            t_color=green
            if [ "$t_crit" != "-" ] && fge "$v_value" "$t_crit"; then
                t_color=red
            elif [ "$t_warn" != "-" ] && fge "$v_value" "$t_warn"; then
                t_color=yellow
            fi
            if [ "$t_color" != green ]; then
                printf '&%s %s: %s=%s (warn %s / crit %s)\n' \
                    "$t_color" "$v_inst" "$v_metric" "$v_value" \
                    "$t_warn" "$t_crit" >> "$WORKDIR/viol"
                printf '%s %s\n' "$v_inst" "$t_color" >> "$WORKDIR/colorlog"
            fi
            break   # first matching threshold line wins
        done 5< "$WORKDIR/thr"
    done 4< "$VALUES"
fi

OVERALL=green
: > "$WORKDIR/colormap"
if [ -s "$WORKDIR/colorlog" ]; then
    awk '
        BEGIN { r["yellow"] = 2; r["red"] = 3 }
        { if (r[$2] > w[$1]) { w[$1] = r[$2]; col[$1] = $2 } }
        END { for (i in col) print i, col[i] }
    ' "$WORKDIR/colorlog" > "$WORKDIR/colormap"
    OVERALL=$(awk '
        BEGIN { r["yellow"] = 2; r["red"] = 3; m = 0; o = "green" }
        { if (r[$2] > m) { m = r[$2]; o = $2 } }
        END { print o }
    ' "$WORKDIR/colorlog")
fi

# ----------------------------------------------------------------------
# Status table
# ----------------------------------------------------------------------
if [ -s "$VALUES" ]; then
    awk -v cm="$WORKDIR/colormap" '
        function g(i, m)  { return ((i, m) in v) ? v[i, m] : "-" }
        function mb(i, m) {
            return ((i, m) in v) ? sprintf("%.2f", v[i, m] / 1048576) : "-"
        }
        BEGIN {
            while ((getline line < cm) > 0) {
                split(line, a, " ")
                col[a[1]] = a[2]
            }
        }
        {
            if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 }
            v[$1, $2] = $3
        }
        END {
            printf "        %-22s %9s %8s %7s %9s %8s %7s %6s %6s\n", \
                "device", "rd MB/s", "rd IOPS", "rd ms", \
                "wr MB/s", "wr IOPS", "wr ms", "util%", "qlen"
            for (i = 1; i <= n; i++) {
                inst = order[i]
                c = (inst in col) ? col[inst] : "green"
                printf "&%s %-22s %9s %8s %7s %9s %8s %7s %6s %6s\n", \
                    c, inst, \
                    mb(inst, "rbps"), g(inst, "riops"), g(inst, "rlat"), \
                    mb(inst, "wbps"), g(inst, "wiops"), g(inst, "wlat"), \
                    g(inst, "util"), g(inst, "qlen")
            }
        }
    ' "$VALUES" > "$WORKDIR/table"
fi

# Baseline / counter-reset notes
if [ -s "$SKNOTES" ]; then
    while read -r s_inst s_reason <&3; do
        case "$s_reason" in
            new)      s_msg="baseline stored (first run for this device)" ;;
            reset)    s_msg="counter reset detected (reboot?), re-baselined" ;;
            interval) s_msg="measurement interval out of range, re-baselined" ;;
            *)        s_msg="skipped this run" ;;
        esac
        printf '&clear %s: %s - values appear on the next run\n' \
            "$s_inst" "$s_msg"
    done 3< "$SKNOTES" > "$WORKDIR/sktext"
fi

NINST=$(awk '!($1 in s) { s[$1]; n++ } END { print n + 0 }' "$VALUES")

# ----------------------------------------------------------------------
# Assemble and send
# ----------------------------------------------------------------------
{
    if [ -s "$WORKDIR/viol" ]; then
        cat "$WORKDIR/viol"
    elif [ -n "$THRESHOLDS" ]; then
        printf 'All monitored devices are within the configured thresholds\n'
    else
        printf 'Disk I/O trending (no thresholds configured)\n'
    fi
    printf '\n'
    if [ -s "$WORKDIR/table" ]; then
        cat "$WORKDIR/table"
        printf '\n'
    fi
    if [ -s "${WORKDIR}/sktext" ]; then
        cat "$WORKDIR/sktext"
        printf '\n'
    fi
    if [ -s "$SRCNOTES" ]; then
        sed -e 's/^/\&clear /' "$SRCNOTES"
        printf '\n'
    fi
    [ -s "$SRCINFO" ] && cat "$SRCINFO"
    printf 'Monitored %s instance(s)\n' "$NINST"
} > "$WORKDIR/final"

awk '{ printf "%s_%s : %s\n", $1, $2, $3 }' "$VALUES" > "$WORKDIR/data"

send_report "$OVERALL" "$WORKDIR/final" "$WORKDIR/data"
exit 0
