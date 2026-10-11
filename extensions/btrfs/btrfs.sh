#!/bin/sh
#
# btrfs.sh -- Xymon client extension: btrfs filesystem health
#
# Reports every mounted btrfs filesystem of a host in one "btrfs"
# column:
#
#   - state: a missing or read-only member device, a filesystem that
#     the kernel has switched to read-only, a "degraded" mount
#   - device error counters (write/read/flush/corruption/generation,
#     the same numbers as "btrfs device stats"): yellow while a counter
#     is above zero, red for BTRFS_ERR_HOLD seconds after it grew
#   - space the way btrfs needs it: unallocated space on the devices,
#     and how full the metadata chunks are once no new metadata chunk
#     can be allocated any more - the classic btrfs ENOSPC, which "df"
#     does not show
#   - the last scrub: age, and with root rights its result
#   - performance: throughput, IOPS and device utilisation of the
#     member devices, transaction commits and their duration
#
# Almost everything comes from sysfs (/sys/fs/btrfs/<uuid>/, readable
# by every user) and /proc - no root rights needed:
#
#   allocation/{data,metadata,system}/   space per block group type
#                                        (kernel 5.14+; the totals
#                                        since 3.14)
#   allocation/global_rsv_size           global reserve (metadata)
#   devinfo/<devid>/error_stats          device error counters (5.14+)
#   devinfo/<devid>/{missing,writeable}  device state (5.6+)
#   exclusive_operation                  running balance/replace/... (5.10+)
#   commit_stats                         transaction commits (6.0+)
#   devices/<name> -> block device       member devices and their size
#
# Source: btrfs-progs Documentation/ch-sysfs.rst. Two values need
# btrfs-progs:
#
#   - the device size: "btrfs filesystem usage -b" (works as an
#     ordinary user). Without btrfs-progs the size of the block devices
#     is used, which is the same unless the filesystem was shrunk with
#     "btrfs filesystem resize".
#   - the scrub result: "btrfs scrub status -R" needs root. As root
#     (OpenWrt/TurrisOS standalone runner) it is used directly, as user
#     xymon only via sudo (BTRFS_SUDO="yes", see sudoers.example).
#     Without it, the modification time of btrfs-progs' scrub status
#     file in /var/lib/btrfs still gives the age of the last scrub.
#
# Per filesystem the data message carries the metrics for split-NCV
# RRD files named btrfs,<fs>_<metric>.rrd (see server/README.md).
#
# Linux only; other platforms and hosts without a mounted btrfs report
# "clear".
#
# Configuration: environment variables and/or
# $XYMONHOME/etc/my-xymon-extensions/btrfs.cfg (see the shipped
# btrfs.cfg; the config file wins over the environment).

set -u

# Every number in a Xymon message must use a decimal point; awk formats
# floating point numbers according to LC_NUMERIC.
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
# Defaults -- every value can be set in the environment or in btrfs.cfg
# ----------------------------------------------------------------------
BTRFS_ENABLE="${BTRFS_ENABLE:-yes}"
BTRFS_COLUMN="${BTRFS_COLUMN:-btrfs}"
BTRFS_NAMES="${BTRFS_NAMES:-}"              # "<uuid>=<name> ..."
BTRFS_EXCLUDE="${BTRFS_EXCLUDE:-}"          # uuid/name globs
BTRFS_RO_OK="${BTRFS_RO_OK:-}"              # uuid/name globs
BTRFS_UNALLOC_WARN="${BTRFS_UNALLOC_WARN-5}"  # percent of the device size
BTRFS_UNALLOC_CRIT="${BTRFS_UNALLOC_CRIT-}"
BTRFS_META_WARN="${BTRFS_META_WARN-75}"     # percent, see btrfs.cfg
BTRFS_META_CRIT="${BTRFS_META_CRIT-90}"
BTRFS_ERR_COLOR="${BTRFS_ERR_COLOR:-yellow}"
BTRFS_ERR_NEW_COLOR="${BTRFS_ERR_NEW_COLOR:-red}"
BTRFS_ERR_HOLD="${BTRFS_ERR_HOLD:-1800}"
BTRFS_SCRUB_MAXAGE="${BTRFS_SCRUB_MAXAGE-35}"  # days, empty/0 = off
BTRFS_SCRUB_COLOR="${BTRFS_SCRUB_COLOR:-yellow}"
BTRFS_SUDO="${BTRFS_SUDO:-no}"
BTRFS_CMD="${BTRFS_CMD:-}"                  # path of btrfs(8), auto
# Where the data comes from (overridable mainly for the unit tests).
BTRFS_SYSFS="${BTRFS_SYSFS:-/sys/fs/btrfs}"
BTRFS_MOUNTS="${BTRFS_MOUNTS:-/proc/mounts}"
BTRFS_DISKSTATS="${BTRFS_DISKSTATS:-/proc/diskstats}"
BTRFS_SCRUBDIR="${BTRFS_SCRUBDIR:-/var/lib/btrfs}"
# Test hooks: the user id that decides about root rights, and the sudo
# command line.
BTRFS_UID="${BTRFS_UID:-$(id -u)}"
BTRFS_SUDOCMD="${BTRFS_SUDOCMD:-sudo -n}"

# Own subdirectory since 0.20.0 ($XYMONHOME/etc is shared with the
# Xymon server and hobbit-plugins); the old place is the fallback.
CFGFILE="${BTRFS_CFG:-}"
if [ -z "$CFGFILE" ] && [ -n "$XYMONHOME" ]; then
    CFGFILE="$XYMONHOME/etc/my-xymon-extensions/btrfs.cfg"
    [ -f "$CFGFILE" ] || CFGFILE="$XYMONHOME/etc/btrfs.cfg"
fi
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi
COLUMN="$BTRFS_COLUMN"

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# is_yes <value> -> true for the usual affirmative config spellings
is_yes() {
    case "${1:-}" in
        1|y|Y|yes|Yes|YES|true|True|TRUE|on|On|ON) return 0 ;;
    esac
    return 1
}

# is_num <value> -> true for a non-negative decimal number
is_num() {
    case "${1:-}" in
        ''|.|*[!0-9.]*|*.*.*) return 1 ;;
    esac
    return 0
}

# color_or <value> <default> -> the value if it is green/yellow/red
color_or() {
    case "${1:-}" in
        green|yellow|red) printf '%s' "$1" ;;
        *) printf '%s' "$2" ;;
    esac
}

# sanitize <text> -> lowercase, [a-z0-9_] only, squeezed and trimmed
sanitize() {
    # shellcheck disable=SC2018,SC2019  # NOT '[:upper:]'/'[:lower:]': BusyBox
    # tr does not recognize the class syntax and translates it letter-by-
    # letter as the literal string "[:upper:]" instead.
    s_out=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '_' | tr -s '_')
    s_out=${s_out#_}
    printf '%s' "${s_out%_}"
}

# attr <file> -> first line of a sysfs attribute, empty if unreadable
attr() {
    a_val=""
    if [ -f "$1" ] && [ -r "$1" ]; then
        read -r a_val < "$1" 2>/dev/null || a_val=""
    fi
    printf '%s' "$a_val"
}

# match_any <name> <pattern-list> -> true if one space-separated glob
# pattern of the list matches the name
match_any() {
    ma_name=$1
    # shellcheck disable=SC2086  # the list is a pattern list on purpose
    for ma_p in $2; do
        # shellcheck disable=SC2254  # glob matching is the point here
        case "$ma_name" in
            $ma_p) return 0 ;;
        esac
    done
    return 1
}

# send_report <color> <status-body-file> [data-body-file]
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - btrfs: ${SUMMARY:-$1}

$(cat "$2")"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            "$XYMON" "$XYMSRV" "data ${MACHINE}.${COLUMN}
$(cat "$3")"
        fi
    else
        # No Xymon environment: print the messages (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - btrfs: ${SUMMARY:-$1}"
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

is_num "$BTRFS_ERR_HOLD" || BTRFS_ERR_HOLD=1800

WORKDIR=$(mktemp -d "${XYMONTMP}/btrfs.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

SUMMARY=""

clear_report() {
    SUMMARY="$1"
    {
        printf '<!-- ncv_skipstart -->\n'
        printf '%s\n' "$2"
        printf '<!-- ncv_skipend -->\n'
    } > "$WORKDIR/clear"
    send_report clear "$WORKDIR/clear"
    exit 0
}

is_yes "$BTRFS_ENABLE" ||
    clear_report "disabled" "Switched off with BTRFS_ENABLE=\"$BTRFS_ENABLE\" in btrfs.cfg."

case "$(uname -s)" in
    Linux) ;;
    *) clear_report "not applicable" "btrfs is a Linux filesystem - test not applicable on $(uname -s)." ;;
esac

# --- the filesystems: one directory per mounted filesystem in sysfs ----
for u in "$BTRFS_SYSFS"/*-*-*-*-*; do
    [ -d "$u/allocation" ] || continue
    printf '%s\n' "${u##*/}" >> "$WORKDIR/uuids"
done
[ -s "$WORKDIR/uuids" ] ||
    clear_report "not applicable" "No btrfs filesystem is mounted on this host ($BTRFS_SYSFS lists none)."

# --- which device belongs to which filesystem ----------------------------
: > "$WORKDIR/devmap"
while IFS= read -r uuid; do
    for d in "$BTRFS_SYSFS/$uuid/devices"/*; do
        [ -e "$d" ] || continue
        printf '%s %s\n' "${d##*/}" "$uuid" >> "$WORKDIR/devmap"
    done
done < "$WORKDIR/uuids"

# --- mounts: "<uuid> <options> <mount point>" ----------------------------
# The mount source names one member device (/dev/nvme1n1p3); a device
# mapper path (/dev/mapper/x -> ../dm-0) is resolved to the name sysfs
# uses. /proc/mounts encodes blanks in paths as octal escapes.
TAB=$(printf '\t')
awk -v OFS="$TAB" '$3 == "btrfs" {
        m = $2
        gsub(/\\040/, " ", m); gsub(/\\011/, "\t", m)
        gsub(/\\012/, "\n", m); gsub(/\\134/, "\\", m)
        print $1, $4, m
    }' "$BTRFS_MOUNTS" 2>/dev/null > "$WORKDIR/btrfsmounts"

: > "$WORKDIR/mounts"
: > "$WORKDIR/unmatched"
while IFS="$TAB" read -r src opts mnt; do
    [ -n "$mnt" ] || continue
    dev=${src##*/}
    if [ -L "$src" ]; then
        tgt=$(readlink "$src" 2>/dev/null) && dev=${tgt##*/}
    fi
    uuid=$(awk -v d="$dev" '$1 == d { print $2; exit }' "$WORKDIR/devmap")
    if [ -n "$uuid" ]; then
        printf '%s %s %s\n' "$uuid" "$opts" "$mnt" >> "$WORKDIR/mounts"
    else
        printf '%s %s\n' "$opts" "$mnt" >> "$WORKDIR/unmatched"
    fi
done < "$WORKDIR/btrfsmounts"

# A source sysfs does not know (/dev/root on some embedded systems)
# can only belong to a filesystem without any other mount.
if [ -s "$WORKDIR/unmatched" ]; then
    : > "$WORKDIR/nomount"
    while IFS= read -r uuid; do
        awk -v u="$uuid" '$1 == u { f = 1 } END { exit f }' "$WORKDIR/mounts" &&
            printf '%s\n' "$uuid" >> "$WORKDIR/nomount"
    done < "$WORKDIR/uuids"
    if [ "$(wc -l < "$WORKDIR/nomount" | tr -d ' ')" = 1 ]; then
        uuid=$(cat "$WORKDIR/nomount")
        while IFS= read -r line; do
            printf '%s %s\n' "$uuid" "$line" >> "$WORKDIR/mounts"
        done < "$WORKDIR/unmatched"
    fi
fi

# --- btrfs-progs and privileges for "scrub status" -----------------------
BTRFS="$BTRFS_CMD"
if [ -z "$BTRFS" ]; then
    BTRFS=$(PATH="$PATH:/usr/sbin:/sbin:/usr/bin:/bin" command -v btrfs 2>/dev/null) || BTRFS=""
fi
[ -n "$BTRFS" ] && [ ! -x "$BTRFS" ] && BTRFS=""

SCRUBVIA=""                 # how "scrub status" is run: root, sudo or ""
if [ -n "$BTRFS" ]; then
    if [ "$BTRFS_UID" = 0 ]; then
        SCRUBVIA=root
    elif is_yes "$BTRFS_SUDO"; then
        SCRUBVIA=sudo
    fi
fi

# Local time offset for the "Scrub started" time stamp of btrfs-progs
# (local time, ctime format).
TZOFF=$(date +%z 2>/dev/null)
case "$TZOFF" in
    [+-][0-9][0-9][0-9][0-9]) ;;
    *) TZOFF="+0000" ;;
esac

NOW=$(date +%s)
STATEFILE="${XYMONTMP}/btrfs.${MACHINE}.state"
[ -r "$STATEFILE" ] || STATEFILE="$WORKDIR/nostate"
: > "$WORKDIR/newstate"
: > "$WORKDIR/data"
: > "$WORKDIR/body"
: > "$WORKDIR/issues"
: > "$WORKDIR/colors"
: > "$WORKDIR/names"

# --- the evaluation, one awk run per filesystem --------------------------
# Input: the facts collected below ("key values..." lines) and the
# state file of the previous run. Output lines:
#   S <text>            status text
#   N <metric> <value>  data message (split-NCV)
#   T <state line>      state for the next run
#   X <text>            issue for the summary line
#   C <color>           color of this filesystem
cat > "$WORKDIR/eval.awk" <<'EOF'
function hs(b,   u, i) {
    split("B KiB MiB GiB TiB PiB EiB", u, " ")
    i = 1
    while (b >= 1024 && i < 7) { b /= 1024; i++ }
    return (i == 1) ? sprintf("%d B", b) : sprintf("%.2f %s", b, u[i])
}
function isnum(x) { return x ~ /^[0-9]+(\.[0-9]+)?$/ }
function rest(k,   s, i) {
    s = $0
    for (i = 1; i < k; i++) sub(/^[^ ]* /, "", s)
    return s
}
function setcolor(c) {
    if (rank[c] > rank[color]) color = c
}
function line(c, text) {
    if (c == "") out[++nout] = "   " text
    else { out[++nout] = "&" c " " text; setcolor(c) }
}
function issue(t) { issues = issues (issues == "" ? "" : ", ") t }
BEGIN {
    rank["green"] = 0; rank["yellow"] = 1; rank["red"] = 2
    color = "green"; nout = 0; issues = ""
    while ((getline sl < statefile) > 0) {
        n = split(sl, f, " ")
        if (f[2] != uuid) continue
        if (f[1] == "P" && n >= 9) {
            pts = f[3]; prd = f[4]; prs = f[5]; pwr = f[6]; pws = f[7]
            pcm = f[8]; pcms = f[9]; havep = 1
        } else if (f[1] == "B" && n >= 4) {
            pticks[f[3]] = f[4]; npb++
        } else if (f[1] == "E" && n >= 5) {
            perr[f[3]] = f[4]; pinc[f[3]] = f[5]
        }
    }
    close(statefile)
}
$1 == "mount"   { nm++; mopts[nm] = $2; mpath[nm] = rest(3) }
$1 == "label"   { label = rest(2) }
$1 == "dev"     { nd++; dname[nd] = $2; dsize[nd] = $3; drd[nd] = $4
                  drs[nd] = $5; dwr[nd] = $6; dws[nd] = $7; dtk[nd] = $8 }
$1 == "cmdsize" { cmdsize = $2 }
$1 == "alloc"   { at[$2] = $3; au[$2] = $4; adt[$2] = $5; acs[$2] = $6
                  havealloc[$2] = 1 }
$1 == "profile" { prof[$2] = prof[$2] (prof[$2] == "" ? "" : "+") toupper($3); nprof[$2]++ }
$1 == "rsv"     { rsv = $2 }
$1 == "devinfo" { ni++; iid[ni] = $2; imiss[ni] = $3; iwr[ni] = $4; irep[ni] = $5
                  for (k = 6; k <= 10; k++) ierr[ni, k - 5] = $k }
$1 == "excl"    { excl = $2 }
$1 == "commit"  { havecommit = 1; ccount = $2; clast = $3; cmax = $4; ctotal = $5 }
$1 == "scrub"   { sk[$2] = rest(3) }
END {
    # --- mounts -----------------------------------------------------
    mounts = ""; nro = 0; deg = 0
    for (i = 1; i <= nm; i++) {
        mounts = mounts (i > 1 ? " " : "") mpath[i]
        o = "," mopts[i] ","
        if (o ~ /,ro,/) nro++
        if (o ~ /,degraded,/) deg = 1
    }
    if (nm == 0) mounts = "(no mount point found)"
    devs = ""
    for (i = 1; i <= nd; i++) devs = devs (i > 1 ? " " : "") dname[i]
    title = name "  " mounts
    if (label != "" && label != name) title = title "  label " label
    title = title "  (" uuid ")"

    # The "mixed" block group type of small filesystems holds data and
    # metadata together.
    if (!havealloc["data"] && havealloc["mixed"]) {
        at["data"] = at["mixed"]; au["data"] = au["mixed"]
        adt["data"] = adt["mixed"]; prof["data"] = prof["mixed"]
        nprof["data"] = nprof["mixed"]
    }
    if (!havealloc["metadata"] && havealloc["mixed"]) {
        at["metadata"] = at["mixed"]; au["metadata"] = au["mixed"]
        adt["metadata"] = adt["mixed"]; acs["metadata"] = acs["mixed"]
        prof["metadata"] = prof["mixed"]; nprof["metadata"] = nprof["mixed"]
        mixed = 1
    }

    line("", "Devices: " nd " (" devs ")   Profiles: data " prof["data"] \
        ", metadata " prof["metadata"] ", system " prof["system"])

    # --- state ------------------------------------------------------
    if (nm > 0 && nro == nm) {
        if (ro_ok) line("", "Mounted read-only (allowed by BTRFS_RO_OK)")
        else {
            line("red", "Read-only: every mount of this filesystem is read-only - after an error the kernel switches btrfs to read-only")
            issue("read-only")
        }
    }
    if (deg) {
        line("red", "Mounted degraded: the filesystem runs without all of its devices")
        issue("degraded")
    }
    for (i = 1; i <= ni; i++) {
        if (imiss[i] == "1") {
            line("red", "devid " iid[i] ": device missing")
            issue("devid " iid[i] " missing")
        } else if (iwr[i] == "0") {
            line("red", "devid " iid[i] ": device not writeable")
            issue("devid " iid[i] " not writeable")
        }
        if (irep[i] == "1") line("", "devid " iid[i] ": target of a running device replace")
    }
    if (excl != "" && excl != "none")
        line("", "Running exclusive operation: " excl)

    # --- device errors ----------------------------------------------
    split("write read flush corruption generation", ename, " ")
    errtotal = 0; noerr = ""; errknown = 0
    for (i = 1; i <= ni; i++) {
        id = iid[i]
        if (!isnum(ierr[i, 1])) continue
        errknown = 1
        sum = 0; txt = ""
        for (k = 1; k <= 5; k++) {
            sum += ierr[i, k]
            if (ierr[i, k] > 0) txt = txt (txt == "" ? "" : ", ") ename[k] " " ierr[i, k]
        }
        errtotal += sum
        inc = (id in pinc && isnum(pinc[id])) ? pinc[id] : 0
        note = ""
        if (id in perr && isnum(perr[id])) {
            if (sum > perr[id]) { inc = now; note = " - grew by " (sum - perr[id]) " since the previous poll" }
            else if (sum < perr[id]) inc = 0     # reset with "btrfs device stats -z"
        }
        print "T E " uuid " " id " " sum " " inc
        if (sum == 0) { noerr = noerr (noerr == "" ? "" : " ") id; continue }
        if (inc > 0 && now - inc <= errhold) {
            if (note == "") note = " - grew " int((now - inc) / 60) " min ago"
            line(errnewcolor, "devid " id ": " txt note)
            if (errnewcolor != "green") issue("device errors on devid " id " growing")
        } else {
            line(errcolor, "devid " id ": " txt " (counters since creation or the last reset with \"btrfs device stats -z\")")
            if (errcolor != "green") issue("device errors on devid " id)
        }
    }
    if (!errknown) line("", "Device errors: not available (devinfo/<devid>/error_stats needs kernel 5.14)")
    else if (noerr != "") line("", "Device errors: none on devid " noerr)

    # --- space ------------------------------------------------------
    devsize = 0
    for (i = 1; i <= nd; i++) if (isnum(dsize[i])) devsize += dsize[i]
    sizesrc = "block devices"
    if (isnum(cmdsize) && cmdsize > 0) { devsize = cmdsize; sizesrc = "btrfs filesystem usage" }
    allocated = adt["data"] + (mixed ? 0 : adt["metadata"]) + adt["system"]
    unalloc = devsize - allocated
    if (unalloc < 0) unalloc = 0
    unpct = (devsize > 0) ? unalloc * 100 / devsize : 0
    dratio = (at["data"] > 0) ? adt["data"] / at["data"] : 1
    mratio = (at["metadata"] > 0) ? adt["metadata"] / at["metadata"] : 1
    datapct = (at["data"] > 0) ? au["data"] * 100 / at["data"] : 0
    metaused = au["metadata"] + rsv
    metapct = (at["metadata"] > 0) ? metaused * 100 / at["metadata"] : 0
    free = at["data"] - au["data"] + unalloc / dratio
    if (free < 0) free = 0
    mchunk = isnum(acs["metadata"]) ? acs["metadata"] : 268435456
    need = mchunk * mratio
    room = (unalloc >= need)

    line("", sprintf("Size: %s, allocated %s, unallocated %s (%.1f %%)   [device size from %s]", \
        hs(devsize), hs(allocated), hs(unalloc), unpct, sizesrc))
    if (isnum(unalcrit) && unpct < unalcrit + 0) {
        line("red", sprintf("Unallocated space below %s %% - btrfs can hardly allocate new chunks", unalcrit))
        issue("unallocated " sprintf("%.1f %%", unpct))
    } else if (isnum(unalwarn) && unpct < unalwarn + 0) {
        line("yellow", sprintf("Unallocated space below %s %% - btrfs can hardly allocate new chunks", unalwarn))
        issue("unallocated " sprintf("%.1f %%", unpct))
    }
    line("", sprintf("Data: %s used of %s allocated (%.1f %%), free (estimated) %s", \
        hs(au["data"]), hs(at["data"]), datapct, hs(free)))
    mtxt = sprintf("Metadata: %s used + %s global reserve of %s allocated (%.1f %%)", \
        hs(au["metadata"]), hs(rsv), hs(at["metadata"]), metapct)
    mcol = ""
    if (room) mtxt = mtxt " - can grow into unallocated space"
    else {
        mtxt = mtxt " - NO room for a new metadata chunk (needs " hs(need) " unallocated)"
        if (isnum(metacrit) && metapct >= metacrit + 0) { mcol = "red"; mtxt = mtxt "  [red >= " metacrit " %]" }
        else if (isnum(metawarn) && metapct >= metawarn + 0) { mcol = "yellow"; mtxt = mtxt "  [yellow >= " metawarn " %]" }
        if (mcol != "") issue(sprintf("metadata %.1f %% full", metapct))
    }
    line(mcol, mtxt)
    if (havealloc["system"])
        line("", sprintf("System: %s used of %s allocated", hs(au["system"]), hs(at["system"])))
    # Partly used data chunks are what a filtered balance gives back.
    slack = at["data"] - au["data"]
    if ((mcol != "" || unpct < unalwarn + 0) && slack >= 2 * mchunk * dratio && nm > 0)
        line("", sprintf("Hint: %s of the data chunks are unused; \"btrfs balance start -dusage=10 %s\" (then 25, 50) returns partly used data chunks to the unallocated space", \
            hs(slack), mpath[1]))
    for (t in nprof) {
        if (nprof[t] > 1 && excl != "balance") {
            line("yellow", "Multiple " t " profiles (" prof[t] ") - an interrupted \"balance -convert\"?")
            issue("multiple " t " profiles")
        }
    }

    # --- scrub ------------------------------------------------------
    last = ""
    if (isnum(sk["start"])) last = sk["start"]
    else if (isnum(sk["mtime"])) last = sk["mtime"]
    age = (last != "") ? int((now - last) / 86400) : -1
    scol = ""; siss = ""
    if (sk["via"] != "") {
        if (sk["never"] == "1") stxt = "Scrub: never run (btrfs scrub status: no stats available)"
        else {
            stxt = sprintf("Scrub: last started %d day(s) ago (%s), %s", age, sk["started"], sk["status"])
            if (sk["duration"] != "") stxt = stxt " after " sk["duration"]
            if (sk["uncorr"] + 0 > 0) {
                scol = "red"; siss = "scrub found uncorrectable errors"
                stxt = stxt ", " sk["uncorr"] " UNCORRECTABLE error(s)"
            } else if (sk["errs"] + sk["corr"] > 0) {
                scol = "yellow"; siss = "scrub found errors"
                stxt = stxt ", " (sk["errs"] + 0) " error(s), " (sk["corr"] + 0) " corrected"
            } else stxt = stxt ", no errors"
            if (sk["status"] != "finished" && sk["status"] != "running") {
                if (scol == "") { scol = scrubcolor; siss = "scrub " sk["status"] }
                stxt = stxt " - did not finish"
            }
        }
    } else {
        if (last != "")
            stxt = sprintf("Scrub: last activity %d day(s) ago (modification time of %s/scrub.status.<uuid>)", age, scrubdir)
        else
            stxt = "Scrub: no record (no status file in " scrubdir ")"
        stxt = stxt ", result unknown"
    }
    if (isnum(scrubmax) && scrubmax > 0) {
        if (last == "") {
            if (scol == "") { scol = scrubcolor; siss = "never scrubbed" }
            stxt = stxt "  [" scrubcolor ": never scrubbed]"
        } else if (age > scrubmax + 0) {
            if (scol == "") { scol = scrubcolor; siss = "last scrub " age " days ago" }
            stxt = stxt "  [" scrubcolor " > " scrubmax " days]"
        }
    }
    if (sk["note"] != "") stxt = stxt " (" sk["note"] ")"
    line(scol, stxt)
    if (scol == "yellow" || scol == "red") issue(siss)

    # --- performance ------------------------------------------------
    srd = 0; srs = 0; swr = 0; sws = 0; iook = (nd > 0)
    for (i = 1; i <= nd; i++) {
        if (!isnum(drd[i])) { iook = 0; continue }
        srd += drd[i]; srs += drs[i]; swr += dwr[i]; sws += dws[i]
        if (isnum(dtk[i])) print "T B " uuid " " dname[i] " " dtk[i]
    }
    cm = havecommit ? ccount : "-"
    cms = havecommit ? ctotal : "-"
    if (iook) print "T P " uuid " " now " " srd " " srs " " swr " " sws " " cm " " cms
    else print "T P " uuid " " now " - - - - " cm " " cms
    dt = now - pts
    rates = 0
    if (havep && dt > 0) {
        if (iook && isnum(prd) && npb == nd && srd >= prd && srs >= prs && swr >= pwr && sws >= pws) {
            rbps = (srs - prs) * 512 / dt; wbps = (sws - pws) * 512 / dt
            riops = (srd - prd) / dt; wiops = (swr - pwr) / dt
            busy = 0; busydev = ""
            for (i = 1; i <= nd; i++) {
                if (!(dname[i] in pticks) || !isnum(dtk[i]) || dtk[i] < pticks[dname[i]]) continue
                b = (dtk[i] - pticks[dname[i]]) * 100 / (dt * 1000)
                if (b > 100) b = 100
                if (busydev == "" || b > busy) { busy = b; busydev = dname[i] }
            }
            line("", sprintf("I/O: read %s/s (%.1f IOPS), write %s/s (%.1f IOPS), busiest device %s %.1f %%  [member devices, RAID copies included]", \
                hs(rbps), riops, hs(wbps), wiops, busydev, busy))
            printf "N %s_read_bps %.0f\nN %s_write_bps %.0f\n", name, rbps, name, wbps
            printf "N %s_read_iops %.2f\nN %s_write_iops %.2f\n", name, riops, name, wiops
            printf "N %s_busy %.2f\n", name, busy
            rates = 1
        }
        if (havecommit && isnum(pcm) && ccount >= pcm && ctotal >= pcms) {
            dc = ccount - pcm
            avg = (dc > 0) ? (ctotal - pcms) / dc : 0
            line("", sprintf("Commits: %.1f per minute, %.0f ms on average since the previous poll; last %s ms, longest %s ms since mount", \
                dc * 60 / dt, avg, clast, cmax))
            printf "N %s_commits %.2f\nN %s_commitms %.1f\n", name, dc * 60 / dt, name, avg
            rates = 1
        }
    }
    if (!rates) {
        if (havecommit) line("", "Commits: " ccount " since mount, last " clast " ms, longest " cmax " ms")
        line("", "I/O and commit rates: shown from the next poll on")
    }

    printf "N %s_unalloc %.0f\nN %s_free %.0f\n", name, unalloc, name, free
    printf "N %s_datapct %.2f\nN %s_metapct %.2f\n", name, datapct, name, metapct
    if (errknown) printf "N %s_errors %d\n", name, errtotal

    printf "S &%s %s\n", color, title
    for (i = 1; i <= nout; i++) print "S " out[i]
    print "C " color
    if (issues != "") print "X " name ": " issues
}
EOF

while IFS= read -r uuid; do
    u="$BTRFS_SYSFS/$uuid"
    F="$WORKDIR/facts"
    : > "$F"

    # --- mount points, shortest first ---------------------------------
    awk -v u="$uuid" '$1 == u {
            o = $2; sub(/^[^ ]* [^ ]* /, ""); print length($0), o, $0
        }' "$WORKDIR/mounts" | sort -n | while read -r _len o m; do
        printf 'mount %s %s\n' "$o" "$m"
    done >> "$F"
    mnt=$(awk '$1 == "mount" { sub(/^[^ ]* [^ ]* /, ""); print; exit }' "$F")

    # --- name ---------------------------------------------------------
    label=$(attr "$u/label")
    name=""
    for e in $BTRFS_NAMES; do
        case "$e" in
            "$uuid="*) name=$(sanitize "${e#*=}") ;;
        esac
    done
    [ -n "$name" ] || name=$(sanitize "$label")
    if [ -z "$name" ]; then
        case "$mnt" in
            "")  name="" ;;
            /)   name=root ;;
            *)   name=$(sanitize "$mnt") ;;
        esac
    fi
    [ -n "$name" ] || name=$(printf '%s' "$uuid" | cut -c1-8)
    if grep -qx "$name" "$WORKDIR/names"; then
        name="${name}_$(printf '%s' "$uuid" | cut -c1-8)"
    fi
    if [ -n "$BTRFS_EXCLUDE" ] &&
        { match_any "$uuid" "$BTRFS_EXCLUDE" || match_any "$name" "$BTRFS_EXCLUDE"; }; then
        printf 'excluded %s (%s)\n' "$name" "$uuid" >> "$WORKDIR/excluded"
        continue
    fi
    printf '%s\n' "$name" >> "$WORKDIR/names"
    rook=""
    if [ -n "$BTRFS_RO_OK" ] &&
        { match_any "$uuid" "$BTRFS_RO_OK" || match_any "$name" "$BTRFS_RO_OK"; }; then
        rook=1
    fi
    printf 'label %s\n' "$label" >> "$F"

    # --- member devices: size and I/O counters ------------------------
    # diskstats fields 4, 6, 8, 10 and 13: reads and sectors read,
    # writes and sectors written, milliseconds spent doing I/O
    # (Documentation/admin-guide/iostats.rst; sectors are 512 bytes).
    for d in "$u/devices"/*; do
        [ -e "$d" ] || continue
        dn=${d##*/}
        sz=$(attr "$d/size")
        io=$(awk -v n="$dn" '$3 == n { print $4, $6, $8, $10, $13; f = 1; exit }
                END { if (!f) print "- - - - -" }' "$BTRFS_DISKSTATS" 2>/dev/null)
        [ -n "$io" ] || io="- - - - -"
        printf '%s %s\n' "$dn" "$sz" | awk -v io="$io" '{
            printf "dev %s %s %s\n", $1, ($2 ~ /^[0-9]+$/ ? sprintf("%.0f", $2 * 512) : "-"), io }' >> "$F"
    done

    # --- allocation per block group type ------------------------------
    for t in data metadata system mixed; do
        a="$u/allocation/$t"
        [ -d "$a" ] || continue
        cs=$(attr "$a/chunk_size")
        printf 'alloc %s %s %s %s %s\n' "$t" "$(attr "$a/total_bytes")" \
            "$(attr "$a/bytes_used")" "$(attr "$a/disk_total")" "${cs:--}" >> "$F"
        for p in "$a"/*; do
            [ -d "$p" ] && printf 'profile %s %s\n' "$t" "${p##*/}" >> "$F"
        done
    done
    rsv=$(attr "$u/allocation/global_rsv_size")
    printf 'rsv %s\n' "${rsv:-0}" >> "$F"

    # --- devices: state and error counters ----------------------------
    for i in "$u/devinfo"/*; do
        [ -d "$i" ] || continue
        if [ -r "$i/error_stats" ]; then
            errs=$(awk '{ v[$1] = $2 } END {
                    printf "%s %s %s %s %s", v["write_errs"], v["read_errs"],
                        v["flush_errs"], v["corruption_errs"], v["generation_errs"] }' "$i/error_stats")
        else
            errs="- - - - -"
        fi
        miss=$(attr "$i/missing"); wr=$(attr "$i/writeable"); rep=$(attr "$i/replace_target")
        printf 'devinfo %s %s %s %s %s\n' "${i##*/}" "${miss:--}" "${wr:--}" "${rep:--}" "$errs" >> "$F"
    done

    ex=$(attr "$u/exclusive_operation")
    printf 'excl %s\n' "${ex:-none}" >> "$F"
    if [ -r "$u/commit_stats" ]; then
        awk '{ v[$1] = $2 } END {
                if (v["commits"] != "")
                    printf "commit %s %s %s %s\n", v["commits"], v["last_commit_ms"],
                        v["max_commit_ms"], v["total_commit_ms"] }' "$u/commit_stats" >> "$F"
    fi

    # --- device size from btrfs-progs ----------------------------------
    if [ -n "$BTRFS" ] && [ -n "$mnt" ]; then
        "$BTRFS" filesystem usage -b "$mnt" 2>/dev/null </dev/null |
            awk '/^ *Device size:/ { print "cmdsize", $3; exit }' >> "$F"
    fi

    # --- scrub ----------------------------------------------------------
    sfile="$BTRFS_SCRUBDIR/scrub.status.$uuid"
    scrubdone=""
    if [ -n "$SCRUBVIA" ] && [ -n "$mnt" ]; then
        if [ "$SCRUBVIA" = sudo ]; then
            # shellcheck disable=SC2086  # the sudo command line is word-split on purpose
            sout=$($BTRFS_SUDOCMD "$BTRFS" scrub status -R "$mnt" 2>&1 </dev/null)
        else
            sout=$("$BTRFS" scrub status -R "$mnt" 2>&1 </dev/null)
        fi
        src=$?
        if [ "$src" -eq 0 ]; then
            printf '%s\n' "$sout" | awk -v via="$SCRUBVIA" -v tz="$TZOFF" '
                function days(y, m, d,   era, yoe, doy, doe) {
                    y -= (m <= 2)
                    era = int(y / 400)
                    yoe = y - era * 400
                    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
                    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
                    return era * 146097 + doe - 719468
                }
                BEGIN {
                    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
                    for (i = 1; i <= 12; i++) mon[mn[i]] = i
                    off = (substr(tz, 2, 2) * 3600 + substr(tz, 4, 2) * 60)
                    if (substr(tz, 1, 1) == "-") off = -off
                    errs = 0
                }
                /^Scrub (started|resumed):/ {
                    split($6, hms, ":")
                    if ($4 in mon) {
                        start = days($7, mon[$4], $5) * 86400 + hms[1] * 3600 + hms[2] * 60 + hms[3] - off
                        started = $4 " " $5 " " $7 " " $6
                    }
                }
                /^Status:/                       { status = $2 }
                /^Duration:/                     { duration = $2 }
                /no stats available/             { never = 1 }
                /^[ \t]*(read|csum|verify|super)_errors:/ { errs += $2 }
                /^[ \t]*uncorrectable_errors:/   { uncorr = $2 }
                /^[ \t]*corrected_errors:/       { corr = $2 }
                END {
                    print "scrub via", via
                    if (never) { print "scrub never 1"; exit }
                    if (start != "") print "scrub start", sprintf("%.0f", start)
                    print "scrub started", started
                    print "scrub status", status
                    print "scrub duration", duration
                    print "scrub uncorr", uncorr + 0
                    print "scrub corr", corr + 0
                    print "scrub errs", errs + 0
                }' >> "$F"
            scrubdone=1
        else
            printf 'scrub note btrfs scrub status via %s failed: %s\n' "$SCRUBVIA" \
                "$(printf '%s\n' "$sout" | head -n 1)" >> "$F"
        fi
    fi
    if [ -z "$scrubdone" ] && [ -e "$sfile" ]; then
        # GNU and BusyBox date both read a file's mtime with -r (Linux only
        # here, FreeBSD stopped above).
        mt=$(date -r "$sfile" +%s 2>/dev/null) && printf 'scrub mtime %s\n' "$mt" >> "$F"
        printf 'scrub file 1\n' >> "$F"
    fi

    awk -v uuid="$uuid" -v name="$name" -v now="$NOW" -v statefile="$STATEFILE" \
        -v ro_ok="$rook" -v errhold="$BTRFS_ERR_HOLD" \
        -v errcolor="$(color_or "$BTRFS_ERR_COLOR" yellow)" \
        -v errnewcolor="$(color_or "$BTRFS_ERR_NEW_COLOR" red)" \
        -v unalwarn="$BTRFS_UNALLOC_WARN" -v unalcrit="$BTRFS_UNALLOC_CRIT" \
        -v metawarn="$BTRFS_META_WARN" -v metacrit="$BTRFS_META_CRIT" \
        -v scrubmax="$BTRFS_SCRUB_MAXAGE" -v scrubcolor="$(color_or "$BTRFS_SCRUB_COLOR" yellow)" \
        -v scrubdir="$BTRFS_SCRUBDIR" \
        -f "$WORKDIR/eval.awk" "$F" > "$WORKDIR/result"

    sed -n 's/^S //p' "$WORKDIR/result" >> "$WORKDIR/body"
    printf '\n' >> "$WORKDIR/body"
    sed -n 's/^N \([^ ]*\) /\1 : /p' "$WORKDIR/result" >> "$WORKDIR/data"
    sed -n 's/^T //p' "$WORKDIR/result" >> "$WORKDIR/newstate"
    sed -n 's/^X //p' "$WORKDIR/result" >> "$WORKDIR/issues"
    sed -n 's/^C //p' "$WORKDIR/result" >> "$WORKDIR/colors"
done < "$WORKDIR/uuids"

if [ ! -s "$WORKDIR/colors" ]; then
    clear_report "not applicable" "Every mounted btrfs filesystem is excluded by BTRFS_EXCLUDE=\"$BTRFS_EXCLUDE\"."
fi

# Remember this run's counters (best effort - a read-only $XYMONTMP
# only disables the rates and the "grew" detection).
REALSTATE="${XYMONTMP}/btrfs.${MACHINE}.state"
if cat "$WORKDIR/newstate" > "${REALSTATE}.$$" 2>/dev/null; then
    mv "${REALSTATE}.$$" "$REALSTATE" 2>/dev/null || rm -f "${REALSTATE}.$$"
fi

WORST=green
grep -qx yellow "$WORKDIR/colors" && WORST=yellow
grep -qx red "$WORKDIR/colors" && WORST=red

NFS=$(wc -l < "$WORKDIR/colors" | tr -d ' ')
if [ -s "$WORKDIR/issues" ]; then
    SUMMARY=$(awk '{ printf "%s%s", (NR > 1 ? "; " : ""), $0 }' "$WORKDIR/issues")
else
    SUMMARY="${NFS} filesystem(s) ok"
fi

{
    # The status text is for humans only - the metrics travel in the
    # separate "data" message, and xymond_rrd's NCV parser would take
    # every "name: value" pair here for a dataset.
    printf '<!-- ncv_skipstart -->\n'
    cat "$WORKDIR/body"
    [ -s "$WORKDIR/excluded" ] && { cat "$WORKDIR/excluded"; printf '\n'; }
    if [ -z "$BTRFS" ]; then
        printf 'btrfs-progs not found: device sizes come from the block devices, no scrub result.\n'
    else
        case "$SCRUBVIA" in
            root) via="read as root" ;;
            sudo) via="read via sudo" ;;
            *)    via="not read (needs root rights: BTRFS_SUDO=\"yes\" and the rule from sudoers.example)" ;;
        esac
        printf 'btrfs-progs: %s; scrub result %s.\n' "$BTRFS" "$via"
    fi
    printf '<!-- ncv_skipend -->\n'
} > "$WORKDIR/final"

send_report "$WORST" "$WORKDIR/final" "$WORKDIR/data"
exit 0
