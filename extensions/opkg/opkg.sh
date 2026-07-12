#!/bin/sh
#
# opkg.sh -- Xymon client extension: opkg package update status
#
# Reports whether opkg-managed packages (OpenWrt/TurrisOS) have
# updates available - the opkg counterpart of the Debian
# hobbit-plugins "apt" check. Updates are yellow; an update matching
# a configurable list of security-relevant package patterns is red.
# The status text carries "updates : N" and "critical : N" lines
# (hidden in an HTML comment) for NCV graphing - see README.md.
#
# The package lists live in RAM on OpenWrt (/tmp) and are gone after
# every reboot, so by default this extension runs "opkg update"
# itself whenever the lists are missing or older than OPKG_MAXAGE
# hours (set OPKG_UPDATE=never to leave that to somebody else).
#
# Hosts without opkg (Debian/EL/FreeBSD) report "clear".
#
# Configuration: environment variables and/or $XYMONHOME/etc/opkg.cfg
# (see the shipped opkg.cfg; the config file wins over the
# environment).

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
# Defaults -- every value can be set in the environment or in opkg.cfg
# ----------------------------------------------------------------------
OPKG_COLUMN="${OPKG_COLUMN:-opkg}"  # Xymon column name
OPKG_BIN="${OPKG_BIN:-}"            # empty: found via command -v
OPKG_UPDATE="${OPKG_UPDATE:-auto}"  # auto|never: run "opkg update"?
OPKG_MAXAGE="${OPKG_MAXAGE:-24}"    # hours before lists count as stale
OPKG_CRITICAL="${OPKG_CRITICAL:-dropbear* *openssl* *ssl* *tls* wpad* hostapd* dnsmasq* firewall* odhcpd* uhttpd* busybox* wireguard* curl* libcurl* wget*}"
OPKG_CONF="${OPKG_CONF:-/etc/opkg.conf}"
OPKG_LISTSDIR="${OPKG_LISTSDIR:-}"  # empty: lists_dir from OPKG_CONF
OPKG_TIMEOUT="${OPKG_TIMEOUT:-300}" # seconds for "opkg update", 0 = off

CFGFILE="${OPKG_CFG:-${XYMONHOME:+${XYMONHOME}/etc/opkg.cfg}}"
if [ -n "$CFGFILE" ] && [ -r "$CFGFILE" ]; then
    # shellcheck disable=SC1090  # user config, sourced on purpose
    . "$CFGFILE"
fi
COLUMN="$OPKG_COLUMN"

# Non-numeric values would blow up the arithmetic below; fall back to
# the built-in defaults instead.
case "$OPKG_MAXAGE" in ''|*[!0-9]*) OPKG_MAXAGE=24 ;; esac
case "$OPKG_TIMEOUT" in ''|*[!0-9]*) OPKG_TIMEOUT=300 ;; esac

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

# send_report <color> <summary> <body-file>
send_report() {
    if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
        "$XYMON" "$XYMSRV" "status ${MACHINE}.${COLUMN} $1 $(date) - $2

$(cat "$3")"
    else
        # No Xymon environment: print the message (manual test run)
        echo "status ${MACHINE}.${COLUMN} $1 $(date) - $2"
        echo ""
        cat "$3"
    fi
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

WORKDIR=$(mktemp -d "${XYMONTMP}/opkg.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

clear_report() {
    printf '%s\n' "$1" > "$WORKDIR/status"
    send_report clear "update check not applicable" "$WORKDIR/status"
    exit 0
}

if [ -z "$OPKG_BIN" ]; then
    OPKG_BIN=$(command -v opkg || true)
fi
if [ -z "$OPKG_BIN" ] || [ ! -x "$OPKG_BIN" ]; then
    clear_report "opkg not found - this test monitors opkg package updates and only applies to opkg-based systems (OpenWrt/TurrisOS)."
fi

# Where opkg keeps the downloaded package lists: explicit setting,
# else the lists_dir option from opkg.conf ("lists_dir ext /path"),
# else the OpenWrt default, else the upstream opkg default.
if [ -z "$OPKG_LISTSDIR" ] && [ -r "$OPKG_CONF" ]; then
    OPKG_LISTSDIR=$(awk '$1 == "lists_dir" { d = $3 } END { if (d != "") print d }' "$OPKG_CONF")
fi
if [ -z "$OPKG_LISTSDIR" ]; then
    if [ -d /var/opkg-lists ]; then
        OPKG_LISTSDIR=/var/opkg-lists
    else
        OPKG_LISTSDIR=/var/lib/opkg/lists
    fi
fi

lists_present() {
    find "$OPKG_LISTSDIR" -type f -print 2>/dev/null | grep -q .
}

# lists_state -> missing|fresh|stale. Age check without stat(1) (not
# portable): create a reference file OPKG_MAXAGE hours old and ask
# find -newer. Both date variants are tried - GNU and BusyBox take
# -d @epoch, FreeBSD takes -r epoch (in that order on purpose: GNU
# date -r means "mtime of file"). If no variant works, "stale" is the
# conservative answer.
lists_state() {
    if ! lists_present; then
        echo missing
        return
    fi
    if [ "$OPKG_MAXAGE" -eq 0 ]; then
        echo fresh
        return
    fi
    ls_cutoff=$(( $(date +%s) - OPKG_MAXAGE * 3600 ))
    ls_stamp=$(date -d "@$ls_cutoff" +%Y%m%d%H%M.%S 2>/dev/null) \
        || ls_stamp=$(date -r "$ls_cutoff" +%Y%m%d%H%M.%S 2>/dev/null) \
        || ls_stamp=""
    if [ -z "$ls_stamp" ] || ! touch -t "$ls_stamp" "$WORKDIR/ref" 2>/dev/null; then
        echo stale
        return
    fi
    if find "$OPKG_LISTSDIR" -type f -newer "$WORKDIR/ref" -print 2>/dev/null | grep -q .; then
        echo fresh
    else
        echo stale
    fi
}

run_update() {
    if [ "$OPKG_TIMEOUT" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        timeout "$OPKG_TIMEOUT" "$OPKG_BIN" update
    else
        "$OPKG_BIN" update
    fi
}

STATE=$(lists_state)
UPDATE_FAILED=no
UPDATE_RAN=no

if [ "$STATE" != "fresh" ] && [ "$OPKG_UPDATE" = "auto" ]; then
    UPDATE_RAN=yes
    if run_update > "$WORKDIR/update.out" 2>&1; then
        if lists_present; then
            STATE=fresh
        else
            STATE=missing
        fi
    else
        UPDATE_FAILED=yes
    fi
fi

NOTES="$WORKDIR/notes"
: > "$NOTES"
NOTECOLOR=green

if [ "$UPDATE_FAILED" = "yes" ]; then
    {
        printf '&yellow opkg update failed - the reported state may be outdated. Last lines:\n'
        tail -n 3 "$WORKDIR/update.out" | sed 's/^/    /'
        printf '\n'
    } >> "$NOTES"
    NOTECOLOR=yellow
elif [ "$STATE" = "stale" ] && [ "$OPKG_UPDATE" != "auto" ]; then
    printf '&yellow package lists are older than %s hour(s) and OPKG_UPDATE=never - the reported state may be outdated.\n\n' \
        "$OPKG_MAXAGE" >> "$NOTES"
    NOTECOLOR=yellow
fi

if [ "$STATE" = "missing" ]; then
    {
        cat "$NOTES"
        printf '&yellow no opkg package lists found in %s - update status unknown.\n' "$OPKG_LISTSDIR"
        if [ "$OPKG_UPDATE" != "auto" ]; then
            printf '\nOPKG_UPDATE=never is set, so this extension does not download them itself.\nRun "opkg update" (e.g. from cron) or set OPKG_UPDATE=auto.\n'
        fi
    } > "$WORKDIR/final"
    send_report yellow "update status unknown" "$WORKDIR/final"
    exit 0
fi

if ! "$OPKG_BIN" list-upgradable > "$WORKDIR/raw" 2> "$WORKDIR/raw.err"; then
    {
        cat "$NOTES"
        printf '&yellow "opkg list-upgradable" failed - update status unknown. Last lines:\n'
        cat "$WORKDIR/raw" "$WORKDIR/raw.err" 2>/dev/null | tail -n 3 | sed 's/^/    /'
    } > "$WORKDIR/final"
    send_report yellow "update status unknown" "$WORKDIR/final"
    exit 0
fi

# Package lines look like "name - oldversion - newversion"; opkg mixes
# in noise like "Collected errors:" on stderr and informational lines
# that do not match the three-field format.
awk -F' - ' 'NF >= 3 { print $1 "|" $2 "|" $3 }' "$WORKDIR/raw" \
    | sort > "$WORKDIR/pkgs"

COUNT=0
CRIT=0
PKGLINES="$WORKDIR/pkglines"
: > "$PKGLINES"

while IFS='|' read -r p_name p_old p_new; do
    [ -n "$p_name" ] || continue
    COUNT=$((COUNT + 1))
    p_hit=""
    # Glob matching: expand OPKG_CRITICAL into words without pathname
    # expansion (patterns like *ssl* must not match files in $PWD).
    set -f
    # shellcheck disable=SC2086  # word splitting is intended
    for p_pat in $OPKG_CRITICAL; do
        # shellcheck disable=SC2254  # unquoted on purpose: glob match
        case "$p_name" in
            $p_pat) p_hit="$p_pat"; break ;;
        esac
    done
    set +f
    if [ -n "$p_hit" ]; then
        CRIT=$((CRIT + 1))
        printf '&red %s %s -> %s (matches critical pattern "%s")\n' \
            "$p_name" "$p_old" "$p_new" "$p_hit" >> "$PKGLINES"
    else
        printf '&yellow %s %s -> %s\n' \
            "$p_name" "$p_old" "$p_new" >> "$PKGLINES"
    fi
done < "$WORKDIR/pkgs"

if [ "$CRIT" -gt 0 ]; then
    COLOR=red
elif [ "$COUNT" -gt 0 ]; then
    COLOR=yellow
else
    COLOR=green
fi
COLOR=$(worst "$COLOR" "$NOTECOLOR")

if [ "$COUNT" -gt 0 ]; then
    SUMMARY="$COUNT update(s) available ($CRIT critical)"
else
    SUMMARY="packages up to date"
fi

if [ "$UPDATE_RAN" = "yes" ] && [ "$UPDATE_FAILED" = "no" ]; then
    LISTSNOTE="refreshed by this run"
elif [ "$OPKG_MAXAGE" -eq 0 ]; then
    LISTSNOTE="age check disabled"
elif [ "$STATE" = "stale" ]; then
    LISTSNOTE="possibly stale"
else
    LISTSNOTE="updated within the last $OPKG_MAXAGE hour(s)"
fi

{
    cat "$NOTES"
    if [ "$COUNT" -gt 0 ]; then
        cat "$PKGLINES"
        printf '\n%s package(s) can be upgraded, %s security-relevant.\n' \
            "$COUNT" "$CRIT"
    else
        printf '&green all packages are up to date\n'
    fi
    printf '\nPackage lists: %s (%s)\n' "$OPKG_LISTSDIR" "$LISTSNOTE"
    printf 'Critical patterns: %s\n' "$OPKG_CRITICAL"
    printf '\n<!--\n'
    printf 'updates : %s\n' "$COUNT"
    printf 'critical : %s\n' "$CRIT"
    printf '%s\n' '-->'
} > "$WORKDIR/final"

send_report "$COLOR" "$SUMMARY" "$WORKDIR/final"
exit 0
