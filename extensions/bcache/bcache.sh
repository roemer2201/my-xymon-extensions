#!/bin/sh
#
# bcache.sh -- Xymon client extension: Linux bcache (block layer cache)
#
# Reports every bcache cache set, cache device and backing device of a
# host in one "bcache" column, plus a "data" message for RRD graphs.
# Everything is read from sysfs; no tool and no root rights are needed
# (the attributes read here are mode 0444).
#
# Where the numbers come from (Documentation/admin-guide/bcache.rst and
# drivers/md/bcache/sysfs.c):
#   /sys/fs/bcache/<set-uuid>/        cache set: stats, cutoffs, errors
#   /sys/fs/bcache/<set-uuid>/cacheN  -> the cache device's bcache dir
#   /sys/block/<bdev>/bcache/         backing device: state, dirty data,
#                                     writeback, stats (also reachable
#                                     as /sys/block/bcacheN/bcache)
#
# Backing devices are found through /sys/block/*/bcache and
# /sys/block/*/*/bcache (partitions), NOT through /sys/block/bcacheN: a
# backing device in state clean or dirty whose cache set is missing is
# registered but never started (super.c, register_bdev() starts only
# "no cache" and "inconsistent" ones), so it has no bcacheN at all -
# and that is exactly the case worth an alarm.
#
# Names: the RRD files are named after the first 8 hex digits of the
# backing device UUID (backing_dev_uuid, from its superblock) resp. the
# cache set UUID. Both survive reboots and device renames, while
# bcacheN and sdX do not. /dev/bcache/by-uuid/ uses the same UUIDs.
#
# Colors (worst wins):
#   red     backing device "inconsistent"; registered but not running;
#           state clean/dirty without its cache set; io_disable set on
#           a backing device or a cache set; in use above
#           cutoff_writeback_sync while a device caches in writeback
#           mode (no write is cached any more); a device or cache set
#           seen before has vanished (BCACHE_VANISHED_COLOR); fewer
#           backing devices than BCACHE_MIN_BDEVS
#   yellow  io_errors on a cache or backing device; in use above
#           cutoff_writeback (only sync writes are cached); writeback
#           mode with writeback_running=0; state "no cache";
#           cache_mode other than BCACHE_MODE (if set); hit ratio below
#           BCACHE_HIT_YELLOW/RED (if set)
#   clear   no bcache on this host (no sysfs, module not loaded, no
#           device registered and none remembered)
#
# Vanished devices: the UUIDs seen are remembered in a state file
# (BCACHE_STATEDIR, default $XYMONTMP). A UUID that disappears stays
# red until it comes back or is acknowledged with BCACHE_FORGET. Put
# the state file on a persistent file system if $XYMONTMP is a tmpfs.
#
# Rates (hit ratio, requests/s, throughput) are differences between two
# polls of the cumulative counters, so they appear from the second poll
# on. A counter that went backwards (reboot, clear_stats) skips one poll.
#
# Configuration: environment variables and/or
# $XYMONHOME/etc/my-xymon-extensions/bcache.cfg (see the shipped
# bcache.cfg; the config file wins over the environment).

set -u

# Every number in a Xymon message must use a decimal point; awk formats
# floats according to LC_NUMERIC.
LC_ALL=C
export LC_ALL

# ----------------------------------------------------------------------
# Xymon environment (xymonlaunch or standalone/xymon-run.sh provide
# these; fallbacks allow running the script manually for testing:
# output then goes to stdout)
# ----------------------------------------------------------------------
XYMONHOME="${XYMONHOME:-${XYMONCLIENTHOME:-}}"
XYMONTMP="${XYMONTMP:-${TMPDIR:-/tmp}}"
MACHINE="${MACHINE:-$(uname -n | tr '.' ',')}"

# ----------------------------------------------------------------------
# Defaults -- every value can be set in the environment or in bcache.cfg
# ----------------------------------------------------------------------
BCACHE_COLUMN="${BCACHE_COLUMN:-bcache}"        # Xymon column name
BCACHE_SYSFS="${BCACHE_SYSFS:-/sys}"            # sysfs mount point
BCACHE_STATEDIR="${BCACHE_STATEDIR:-}"          # empty: $XYMONTMP
BCACHE_FORGET="${BCACHE_FORGET:-}"              # UUID prefixes to forget
BCACHE_VANISHED_COLOR="${BCACHE_VANISHED_COLOR:-red}"
BCACHE_MIN_BDEVS="${BCACHE_MIN_BDEVS:-}"        # empty: no minimum
BCACHE_MODE="${BCACHE_MODE:-}"                  # expected cache_mode
BCACHE_MODE_COLOR="${BCACHE_MODE_COLOR:-yellow}"
BCACHE_NOCACHE_COLOR="${BCACHE_NOCACHE_COLOR:-yellow}"
BCACHE_IOERR_COLOR="${BCACHE_IOERR_COLOR:-yellow}"
BCACHE_CUTOFF_COLOR="${BCACHE_CUTOFF_COLOR:-yellow}"
BCACHE_CUTOFF_SYNC_COLOR="${BCACHE_CUTOFF_SYNC_COLOR:-red}"
BCACHE_HIT_YELLOW="${BCACHE_HIT_YELLOW:-}"      # percent, cache set
BCACHE_HIT_RED="${BCACHE_HIT_RED:-}"            # percent, cache set
BCACHE_HIT_MINREQ="${BCACHE_HIT_MINREQ:-1000}"  # requests per poll
BCACHE_PRIO_STATS="${BCACHE_PRIO_STATS:-yes}"   # read priority_stats
BCACHE_INTERNAL="${BCACHE_INTERNAL:-no}"        # btree usage graph

# Own subdirectory since 0.20.0 ($XYMONHOME/etc is shared with the
# Xymon server and hobbit-plugins); the old place is the fallback.
CFGFILE="${BCACHE_CFG:-}"
if [ -z "$CFGFILE" ] && [ -n "$XYMONHOME" ]; then
    CFGFILE="$XYMONHOME/etc/my-xymon-extensions/bcache.cfg"
    [ -f "$CFGFILE" ] || CFGFILE="$XYMONHOME/etc/bcache.cfg"
fi
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi
COLUMN="$BCACHE_COLUMN"
[ -n "$BCACHE_STATEDIR" ] || BCACHE_STATEDIR="$XYMONTMP"

# Only the colors that make sense; anything else falls back.
color_or() { # color_or <value> <default> -> red|yellow|green
    case "$1" in
        red|yellow|green) printf '%s' "$1" ;;
        *) printf '%s' "$2" ;;
    esac
}
BCACHE_VANISHED_COLOR=$(color_or "$BCACHE_VANISHED_COLOR" red)
BCACHE_MODE_COLOR=$(color_or "$BCACHE_MODE_COLOR" yellow)
BCACHE_NOCACHE_COLOR=$(color_or "$BCACHE_NOCACHE_COLOR" yellow)
BCACHE_IOERR_COLOR=$(color_or "$BCACHE_IOERR_COLOR" yellow)
BCACHE_CUTOFF_COLOR=$(color_or "$BCACHE_CUTOFF_COLOR" yellow)
BCACHE_CUTOFF_SYNC_COLOR=$(color_or "$BCACHE_CUTOFF_SYNC_COLOR" red)

is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}
is_uint "$BCACHE_MIN_BDEVS" || BCACHE_MIN_BDEVS=""
is_uint "$BCACHE_HIT_YELLOW" || BCACHE_HIT_YELLOW=""
is_uint "$BCACHE_HIT_RED" || BCACHE_HIT_RED=""
is_uint "$BCACHE_HIT_MINREQ" || BCACHE_HIT_MINREQ=1000

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# send_report <color> <status-body-file> [data-body-file]
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - bcache: ${SUMMARY:-$1}

$(cat "$2")"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            "$XYMON" "$XYMSRV" "data ${MACHINE}.${COLUMN}
$(cat "$3")"
        fi
    else
        # No Xymon environment: print the messages (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - bcache: ${SUMMARY:-$1}"
        echo ""
        cat "$2"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            echo ""
            echo "data ${MACHINE}.${COLUMN}"
            cat "$3"
        fi
    fi
}

# attrs <dir> <name>... -> one "name:line" per line of every readable
# attribute. The extra /dev/null makes grep prefix the file name even
# for a single file (-H is not POSIX); unreadable or missing attributes
# are skipped silently (-s).
attrs() {
    at_dir=$1
    shift
    ( cd "$at_dir" 2>/dev/null && grep -s '' /dev/null "$@" )
}

# target_name <symlink> -> last path component of what it points to
target_name() {
    tn_path=$( cd -P "$1" 2>/dev/null && pwd -P ) || return 1
    printf '%s\n' "${tn_path##*/}"
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

WORKDIR=$(mktemp -d "${XYMONTMP}/bcache.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

FACTS="$WORKDIR/facts"
STATUS="$WORKDIR/status"
DATA="$WORKDIR/data"
NEWSTATE="$WORKDIR/newstate"
: > "$FACTS"
: > "$DATA"
: > "$NEWSTATE"
SUMMARY=""
STATEFILE="${BCACHE_STATEDIR}/bcache.${MACHINE}.state"
NOW=$(date +%s)

clear_report() {
    SUMMARY="not applicable"
    {
        printf '<!-- ncv_skipstart -->\n'
        printf '%s\n' "$1"
        printf '<!-- ncv_skipend -->\n'
    } > "$WORKDIR/clear"
    send_report clear "$WORKDIR/clear"
    exit 0
}

SYSBLOCK="$BCACHE_SYSFS/block"
SYSSETS="$BCACHE_SYSFS/fs/bcache"

if [ ! -d "$SYSBLOCK" ]; then
    clear_report "$SYSBLOCK does not exist - bcache is a Linux kernel feature, test not applicable on this host."
fi

# --- backing devices ---------------------------------------------------
# /sys/block/bcacheN/bcache is only a symlink to the backing device's
# directory, so those entries are skipped; a flash-only volume has a
# bcache directory without "state" and is skipped as well.
for bdir in "$SYSBLOCK"/*/bcache "$SYSBLOCK"/*/*/bcache; do
    [ -f "$bdir/state" ] || continue
    bpar=${bdir%/bcache}
    bname=${bpar##*/}
    case "$bname" in
        bcache[0-9]*) continue ;;
    esac
    uuid=""
    if [ -r "$bdir/backing_dev_uuid" ]; then
        read -r uuid < "$bdir/backing_dev_uuid"
    fi
    # Kernels without backing_dev_uuid: fall back to the device name.
    case "$uuid" in
        ''|*[!0-9a-f-]*) uuid="dev-$bname" ;;
    esac
    {
        printf 'sysname:%s\n' "$bname"
        if [ -d "$bdir/dev" ]; then
            target_name "$bdir/dev" | sed 's/^/bcname:/'
            if [ -r "$bdir/dev/stat" ]; then
                sed -n '1s/^/stat:/p' "$bdir/dev/stat"
            fi
        fi
        if [ -d "$bdir/cache" ]; then
            target_name "$bdir/cache" | sed 's/^/cset:/'
        fi
        attrs "$bdir" state running cache_mode dirty_data io_errors \
            io_disable writeback_running writeback_rate \
            writeback_rate_debug label stats_total/cache_hits \
            stats_total/cache_misses stats_total/cache_hit_ratio
    } | sed "s|^|B $uuid |" >> "$FACTS"
done

# --- cache sets and their cache devices --------------------------------
for sdir in "$SYSSETS"/*; do
    [ -f "$sdir/cache_available_percent" ] || continue
    sid=${sdir##*/}
    case "$sid" in
        *[!0-9a-f-]*) continue ;;
    esac
    nbdev=0
    for link in "$sdir"/bdev[0-9]*; do
        [ -e "$link" ] && nbdev=$((nbdev + 1))
    done
    {
        printf 'nbdev:%s\n' "$nbdev"
        attrs "$sdir" cache_available_percent errors io_error_limit \
            stats_total/cache_hits stats_total/cache_misses \
            stats_total/cache_bypass_hits stats_total/cache_bypass_misses \
            stats_total/cache_hit_ratio internal/io_disable \
            internal/cutoff_writeback internal/cutoff_writeback_sync \
            internal/btree_used_percent root_usage_percent
    } | sed "s|^|S $sid |" >> "$FACTS"

    for cdir in "$sdir"/cache[0-9]*; do
        [ -d "$cdir" ] || continue
        cid="$sid/${cdir##*/}"
        {
            # The partition (or disk) the cache device lives on, and its
            # I/O counters: written/btree_written are rounded to three
            # digits by bch_hprint() and useless as rates.
            target_name "$cdir/.." | sed 's/^/sysname:/'
            if [ -r "$cdir/../stat" ]; then
                sed -n '1s/^/stat:/p' "$cdir/../stat"
            fi
            attrs "$cdir" io_errors written nbuckets
            if [ "$BCACHE_PRIO_STATS" = yes ]; then
                attrs "$cdir" priority_stats
            fi
        } | sed "s|^|C $cid |" >> "$FACTS"
    done
done

# --- nothing at all? ---------------------------------------------------
if [ ! -s "$FACTS" ] && [ -z "$BCACHE_MIN_BDEVS" ] &&
   ! grep -q '^SEEN ' "$STATEFILE" 2>/dev/null; then
    clear_report "No bcache device on this host (the bcache module is not loaded, or no cache set and no backing device is registered) - test not applicable."
fi

# ----------------------------------------------------------------------
# Evaluation: one awk pass over the previous state ("P" lines) and the
# facts collected above.
# ----------------------------------------------------------------------
{
    [ -r "$STATEFILE" ] && sed 's/^/P /' "$STATEFILE"
    cat "$FACTS"
} | awk -v now="$NOW" -v statusf="$STATUS" -v dataf="$DATA" \
    -v statef="$NEWSTATE" -v forget="$BCACHE_FORGET" \
    -v vanishedcolor="$BCACHE_VANISHED_COLOR" \
    -v minbdevs="$BCACHE_MIN_BDEVS" -v wantmode="$BCACHE_MODE" \
    -v modecolor="$BCACHE_MODE_COLOR" \
    -v nocachecolor="$BCACHE_NOCACHE_COLOR" \
    -v ioerrcolor="$BCACHE_IOERR_COLOR" \
    -v cutcolor="$BCACHE_CUTOFF_COLOR" \
    -v cutsynccolor="$BCACHE_CUTOFF_SYNC_COLOR" \
    -v hityellow="$BCACHE_HIT_YELLOW" -v hitred="$BCACHE_HIT_RED" \
    -v hitminreq="$BCACHE_HIT_MINREQ" -v internal="$BCACHE_INTERNAL" '
function rank(c) { return (c == "red") ? 3 : (c == "yellow") ? 2 : (c == "green") ? 1 : 0 }
function worse(a, b) { return (rank(b) > rank(a)) ? b : a }

# bch_hprint() output ("9.6G", "4.0k/sec", "-95.3M") -> number; units
# are powers of 1024. Empty when the text is not such a value.
function h2n(s,   u, i, n) {
    sub(/\/sec$/, "", s)
    u = substr(s, length(s), 1)
    i = index("kMGTPEZY", u)
    if (i > 0) s = substr(s, 1, length(s) - 1)
    if (s !~ /^-?[0-9]+(\.[0-9]+)?$/) return ""
    n = s + 0
    while (i-- > 0) n *= 1024
    return n
}

# "writethrough [writeback] writearound none" -> "writeback"
function selected(s) {
    if (match(s, /\[[a-z-]+\]/)) return substr(s, RSTART + 1, RLENGTH - 2)
    return s
}

# "06912c73-4920-..." -> "06912c73"; anything else sanitized
function short(id,   s) {
    if (id ~ /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-/)
        return substr(id, 1, 8)
    s = tolower(id)
    gsub(/[^a-z0-9]+/, "_", s)
    return s
}

function isuuid(id) { return id ~ /^[0-9a-f]+-[0-9a-f]+-[0-9a-f]+-[0-9a-f]+-[0-9a-f]+$/ }

function human(b) {
    if (b == "") return "?"
    if (b >= 1099511627776) return sprintf("%.1fT", b / 1099511627776)
    if (b >= 1073741824) return sprintf("%.1fG", b / 1073741824)
    if (b >= 1048576) return sprintf("%.1fM", b / 1048576)
    return sprintf("%.1fk", b / 1024)
}

function ncv(name, val) {
    if (val == "") return
    printf "%s : %s\n", name, val > dataf
}

# delta <key> <current counter> -> increase since the previous poll, or
# "" (first poll, counter reset, no value). Records the new value.
function delta(key, cur) {
    if (cur !~ /^[0-9]+$/) return ""
    printf "K %s %s\n", key, cur > statef
    if (!(key in K) || dt <= 0 || cur + 0 < K[key] + 0) return ""
    return cur - K[key]
}

function rate(d) { return (d == "") ? "" : d / dt }

# stat file of a block device -> field n (1-based)
function statf(line, n,   f) {
    if (split(line, f, " ") < n) return ""
    return f[n]
}

function forgotten(uuid,   n, p, i) {
    n = split(forget, p, " ")
    for (i = 1; i <= n; i++)
        if (p[i] != "" && index(uuid, tolower(p[i])) == 1) return 1
    return 0
}

function problem(color, text) {
    WORST = worse(WORST, color)
    if (rank(color) >= 2) {
        NPROB++
        if (FIRSTPROB == "" || rank(color) > rank(FIRSTCOLOR)) {
            FIRSTPROB = text
            FIRSTCOLOR = color
        }
    }
}

BEGIN { WORST = "green"; NPROB = 0; FIRSTPROB = ""; FIRSTCOLOR = ""; NB = NS = NC = 0 }

$1 == "P" {
    if ($2 == "T" && $3 ~ /^[0-9]+$/) PREVT = $3
    else if ($2 == "K" && NF >= 4) K[$3] = $4
    else if ($2 == "SEEN" && NF >= 6) {
        nseen++
        SK[nseen] = $3; SU[nseen] = $4; SN[nseen] = $5; SF[nseen] = $6
    }
    next
}

{
    kind = $1; id = $2
    line = $0
    sub(/^[^ ]+ [^ ]+ /, "", line)
    c = index(line, ":")
    if (c == 0) next
    key = substr(line, 1, c - 1)
    val = substr(line, c + 1)
    # multi-line attributes: "Dirty:  14%", "target:  13.3G"
    if (key == "writeback_rate_debug" || key == "priority_stats") {
        c = index(val, ":")
        if (c == 0) next
        key = key "." tolower(substr(val, 1, c - 1))
        val = substr(val, c + 1)
    }
    gsub(/^[ \t]+|[ \t]+$/, "", val)
    A[kind, id, key] = val
    if (!((kind, id) in HAVE)) {
        HAVE[kind, id] = 1
        if (kind == "B") BID[++NB] = id
        else if (kind == "S") SID[++NS] = id
        else if (kind == "C") CID[++NC] = id
    }
}

END {
    dt = (PREVT != "" && now > PREVT) ? now - PREVT : 0
    printf "T %s\n", now > statef

    # Backing devices, sorted by bcacheN (fall back to the device name)
    for (i = 1; i <= NB; i++) {
        b = BID[i]
        SORTKEY[b] = (A["B", b, "bcname"] != "") ? A["B", b, "bcname"] : "~" A["B", b, "sysname"]
        if (SORTKEY[b] ~ /^bcache[0-9]+$/)
            SORTKEY[b] = sprintf("bcache%09d", substr(SORTKEY[b], 7) + 0)
    }
    for (i = 2; i <= NB; i++)
        for (j = i; j > 1 && SORTKEY[BID[j]] < SORTKEY[BID[j - 1]]; j--) {
            t = BID[j]; BID[j] = BID[j - 1]; BID[j - 1] = t
        }

    # --- pre-pass: what is here, which sets cache in writeback mode ------
    for (i = 1; i <= NB; i++) {
        b = BID[i]
        set = A["B", b, "cset"]
        if (set != "" && selected(A["B", b, "cache_mode"]) == "writeback") WBSET[set] = 1
        if (isuuid(b))
            PRESENT["B", b] = (A["B", b, "bcname"] != "" ? A["B", b, "bcname"] "/" : "") A["B", b, "sysname"]
    }
    for (i = 1; i <= NS; i++)
        if (isuuid(SID[i])) PRESENT["S", SID[i]] = "no_cache_device"
    for (i = 1; i <= NC; i++) {
        s = CID[i]
        sub(/\/.*/, "", s)
        if (isuuid(s) && CID[i] ~ /\/cache0$/) PRESENT["S", s] = A["C", CID[i], "sysname"]
    }

    # The order of the sections below is the order of importance for the
    # summary line: the first problem of the worst color is named there.

    # --- remembered devices: vanished, forgotten, still here -------------
    for (i = 1; i <= nseen; i++) {
        k = SK[i]; u = SU[i]
        if ((k, u) in PRESENT) continue
        if (forgotten(u)) {
            GONETXT = GONETXT "\n&clear " (k == "S" ? "cache set " : "backing device ") u " (last seen as " SN[i] ") - forgotten (BCACHE_FORGET)"
            continue
        }
        printf "SEEN %s %s %s %s\n", k, u, SN[i], SF[i] > statef
        GONETXT = GONETXT "\n&" vanishedcolor " " (k == "S" ? "cache set " : "backing device ") u " (last seen as " SN[i] ") has vanished"
        if (k == "S") problem(vanishedcolor, "cache set " short(u) " (" SN[i] ") vanished")
        else problem(vanishedcolor, SN[i] " (" short(u) ") vanished")
    }
    for (i = 1; i <= nseen; i++) FIRST[SK[i], SU[i]] = SF[i]
    for (key in PRESENT) {
        split(key, kp, SUBSEP)
        nm = PRESENT[key]; gsub(/ /, "_", nm)
        printf "SEEN %s %s %s %s\n", kp[1], kp[2], nm, ((key in FIRST) ? FIRST[key] : now) > statef
    }

    if (minbdevs != "" && NB < minbdevs + 0) {
        GONETXT = GONETXT "\n&red " NB " backing device(s) found, BCACHE_MIN_BDEVS expects at least " minbdevs
        problem("red", NB " of " minbdevs " backing devices")
    }

    # --- cache sets -----------------------------------------------------
    for (i = 1; i <= NS; i++) {
        s = SID[i]; s8 = short(s)
        color = "green"
        msg = ""
        avail = A["S", s, "cache_available_percent"]
        inuse = (avail ~ /^[0-9]+$/) ? 100 - avail : ""
        cut = A["S", s, "internal/cutoff_writeback"]
        cutsync = A["S", s, "internal/cutoff_writeback_sync"]

        if (A["S", s, "internal/io_disable"] == "1") {
            color = worse(color, "red")
            msg = msg "\n    io_disable is set: the cache set has been disabled after I/O errors"
            problem("red", "cache set " s8 " disabled")
        }
        if (inuse != "" && cutsync ~ /^[0-9]+$/ && inuse > cutsync + 0 && WBSET[s]) {
            color = worse(color, cutsynccolor)
            msg = msg "\n    " inuse "% in use is above cutoff_writeback_sync (" cutsync "%): no write is cached any more, all go to the backing devices"
            problem(cutsynccolor, "cache set " s8 " " inuse "% in use, writeback caching off")
        } else if (inuse != "" && cut ~ /^[0-9]+$/ && inuse > cut + 0 && WBSET[s]) {
            color = worse(color, cutcolor)
            msg = msg "\n    " inuse "% in use is above cutoff_writeback (" cut "%): only synchronous writes are cached"
            problem(cutcolor, "cache set " s8 " " inuse "% in use")
        }

        dh = delta(s8 "_hits", A["S", s, "stats_total/cache_hits"])
        dm = delta(s8 "_misses", A["S", s, "stats_total/cache_misses"])
        dbh = delta(s8 "_bphits", A["S", s, "stats_total/cache_bypass_hits"])
        dbm = delta(s8 "_bpmisses", A["S", s, "stats_total/cache_bypass_misses"])
        hit = (dh != "" && dm != "" && dh + dm > 0) ? sprintf("%.1f", 100 * dh / (dh + dm)) : ""
        if (hit != "" && dh + dm >= hitminreq + 0) {
            if (hitred != "" && hit + 0 < hitred + 0) {
                color = worse(color, "red")
                msg = msg "\n    hit ratio " hit "% is below " hitred "% (BCACHE_HIT_RED)"
                problem("red", "cache set " s8 " hit ratio " hit "%")
            } else if (hityellow != "" && hit + 0 < hityellow + 0) {
                color = worse(color, "yellow")
                msg = msg "\n    hit ratio " hit "% is below " hityellow "% (BCACHE_HIT_YELLOW)"
                problem("yellow", "cache set " s8 " hit ratio " hit "%")
            }
        }
        ncv(s8 "_hitpct", hit)
        if (dh != "") ncv(s8 "_hits", sprintf("%.2f", dh / dt))
        if (dm != "") ncv(s8 "_misses", sprintf("%.2f", dm / dt))
        if (dbh != "") ncv(s8 "_bphits", sprintf("%.2f", dbh / dt))
        if (dbm != "") ncv(s8 "_bpmisses", sprintf("%.2f", dbm / dt))
        ncv(s8 "_inuse", inuse)
        if (cut ~ /^[0-9]+$/) ncv(s8 "_cutwb", cut)
        if (cutsync ~ /^[0-9]+$/) ncv(s8 "_cutsync", cutsync)
        if (internal == "yes") {
            if (A["S", s, "internal/btree_used_percent"] ~ /^[0-9]+$/) ncv(s8 "_btused", A["S", s, "internal/btree_used_percent"])
            if (A["S", s, "root_usage_percent"] ~ /^[0-9]+$/) ncv(s8 "_btroot", A["S", s, "root_usage_percent"])
        }

        txt = sprintf("Cache set %s  (graphs: %s)", s, s8)
        txt = txt "\n    " A["S", s, "nbdev"] " backing device(s) attached, on error: " selected(A["S", s, "errors"]) ", io_error_limit " A["S", s, "io_error_limit"]
        if (inuse != "")
            txt = txt "\n    " inuse "% in use (writeback caching is reduced above " cut "% and stops above " cutsync "%)"
        if (A["S", s, "stats_total/cache_hit_ratio"] != "")
            txt = txt "\n    hit ratio " A["S", s, "stats_total/cache_hit_ratio"] "% total" (hit != "" ? ", " hit "% since the previous poll" : "")
        SCOLOR[s] = color
        STXT[s] = txt msg
    }

    # --- cache devices --------------------------------------------------
    for (i = 1; i <= NC; i++) {
        cd = CID[i]
        s = cd; sub(/\/.*/, "", s)
        n = cd; sub(/.*\/cache/, "", n)
        c8 = short(s) (n == "0" ? "" : "c" n)
        color = "green"
        msg = ""
        if (A["C", cd, "io_errors"] ~ /^[0-9]+$/ && A["C", cd, "io_errors"] > 0) {
            color = ioerrcolor
            msg = "\n    " A["C", cd, "io_errors"] " I/O error(s) on the cache device (decayed by io_error_halflife)"
            problem(ioerrcolor, "cache device " A["C", cd, "sysname"] " I/O errors")
        }
        st = A["C", cd, "stat"]
        rd = rate(delta(c8 "_ssdrdsec", statf(st, 3)))
        wr = rate(delta(c8 "_ssdwrsec", statf(st, 7)))
        if (rd != "") ncv(c8 "_ssdrd", sprintf("%.3f", rd * 512 / 1048576))
        if (wr != "") ncv(c8 "_ssdwr", sprintf("%.3f", wr * 512 / 1048576))
        txt = sprintf("    &%s cache device %s, %s buckets, %s written", color, A["C", cd, "sysname"], A["C", cd, "nbuckets"], A["C", cd, "written"])
        if (A["C", cd, "priority_stats.unused"] != "") {
            txt = txt "\n      buckets: unused " A["C", cd, "priority_stats.unused"] ", clean " A["C", cd, "priority_stats.clean"] ", dirty " A["C", cd, "priority_stats.dirty"] ", metadata " A["C", cd, "priority_stats.metadata"]
            split("unused clean dirty metadata", pn, " ")
            split("bkunused bkclean bkdirty bkmeta", pm, " ")
            for (k = 1; k <= 4; k++) {
                v = A["C", cd, "priority_stats." pn[k]]
                sub(/%$/, "", v)
                if (v ~ /^[0-9]+$/) ncv(c8 "_" pm[k], v)
            }
        }
        SCOLOR[s] = worse(SCOLOR[s], color)
        CTXT[s] = CTXT[s] "\n" txt msg
    }

    # --- backing devices ------------------------------------------------
    for (i = 1; i <= NB; i++) {
        b = BID[i]; s8 = short(b)
        state = A["B", b, "state"]
        running = A["B", b, "running"]
        mode = selected(A["B", b, "cache_mode"])
        set = A["B", b, "cset"]
        name = (A["B", b, "bcname"] != "") ? A["B", b, "bcname"] : "(no bcache device)"
        color = "green"
        msg = ""

        if (state == "inconsistent") {
            color = worse(color, "red")
            msg = msg "\n    state \"inconsistent\": the device was forced to run while its cache held dirty data - data on it is probably corrupted"
            problem("red", name " inconsistent")
        }
        if ((state == "clean" || state == "dirty") && set == "") {
            color = worse(color, "red")
            msg = msg "\n    state \"" state "\" but not attached to any cache set - the cache device is missing" (state == "dirty" ? " and holds dirty data of this device" : "")
            problem("red", A["B", b, "sysname"] " without its cache set")
        }
        if (running == "0") {
            color = worse(color, "red")
            msg = msg "\n    not running: no /dev/bcacheN exists for it (waiting for its cache set?)"
            problem("red", A["B", b, "sysname"] " not running")
        }
        if (A["B", b, "io_disable"] == "1") {
            color = worse(color, "red")
            msg = msg "\n    io_disable is set: I/O to this device is refused"
            problem("red", name " io_disable")
        }
        if (A["B", b, "io_errors"] ~ /^[0-9]+$/ && A["B", b, "io_errors"] > 0) {
            color = worse(color, ioerrcolor)
            msg = msg "\n    " A["B", b, "io_errors"] " I/O error(s) on the backing device"
            problem(ioerrcolor, name " I/O errors")
        }
        if (state == "no cache") {
            color = worse(color, nocachecolor)
            msg = msg "\n    state \"no cache\": not attached to a cache set"
            problem(nocachecolor, name " not cached")
        }
        if (wantmode != "" && mode != wantmode && state != "no cache") {
            color = worse(color, modecolor)
            msg = msg "\n    cache_mode is " mode ", expected " wantmode " (BCACHE_MODE)"
            problem(modecolor, name " in " mode " mode")
        }
        if (mode == "writeback" && A["B", b, "writeback_running"] == "0") {
            color = worse(color, "yellow")
            msg = msg "\n    writeback_running is 0: dirty data is never written back"
            problem("yellow", name " writeback stopped")
        }

        # metrics
        dirty = h2n(A["B", b, "dirty_data"])
        target = h2n(A["B", b, "writeback_rate_debug.target"])
        wbrate = h2n(A["B", b, "writeback_rate"])
        dh = delta(s8 "_hits", A["B", b, "stats_total/cache_hits"])
        dm = delta(s8 "_misses", A["B", b, "stats_total/cache_misses"])
        hit = (dh != "" && dm != "" && dh + dm > 0) ? sprintf("%.1f", 100 * dh / (dh + dm)) : ""
        st = A["B", b, "stat"]
        rdops = rate(delta(s8 "_rdios", statf(st, 1)))
        rdsec = rate(delta(s8 "_rdsec", statf(st, 3)))
        wrops = rate(delta(s8 "_wrios", statf(st, 5)))
        wrsec = rate(delta(s8 "_wrsec", statf(st, 7)))
        ncv(s8 "_hitpct", hit)
        if (dirty != "") ncv(s8 "_dirty", sprintf("%.2f", dirty / 1073741824))
        if (target != "" && mode == "writeback") ncv(s8 "_target", sprintf("%.2f", target / 1073741824))
        if (wbrate != "" && mode == "writeback") ncv(s8 "_wbrate", sprintf("%.1f", wbrate / 1024))
        if (rdsec != "") ncv(s8 "_rdbytes", sprintf("%.3f", rdsec * 512 / 1048576))
        if (wrsec != "") ncv(s8 "_wrbytes", sprintf("%.3f", wrsec * 512 / 1048576))
        if (rdops != "") ncv(s8 "_rdops", sprintf("%.1f", rdops))
        if (wrops != "") ncv(s8 "_wrops", sprintf("%.1f", wrops))

        label = A["B", b, "label"]
        gsub(/[^A-Za-z0-9._-]/, "_", label)
        txt = sprintf("&%s %s  %s  %s%s  %s  %s", color, name, A["B", b, "sysname"], s8,
            (label != "" ? " (" label ")" : ""), mode, state)
        if (dirty != "" && state != "no cache")
            txt = txt "  dirty " A["B", b, "dirty_data"] (target != "" && mode == "writeback" ? " (target " A["B", b, "writeback_rate_debug.target"] ")" : "")
        if (A["B", b, "stats_total/cache_hit_ratio"] != "")
            txt = txt "  hits " A["B", b, "stats_total/cache_hit_ratio"] "% total" (hit != "" ? ", " hit "% last poll" : "")
        BTXT[b] = txt msg
        BSET[b] = set
    }

    # --- status page ----------------------------------------------------
    printf "<!-- ncv_skipstart -->\n" > statusf
    if (GONETXT != "") printf "%s\n\n", substr(GONETXT, 2) > statusf
    for (i = 1; i <= NS; i++) {
        s = SID[i]
        printf "&%s %s%s\n", SCOLOR[s], STXT[s], CTXT[s] > statusf
        for (j = 1; j <= NB; j++)
            if (BSET[BID[j]] == s) printf "%s\n", BTXT[BID[j]] > statusf
        printf "\n" > statusf
    }
    nfree = 0
    for (j = 1; j <= NB; j++) {
        b = BID[j]
        if (BSET[b] != "" && (("S", BSET[b]) in HAVE)) continue
        if (nfree++ == 0) printf "Backing devices without a cache set:\n" > statusf
        printf "%s\n", BTXT[b] > statusf
    }
    if (nfree) printf "\n" > statusf
    if (PREVT == "")
        printf "First poll (or no state file from the previous one): hit ratios, request and I/O rates appear from the next poll on.\n" > statusf
    printf "<!-- ncv_skipend -->\n" > statusf

    # summary for the status line, and the color for the shell
    if (NPROB > 0)
        summary = FIRSTPROB (NPROB > 1 ? " (+" NPROB - 1 " more)" : "")
    else
        summary = NS " cache set(s), " NB " backing device(s), all OK"
    printf "%s %s\n", WORST, summary
}' > "$WORKDIR/result"

read -r COLOR SUMMARY < "$WORKDIR/result" || {
    COLOR=yellow
    SUMMARY="evaluation failed"
    printf 'The evaluation of the bcache attributes failed.\n' > "$STATUS"
}
case "$COLOR" in
    red|yellow|green) ;;
    *) COLOR=yellow ;;
esac

# Remember this run's counters and devices (best effort - a read-only
# state directory only costs the rates and the vanished-device check).
if [ -s "$NEWSTATE" ]; then
    if { cat "$NEWSTATE" > "${STATEFILE}.$$"; } 2>/dev/null; then
        if ! mv "${STATEFILE}.$$" "$STATEFILE" 2>/dev/null; then
            rm -f "${STATEFILE}.$$"
            printf '\n&yellow cannot write the state file %s\n' "$STATEFILE" >> "$STATUS"
            [ "$COLOR" = red ] || COLOR=yellow
        fi
    else
        rm -f "${STATEFILE}.$$" 2>/dev/null
        printf '\n&yellow cannot write the state file %s - rates and the vanished-device check do not work\n' "$STATEFILE" >> "$STATUS"
        [ "$COLOR" = red ] || COLOR=yellow
    fi
fi

send_report "$COLOR" "$STATUS" "$DATA"
exit 0
