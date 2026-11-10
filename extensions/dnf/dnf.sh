#!/bin/sh
#
# dnf.sh -- Xymon client extension: dnf package update status
#
# Reports whether a dnf-managed host (Rocky Linux, RHEL, AlmaLinux,
# ...) has package updates pending - the dnf counterpart of the "apt"
# check from Debian's hobbit-plugins, and built the same way: it only
# READS what the system already knows and never downloads anything.
#
#   * no enabled package repository                        -> yellow
#   * repository metadata missing or older than DNF_MAXAGE -> yellow
#   * security updates, by the severity of their advisories:
#     critical/important -> red, moderate/low/unknown -> yellow
#   * other updates                                        -> yellow
#   * the running kernel is older than an installed kernel
#     security update (reboot pending)                     -> yellow
#
# Every color can be changed in dnf.cfg. The status text starts with
# an overview of all findings, so that a Xymon alert mail shows them
# in its first lines; the package lists follow below.
#
# Program flow:
#   1. defaults -> config file -> dnf binary (none: report clear)
#   2. dnf --version                  -> dnf5 is not supported: clear
#   3. dnf -C repolist --enabled      -> enabled repositories
#      (none: report yellow)
#   4. mtime of the cached metadata per repository, straight from the
#      cache directory -> age, compared with DNF_MAXAGE
#   5. dnf -C check-update            -> packages with updates, and
#      dnf's own "Security: kernel ..." lines (reboot pending)
#   6. only if there are updates:
#      dnf -C updateinfo summary --updates --security
#                                     -> advisory counts per severity
#      dnf -C updateinfo list --updates --security
#                                     -> advisories per package
#      dnf -C updateinfo list --updates --security --with-cve
#                                     -> CVEs per package
#   7. status message (worst color wins; overview first) plus a "data"
#      message with the graphed values (plain NCV on the server, see
#      server/README.md)
#
# Why "-C" (cache only) on every call: dnf keeps one metadata cache
# per user. Without -C the xymon user would download its own copy of
# all repository metadata into /var/tmp/dnf-<user>-*, on every host
# and again whenever it expires. With -C an unprivileged user reads
# the system cache in /var/cache/dnf instead (dnf(8), "--cacheonly"),
# which root keeps current - on EL through dnf-makecache.timer. This
# extension therefore needs no network access and no root rights, and
# step 4 is what notices when nobody refreshes that cache any more.
#
# Why the mtime in step 4: libdnf takes the age of a repository from
# the mtime of its cached primary metadata and touches that file - and
# only that one - on every successful refresh, also when the metadata
# did not change (verified with dnf 4.20 on Rocky Linux 10). That is
# the value behind
# dnf's "Last metadata expiration check" line - which only reports the
# freshest repository, so a single repository that stopped refreshing
# would stay hidden behind it.
#
# Hosts without dnf (Debian/Ubuntu, FreeBSD, OpenWrt) report "clear".
#
# Configuration: environment variables and/or
# $XYMONHOME/etc/my-xymon-extensions/dnf.cfg (see the shipped dnf.cfg;
# the config file wins over the environment).

# Version: 1.0.0 (2026-11-10)

set -u

# dnf's output is parsed below and must not depend on the locale; the
# numbers in the data message need a decimal point in every locale.
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
# Defaults -- every value can be set in the environment or in dnf.cfg
# ----------------------------------------------------------------------
DNF_COLUMN="${DNF_COLUMN:-dnf}"                 # Xymon column name
DNF_BIN="${DNF_BIN:-}"                          # empty: command -v dnf
DNF_CACHEDIR="${DNF_CACHEDIR:-/var/cache/dnf}"  # dnf's system cache
DNF_MAXAGE="${DNF_MAXAGE:-72}"                  # hours; 0 = no age check
DNF_TIMEOUT="${DNF_TIMEOUT:-120}"               # seconds per dnf call
DNF_LIFETIME="${DNF_LIFETIME:-30}"              # status validity, minutes
DNF_UPDATES_COLOR="${DNF_UPDATES_COLOR:-yellow}"  # non-security updates
DNF_SEC_CRITICAL_COLOR="${DNF_SEC_CRITICAL_COLOR:-red}"
DNF_SEC_IMPORTANT_COLOR="${DNF_SEC_IMPORTANT_COLOR:-red}"
DNF_SEC_MODERATE_COLOR="${DNF_SEC_MODERATE_COLOR:-yellow}"
DNF_SEC_LOW_COLOR="${DNF_SEC_LOW_COLOR:-yellow}"
DNF_SEC_UNKNOWN_COLOR="${DNF_SEC_UNKNOWN_COLOR:-yellow}"
DNF_REBOOT_COLOR="${DNF_REBOOT_COLOR:-yellow}"  # or "off": no check
DNF_SHOW_CVES="${DNF_SHOW_CVES:-no}"            # yes: list every CVE id
DNF_OSRELEASE="${DNF_OSRELEASE:-/etc/os-release}"

# Own subdirectory since 0.20.0 ($XYMONHOME/etc is shared with the
# Xymon server and hobbit-plugins); the old place is the fallback all
# extensions share, although dnf.cfg itself never lived there.
CFGFILE="${DNF_CFG:-}"
if [ -z "$CFGFILE" ] && [ -n "$XYMONHOME" ]; then
    CFGFILE="$XYMONHOME/etc/my-xymon-extensions/dnf.cfg"
    [ -f "$CFGFILE" ] || CFGFILE="$XYMONHOME/etc/dnf.cfg"
fi
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi
COLUMN="${DNF_COLUMN}"

# Non-numeric values would blow up the arithmetic below, and an invalid
# color or lifetime produces a status message the Xymon server rejects;
# all of them fall back to the built-in defaults instead.
case "${DNF_MAXAGE}" in ''|*[!0-9]*) DNF_MAXAGE=72 ;; esac
case "${DNF_TIMEOUT}" in ''|*[!0-9]*) DNF_TIMEOUT=120 ;; esac
case "${DNF_LIFETIME}" in ''|*[!0-9]*|0) DNF_LIFETIME=30 ;; esac

# valid_color <value> <default> -> the value if it is a color a finding
# may have, else the default. "green" keeps a finding in the report
# without changing the column.
valid_color() {
    case "${1}" in
        red|yellow|green) printf '%s' "${1}" ;;
        *) printf '%s' "${2}" ;;
    esac
}
DNF_UPDATES_COLOR=$(valid_color "${DNF_UPDATES_COLOR}" yellow)
DNF_SEC_CRITICAL_COLOR=$(valid_color "${DNF_SEC_CRITICAL_COLOR}" red)
DNF_SEC_IMPORTANT_COLOR=$(valid_color "${DNF_SEC_IMPORTANT_COLOR}" red)
DNF_SEC_MODERATE_COLOR=$(valid_color "${DNF_SEC_MODERATE_COLOR}" yellow)
DNF_SEC_LOW_COLOR=$(valid_color "${DNF_SEC_LOW_COLOR}" yellow)
DNF_SEC_UNKNOWN_COLOR=$(valid_color "${DNF_SEC_UNKNOWN_COLOR}" yellow)
case "${DNF_REBOOT_COLOR}" in
    off) ;;
    *) DNF_REBOOT_COLOR=$(valid_color "${DNF_REBOOT_COLOR}" yellow) ;;
esac

# The whole status travels as ONE command line argument to $XYMON, and
# Linux limits a single argument to 128 KiB (MAX_ARG_STRLEN). A host
# that is hundreds of updates behind must not lose its report to that,
# so the text is cut at this many bytes - the overview comes first and
# always survives.
MAXBYTES=100000

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

# raise <color> -- make <color> the column color if it is worse
raise() {
    case "${1}" in
        red) WORST=red ;;
        yellow) [ "${WORST}" = red ] || WORST=yellow ;;
    esac
}

# send_report <color> <status-body-file> [data-body-file]
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "${XYMON}" "${XYMSRV}" "status+${DNF_LIFETIME} ${MACHINE}.${COLUMN} ${1} $(date) - dnf: ${SUMMARY:-${1}}

$(cat "${2}")" || return 1
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            "${XYMON}" "${XYMSRV}" "data ${MACHINE}.${COLUMN}
$(cat "${3}")" || return 1
        fi
    else
        # No Xymon environment: print the messages (manual test run)
        echo "status+${DNF_LIFETIME} ${MACHINE}.${COLUMN} ${1} $(date) - dnf: ${SUMMARY:-${1}}"
        echo ""
        cat "${2}"
        if [ -n "${3:-}" ] && [ -s "${3:-}" ]; then
            echo ""
            echo "data ${MACHINE}.${COLUMN}"
            cat "${3}"
        fi
    fi
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

# One spelling for the awk program that prints the package list.
if is_yes "${DNF_SHOW_CVES}"; then DNF_SHOW_CVES=yes; else DNF_SHOW_CVES=no; fi

WORKDIR=$(mktemp -d "${XYMONTMP}/dnf.XXXXXX") || exit 1
trap 'rm -rf "${WORKDIR}"' EXIT INT TERM

STATUS="${WORKDIR}/status"
DATA="${WORKDIR}/data"
REPOTXT="${WORKDIR}/repotxt"      # one line per repository
PROBLEMS="${WORKDIR}/problems"    # overview lines about repositories
: > "${DATA}"
: > "${REPOTXT}"
: > "${PROBLEMS}"
SUMMARY=""
WORST=green

# The status is for humans only - the metrics travel in the separate
# "data" message. xymond_rrd's NCV parser treats both ":" and "=" as a
# name/value separator, so without the ncv_skip markers a line like
# "Security updates: 3" would end up in an RRD.

# short_report <color> <summary> <text> -- a report without package
# lists and without metrics, for "not applicable" and "no repository".
short_report() {
    SUMMARY="${2}"
    {
        printf '<!-- ncv_skipstart -->\n'
        printf '%s\n' "${3}"
        printf '<!-- ncv_skipend -->\n'
    } > "${STATUS}"
    send_report "${1}" "${STATUS}"
    exit "$?"
}

# run_dnf <name> <dnf arguments...> -- run one cache-only dnf command;
# stdout goes to $WORKDIR/<name>.out, stderr to $WORKDIR/<name>.err.
# Returns dnf's exit code (124: timeout(1) killed it).
run_dnf() {
    rd_name=${1}
    shift
    if [ "${DNF_TIMEOUT}" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        timeout "${DNF_TIMEOUT}" "${DNF_BIN}" -C "$@" \
            > "${WORKDIR}/${rd_name}.out" 2> "${WORKDIR}/${rd_name}.err"
    else
        "${DNF_BIN}" -C "$@" \
            > "${WORKDIR}/${rd_name}.out" 2> "${WORKDIR}/${rd_name}.err"
    fi
}

# fail_report <name> <exit-code> <command> -- a dnf command failed, so
# what is pending is unknown: yellow, with dnf's own error message and
# whatever is already known about the repositories.
fail_report() {
    SUMMARY="update status unknown"
    {
        printf '<!-- ncv_skipstart -->\n'
        if [ "${2}" -eq 124 ]; then
            printf '&yellow "dnf -C %s" did not finish within %s second(s) - update status unknown.\n' \
                "${3}" "${DNF_TIMEOUT}"
        else
            printf '&yellow "dnf -C %s" failed (exit code %s) - update status unknown. Last lines:\n' \
                "${3}" "${2}"
        fi
        cat "${WORKDIR}/${1}.err" "${WORKDIR}/${1}.out" 2>/dev/null \
            | grep -v '^[[:space:]]*$' | tail -n 5 | sed 's/^/    /'
        cat "${PROBLEMS}"
        printf '\nThis test reads dnf'"'"'s system cache in %s and never downloads\n' "${DNF_CACHEDIR}"
        printf 'metadata itself. If the cache of a repository is missing, run\n'
        printf '"dnf makecache" as root and check that dnf-makecache.timer is enabled.\n'
        if [ -s "${REPOTXT}" ]; then
            printf '\nRepositories:\n'
            cat "${REPOTXT}"
        fi
        printf '<!-- ncv_skipend -->\n'
    } > "${STATUS}"
    send_report yellow "${STATUS}"
    exit "$?"
}

# --- 1. the dnf binary -------------------------------------------------
if [ -z "${DNF_BIN}" ]; then
    DNF_BIN=$(command -v dnf || true)
fi
if [ -z "${DNF_BIN}" ] || [ ! -x "${DNF_BIN}" ]; then
    short_report clear "update check not applicable" \
        "dnf not found - this test monitors dnf package updates and only applies to dnf-based systems (Rocky Linux, RHEL, AlmaLinux, ...)."
fi

# --- 2. dnf generation -------------------------------------------------
# dnf5 (Fedora 41 and later) is a rewrite with other commands
# ("advisory" instead of "updateinfo") and another cache layout; its
# output would be misread here, so say so instead of guessing.
DNF_VERSION=$("${DNF_BIN}" --version 2>/dev/null | head -n 1)
case "${DNF_VERSION}" in
    dnf5*|[5-9].*|[1-9][0-9].*)
        short_report clear "update check not applicable" \
            "This test supports dnf 4 (EL8, EL9, EL10); found: ${DNF_VERSION}. dnf5 is not supported yet."
        ;;
esac

OSNAME=""
if [ -r "${DNF_OSRELEASE}" ]; then
    OSNAME=$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${DNF_OSRELEASE}" | head -n 1)
fi

# --- 3. enabled repositories -------------------------------------------
# "repolist" does not load any metadata, so it also works when the
# cache of a repository is missing - which step 4 then reports by name.
run_dnf repolist -q repolist --enabled
RC=$?
[ "${RC}" -eq 0 ] || fail_report repolist "${RC}" "repolist --enabled"

# "repo id   repo name" header, then one line per repository
awk '$1 == "repo" && $2 == "id" { next }
     NF >= 1 { id = $1; name = $0; sub(/^[^ \t]+[ \t]*/, "", name)
               print id "|" name }' \
    "${WORKDIR}/repolist.out" > "${WORKDIR}/repos"

NREPOS=$(wc -l < "${WORKDIR}/repos" | tr -d ' ')
if [ "${NREPOS}" -eq 0 ]; then
    short_report yellow "no enabled package repository" \
        "&yellow No package repository is enabled on this host, so no update can be found - neither a security update nor any other.
Check the files in /etc/yum.repos.d (\"dnf repolist --all\" lists the disabled repositories)."
fi

# --- 4. age of the cached metadata -------------------------------------
# Cache directories are named <repo id>-<16 hex digits>; a repository
# whose URL changed leaves an older directory behind, so the freshest
# of all matching directories counts. Within a directory only the
# primary metadata counts, as for libdnf: other files are fetched on
# demand ("dnf provides" downloads the file lists) and would make a
# cache look fresh that no refresh has touched for weeks. A directory
# without primary metadata falls back to all of its files.
# "date -r FILE" prints the mtime with GNU coreutils, BusyBox and
# FreeBSD alike.
NOW=$(date +%s)
NSTALE=0
NNOCACHE=0
AGEMIN=""
AGEMAX=""

# hours <seconds> -> hours with one decimal, in integer arithmetic
hours() {
    h_tenths=$(( ${1} * 10 / 3600 ))
    printf '%s.%s' "$(( h_tenths / 10 ))" "$(( h_tenths % 10 ))"
}

while IFS='|' read -r r_id r_name; do
    [ -n "${r_id}" ] || continue
    r_newest=""
    for r_dir in "${DNF_CACHEDIR}/${r_id}"-*; do
        [ -d "${r_dir}/repodata" ] || continue
        r_suffix=${r_dir#"${DNF_CACHEDIR}/${r_id}-"}
        case "${r_suffix}" in ''|*[!0-9a-f]*) continue ;; esac
        [ "${#r_suffix}" -eq 16 ] || continue
        r_found=no
        for r_pattern in '*primary.xml*' '*'; do
            for r_file in "${r_dir}"/repodata/${r_pattern}; do
                [ -f "${r_file}" ] || continue
                r_mtime=$(date -r "${r_file}" +%s 2>/dev/null) || continue
                case "${r_mtime}" in ''|*[!0-9]*) continue ;; esac
                r_found=yes
                if [ -z "${r_newest}" ] || [ "${r_mtime}" -gt "${r_newest}" ]; then
                    r_newest=${r_mtime}
                fi
            done
            [ "${r_found}" = no ] || break
        done
    done

    if [ -z "${r_newest}" ]; then
        NNOCACHE=$((NNOCACHE + 1))
        printf '&yellow %s (%s): no cached metadata\n' "${r_id}" "${r_name}" >> "${REPOTXT}"
        printf '&yellow Repository %s: no cached metadata in %s - its updates are unknown\n' \
            "${r_id}" "${DNF_CACHEDIR}" >> "${PROBLEMS}"
        continue
    fi

    # A file from the future (clock stepped back) is as fresh as it gets.
    r_age=$((NOW - r_newest))
    [ "${r_age}" -ge 0 ] || r_age=0
    if [ -z "${AGEMIN}" ] || [ "${r_age}" -lt "${AGEMIN}" ]; then AGEMIN=${r_age}; fi
    if [ -z "${AGEMAX}" ] || [ "${r_age}" -gt "${AGEMAX}" ]; then AGEMAX=${r_age}; fi

    if [ "${DNF_MAXAGE}" -gt 0 ] && [ "${r_age}" -gt $((DNF_MAXAGE * 3600)) ]; then
        NSTALE=$((NSTALE + 1))
        printf '&yellow %s (%s): metadata %s hour(s) old\n' \
            "${r_id}" "${r_name}" "$(hours "${r_age}")" >> "${REPOTXT}"
        printf '&yellow Repository %s: metadata is %s hour(s) old (limit: %s) - newer updates are not seen\n' \
            "${r_id}" "$(hours "${r_age}")" "${DNF_MAXAGE}" >> "${PROBLEMS}"
    else
        printf '&green %s (%s): metadata %s hour(s) old\n' \
            "${r_id}" "${r_name}" "$(hours "${r_age}")" >> "${REPOTXT}"
    fi
done < "${WORKDIR}/repos"

NREPOPROBLEMS=$((NSTALE + NNOCACHE))
[ "${NREPOPROBLEMS}" -eq 0 ] || raise yellow

# --- 5. pending updates ------------------------------------------------
# Exit code 100: updates available, 0: none, anything else: error
# (dnf(8), "check-update"). A repository without cache makes dnf fail
# here - unless it is marked skip_if_unavailable, in which case dnf
# carries on without it and, with -q, without a word. Step 4 has
# already reported such a repository by name.
run_dnf check -q check-update
RC=$?
case "${RC}" in
    0|100) ;;
    *) fail_report check "${RC}" "check-update" ;;
esac

# dnf prints these two lines itself when the running kernel is older
# than an installed kernel that fixes a security issue
# (autocheck_running_kernel, dnf.conf(5)).
: > "${WORKDIR}/reboot"
if [ "${DNF_REBOOT_COLOR}" != off ]; then
    grep '^Security: ' "${WORKDIR}/check.out" > "${WORKDIR}/reboot" || true
fi

# --- 6. advisories -----------------------------------------------------
# Without a pending update there is no advisory "--updates" could
# list, so the three calls are only made when check-update found some.
: > "${WORKDIR}/summary.out"
: > "${WORKDIR}/list.out"
: > "${WORKDIR}/cve.out"
if [ "${RC}" -eq 100 ]; then
    run_dnf summary -q updateinfo summary --updates --security
    RC=$?
    [ "${RC}" -eq 0 ] || fail_report summary "${RC}" "updateinfo summary --updates --security"
    run_dnf list -q updateinfo list --updates --security
    RC=$?
    [ "${RC}" -eq 0 ] || fail_report list "${RC}" "updateinfo list --updates --security"
    run_dnf cve -q updateinfo list --updates --security --with-cve
    RC=$?
    [ "${RC}" -eq 0 ] || fail_report cve "${RC}" "updateinfo list --updates --security --with-cve"
fi

# Join the three lists per package.
#
# check-update: "name.arch  [epoch:]version-release  repo". Old dnf
# versions wrap a line that does not fit the terminal width and
# continue it indented, so the fields are collected across lines. The
# "Obsoleting Packages" section at the end lists pairs: a package that
# replaces an installed one under another name, and indented below it
# the package it replaces. The replacing package is an update like any
# other (dnf exits with 100 for it alone), the replaced one is not.
#
# updateinfo list: "ID  Severity/Sec.  name-[epoch:]version-release.arch",
# one line per advisory and package build - a package that is several
# updates behind appears once per advisory in between. Neither version
# nor release can contain a "-", so the name ends at the second "-"
# from the right.
#
# --with-cve replaces the advisory id by its references. Rocky Linux
# lists more than CVEs there (the RLSA/RHSA ids and the license of the
# advisory text), hence the match on "CVE-".
awk -v secfile="${WORKDIR}/sec.raw" -v otherfile="${WORKDIR}/other.raw" \
    -v countfile="${WORKDIR}/counts" '
function pkgkey(n,   arch) {
    arch = n
    sub(/^.*\./, "", arch)
    sub(/\.[^.]*$/, "", n)
    if (match(n, /-[^-]*-[^-]*$/)) n = substr(n, 1, RSTART - 1)
    return n "." arch
}
function sevrank(s) {
    if (s == "Critical") return 5
    if (s == "Important") return 4
    if (s == "Moderate") return 3
    if (s == "Low") return 2
    return 1
}
function sevname(s) {
    if (s == "Critical" || s == "Important" || s == "Moderate" || s == "Low") return s
    return "Unknown"
}
kind == "check" {
    if ($0 ~ /^Obsoleting Packages/) { obsoleting = 1; nbuf = 0; next }
    if ($0 ~ /^Security: /) next
    if ($0 ~ /^[ \t]*$/) { nbuf = 0; next }
    if (obsoleting && ($0 ~ /^[ \t]/ || NF != 3)) next
    if ($0 !~ /^[ \t]/) nbuf = 0
    for (i = 1; i <= NF; i++) buf[++nbuf] = $i
    if (nbuf < 3) next
    if (nbuf == 3 && buf[1] ~ /\./ && buf[2] ~ /^[0-9]/ && !(buf[1] in ver)) {
        order[++npkg] = buf[1]
        ver[buf[1]] = buf[2]
        repo[buf[1]] = buf[3]
    }
    nbuf = 0
    next
}
kind == "list" && NF == 3 && $2 ~ /\/Sec\.$/ {
    k = pkgkey($3)
    sev = $2
    sub(/\/Sec\.$/, "", sev)
    sev = sevname(sev)
    r = sevrank(sev)
    if (!(k in rank) || r > rank[k]) { rank[k] = r; psev[k] = sev }
    if (!((k, $1) in seenid)) {
        seenid[k, $1] = 1
        nids[k]++
        ids[k] = ids[k] (ids[k] == "" ? "" : " ") $1
    }
    if (!($1 in notice)) { notice[$1] = 1; nnotice[sev]++; nnotices++ }
    next
}
kind == "cve" && NF == 3 && $1 ~ /^CVE-/ {
    k = pkgkey($3)
    if (!((k, $1) in seencve)) {
        seencve[k, $1] = 1
        ncve[k]++
        cves[k] = cves[k] (cves[k] == "" ? "" : " ") $1
    }
    if (!($1 in allcve)) { allcve[$1] = 1; ncves++ }
    next
}
END {
    for (i = 1; i <= npkg; i++) {
        k = order[i]
        if (k in rank) {
            print rank[k] "|" k "|" ver[k] "|" repo[k] "|" psev[k] "|" nids[k] "|" (ncve[k] + 0) "|" ids[k] "|" cves[k] > secfile
            done[k] = 1
            nsec++
            npsev[psev[k]]++
        } else {
            print k "|" ver[k] "|" repo[k] > otherfile
            nother++
        }
    }
    # An advisory for a package check-update did not offer (excluded,
    # version locked): still a known security issue, so it is listed.
    for (k in rank) {
        if (k in done) continue
        print rank[k] "|" k "|-|-|" psev[k] "|" nids[k] "|" (ncve[k] + 0) "|" ids[k] "|" cves[k] > secfile
        nsec++
        npsev[psev[k]]++
    }
    print "updates", npkg + 0 > countfile
    print "security", nsec + 0 > countfile
    print "other", nother + 0 > countfile
    print "cves", ncves + 0 > countfile
    print "notices", nnotices + 0 > countfile
    print "n_critical", nnotice["Critical"] + 0 > countfile
    print "n_important", nnotice["Important"] + 0 > countfile
    print "n_moderate", nnotice["Moderate"] + 0 > countfile
    print "n_low", nnotice["Low"] + 0 > countfile
    print "n_unknown", nnotice["Unknown"] + 0 > countfile
    print "p_critical", npsev["Critical"] + 0 > countfile
    print "p_important", npsev["Important"] + 0 > countfile
    print "p_moderate", npsev["Moderate"] + 0 > countfile
    print "p_low", npsev["Low"] + 0 > countfile
    print "p_unknown", npsev["Unknown"] + 0 > countfile
}' kind=check "${WORKDIR}/check.out" \
   kind=list "${WORKDIR}/list.out" \
   kind=cve "${WORKDIR}/cve.out"

# count <name> -> the number the join stored under that name
count() {
    awk -v n="${1}" '$1 == n { print $2; found = 1; exit } END { if (!found) print 0 }' \
        "${WORKDIR}/counts"
}
NUPDATES=$(count updates)
NSEC=$(count security)
NOTHER=$(count other)
NCVES=$(count cves)
NNOTICES=$(count notices)
N_CRITICAL=$(count n_critical)
N_IMPORTANT=$(count n_important)
N_MODERATE=$(count n_moderate)
N_LOW=$(count n_low)
N_UNKNOWN=$(count n_unknown)
P_CRITICAL=$(count p_critical)
P_IMPORTANT=$(count p_important)
P_MODERATE=$(count p_moderate)
P_LOW=$(count p_low)
P_UNKNOWN=$(count p_unknown)

# dnf's own summary is the authority for the notice counts; the values
# counted from the list above only stand in if a future dnf words the
# summary differently.
# summary_count <word> -> the count in front of "<word> Security notice(s)"
summary_count() {
    awk -v w="${1}" '$2 == w && $3 == "Security" && $4 == "notice(s)" && $1 ~ /^[0-9]+$/ { print $1; exit }' \
        "${WORKDIR}/summary.out"
}
S_TOTAL=$(awk '$2 == "Security" && $3 == "notice(s)" && $1 ~ /^[0-9]+$/ { print $1; exit }' \
    "${WORKDIR}/summary.out")
if [ -n "${S_TOTAL}" ]; then
    NNOTICES=${S_TOTAL}
    S_VAL=$(summary_count Critical);  N_CRITICAL=${S_VAL:-0}
    S_VAL=$(summary_count Important); N_IMPORTANT=${S_VAL:-0}
    S_VAL=$(summary_count Moderate);  N_MODERATE=${S_VAL:-0}
    S_VAL=$(summary_count Low);       N_LOW=${S_VAL:-0}
    S_VAL=$(summary_count Unknown);   N_UNKNOWN=${S_VAL:-0}
fi

# --- 7. the report -----------------------------------------------------
OVERVIEW="${WORKDIR}/overview"
: > "${OVERVIEW}"

# sev_line <label> <notices> <packages> <color> -- one overview line
# per severity that has something pending, and its color for the column
sev_line() {
    [ "${2}" -gt 0 ] || [ "${3}" -gt 0 ] || return 0
    raise "${4}"
    printf '&%s %5s %s security notice(s) - %s package(s)\n' \
        "${4}" "${2}" "${1}" "${3}" >> "${OVERVIEW}"
}

if [ "${NSEC}" -gt 0 ] || [ "${NNOTICES}" -gt 0 ]; then
    printf 'Security updates pending: %s package(s), %s notice(s), %s CVE(s)\n' \
        "${NSEC}" "${NNOTICES}" "${NCVES}" >> "${OVERVIEW}"
    sev_line critical "${N_CRITICAL}" "${P_CRITICAL}" "${DNF_SEC_CRITICAL_COLOR}"
    sev_line important "${N_IMPORTANT}" "${P_IMPORTANT}" "${DNF_SEC_IMPORTANT_COLOR}"
    sev_line moderate "${N_MODERATE}" "${P_MODERATE}" "${DNF_SEC_MODERATE_COLOR}"
    sev_line low "${N_LOW}" "${P_LOW}" "${DNF_SEC_LOW_COLOR}"
    sev_line unknown "${N_UNKNOWN}" "${P_UNKNOWN}" "${DNF_SEC_UNKNOWN_COLOR}"
else
    printf '&green No security update pending\n' >> "${OVERVIEW}"
fi

if [ "${NOTHER}" -gt 0 ]; then
    raise "${DNF_UPDATES_COLOR}"
    printf '&%s Other updates pending: %s package(s)\n' \
        "${DNF_UPDATES_COLOR}" "${NOTHER}" >> "${OVERVIEW}"
else
    printf '&green No other update pending\n' >> "${OVERVIEW}"
fi

REBOOT=no
if [ -s "${WORKDIR}/reboot" ]; then
    REBOOT=yes
    raise "${DNF_REBOOT_COLOR}"
    printf '&%s Reboot pending: the running kernel is older than an installed kernel security update\n' \
        "${DNF_REBOOT_COLOR}" >> "${OVERVIEW}"
fi

if [ "${NREPOPROBLEMS}" -gt 0 ]; then
    cat "${PROBLEMS}" >> "${OVERVIEW}"
elif [ "${DNF_MAXAGE}" -gt 0 ]; then
    printf '&green Repository metadata current: %s enabled, %s to %s hour(s) old (limit: %s)\n' \
        "${NREPOS}" "$(hours "${AGEMIN:-0}")" "$(hours "${AGEMAX:-0}")" "${DNF_MAXAGE}" >> "${OVERVIEW}"
else
    printf '&green Repository metadata: %s enabled, %s to %s hour(s) old (age check disabled)\n' \
        "${NREPOS}" "$(hours "${AGEMIN:-0}")" "$(hours "${AGEMAX:-0}")" >> "${OVERVIEW}"
fi

# First line of the status (and the subject of an alert mail)
if [ "${NUPDATES}" -eq 0 ] && [ "${NSEC}" -eq 0 ]; then
    SUMMARY="packages up to date"
else
    SUMMARY="${NSEC} security update(s)"
    S_DETAIL=""
    [ "${N_CRITICAL}" -gt 0 ] && S_DETAIL="${N_CRITICAL} critical"
    if [ "${N_IMPORTANT}" -gt 0 ]; then
        S_DETAIL="${S_DETAIL:+${S_DETAIL}, }${N_IMPORTANT} important"
    fi
    [ -n "${S_DETAIL}" ] && SUMMARY="${SUMMARY} (${S_DETAIL} notice(s))"
    SUMMARY="${SUMMARY}, ${NOTHER} other update(s)"
fi
[ "${REBOOT}" = yes ] && SUMMARY="${SUMMARY}, reboot pending"
[ "${NREPOPROBLEMS}" -gt 0 ] && SUMMARY="${SUMMARY}, ${NREPOPROBLEMS} repository problem(s)"

{
    [ -n "${OSNAME}" ] && printf '%s\n\n' "${OSNAME}"
    cat "${OVERVIEW}"

    if [ "${NSEC}" -gt 0 ]; then
        printf '\nSecurity updates (%s package(s), most severe first) - install with "dnf upgrade --security":\n' \
            "${NSEC}"
        # Each package with the worst severity among its advisories
        sort -t '|' -k 1,1nr -k 2,2 "${WORKDIR}/sec.raw" | awk -F '|' \
            -v c5="${DNF_SEC_CRITICAL_COLOR}" -v c4="${DNF_SEC_IMPORTANT_COLOR}" \
            -v c3="${DNF_SEC_MODERATE_COLOR}" -v c2="${DNF_SEC_LOW_COLOR}" \
            -v c1="${DNF_SEC_UNKNOWN_COLOR}" -v showcves="${DNF_SHOW_CVES}" '
            BEGIN { color[5] = c5; color[4] = c4; color[3] = c3; color[2] = c2; color[1] = c1 }
            {
                target = ($3 == "-") ? "not offered by check-update" : $3 " (" $4 ")"
                printf "&%s %-9s %s %s - %s notice(s), %s CVE(s): %s\n",
                    color[$1], $5, $2, target, $6, $7, $8
                if (showcves == "yes" && $9 != "") printf "        %s\n", $9
            }'
    fi

    if [ "${NOTHER}" -gt 0 ]; then
        printf '\nOther updates (%s package(s)) - install with "dnf upgrade":\n' "${NOTHER}"
        sort -t '|' -k 1,1 "${WORKDIR}/other.raw" \
            | awk -F '|' '{ printf "    %s %s (%s)\n", $1, $2, $3 }'
    fi

    if [ "${REBOOT}" = yes ]; then
        printf '\nReboot pending (reported by dnf):\n'
        sed 's/^Security: /    /' "${WORKDIR}/reboot"
    fi

    printf '\nRepositories (%s enabled). Metadata is read from the system cache %s,\n' \
        "${NREPOS}" "${DNF_CACHEDIR}"
    printf 'which root keeps current (dnf-makecache.timer); this test downloads nothing.\n'
    cat "${REPOTXT}"
} > "${WORKDIR}/body"

{
    printf '<!-- ncv_skipstart -->\n'
    awk -v max="${MAXBYTES}" '
        { bytes += length($0) + 1 }
        bytes > max {
            print ""
            print "[report cut here: it exceeds " max " bytes - run \"dnf check-update\" on the host for the full list]"
            exit
        }
        { print }' "${WORKDIR}/body"
    printf '<!-- ncv_skipend -->\n'
} > "${STATUS}"

# All values or none: plain NCV creates the RRD file with the datasets
# of the FIRST message it sees. This point is only reached when every
# dnf command succeeded, so the set is always complete.
{
    printf 'updates : %s\n' "${NUPDATES}"
    printf 'security : %s\n' "${NSEC}"
    printf 'critical : %s\n' "${N_CRITICAL}"
    printf 'important : %s\n' "${N_IMPORTANT}"
    printf 'moderate : %s\n' "${N_MODERATE}"
    printf 'low : %s\n' "${N_LOW}"
    printf 'unknown : %s\n' "${N_UNKNOWN}"
    printf 'cves : %s\n' "${NCVES}"
} > "${DATA}"

send_report "${WORST}" "${STATUS}" "${DATA}"
exit "$?"
