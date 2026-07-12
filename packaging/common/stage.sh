#!/bin/sh
# stage.sh - copy all installable files into a package staging tree.
# Shared by the deb, rpm and FreeBSD package builds so the file list
# lives in exactly one place.
#
# usage: stage.sh DESTDIR EXTDIR ETCDIR DOCDIR [CFGSUFFIX]
#
#   DESTDIR    staging root (buildroot)
#   EXTDIR     absolute path of the Xymon client ext/ directory
#   ETCDIR     absolute path of the config directory
#   DOCDIR     absolute path of the documentation directory,
#              or "-" to skip the docs (opkg: flash space)
#   CFGSUFFIX  optional suffix appended to config files
#              (FreeBSD uses ".sample" for @sample handling)
#
# Must be run from the repository root.
set -u

if [ $# -lt 4 ]; then
    echo "usage: $0 DESTDIR EXTDIR ETCDIR DOCDIR [CFGSUFFIX]" >&2
    exit 1
fi

DESTDIR=$1
EXTDIR=$2
ETCDIR=$3
DOCDIR=$4
SUF=${5:-}

# No install(1) here: BusyBox on OpenWrt/TurrisOS has no install
# applet, and the opkg build must run there.
inst() { # inst MODE SRC DST
    cp "$2" "$3" && chmod "$1" "$3"
}

mkdir -p "$DESTDIR$EXTDIR" "$DESTDIR$ETCDIR/tasks.d" || exit 1

for ext in smart temp la memory; do
    inst 0755 "extensions/$ext/$ext.sh" "$DESTDIR$EXTDIR/$ext.sh" || exit 1
    inst 0644 "extensions/$ext/$ext.cfg" "$DESTDIR$ETCDIR/$ext.cfg$SUF" || exit 1
    inst 0644 "packaging/common/tasks.d/$ext.cfg" "$DESTDIR$ETCDIR/tasks.d/$ext.cfg$SUF" || exit 1
done

inst 0755 extensions/fritzdsl/fritzdsl.sh "$DESTDIR$EXTDIR/fritzdsl.sh" || exit 1
inst 0644 extensions/fritzdsl/fritzdsl.cfg "$DESTDIR$ETCDIR/fritzdsl.cfg$SUF" || exit 1
inst 0644 packaging/common/tasks.d/fritzdsl.cfg "$DESTDIR$ETCDIR/tasks.d/fritzdsl.cfg$SUF" || exit 1

inst 0755 extensions/fritzwan/fritzwan.sh "$DESTDIR$EXTDIR/fritzwan.sh" || exit 1
inst 0644 extensions/fritzwan/fritzwan.cfg "$DESTDIR$ETCDIR/fritzwan.cfg$SUF" || exit 1
inst 0644 packaging/common/tasks.d/fritzwan.cfg "$DESTDIR$ETCDIR/tasks.d/fritzwan.cfg$SUF" || exit 1

# ntfy-alert is an alert script run by xymond_alert (alerts.cfg SCRIPT
# rule) on the Xymon server, not a client test - no tasks.d snippet.
inst 0755 extensions/ntfy-alert/ntfy-alert.sh "$DESTDIR$EXTDIR/ntfy-alert.sh" || exit 1
inst 0644 extensions/ntfy-alert/ntfy-alert.cfg "$DESTDIR$ETCDIR/ntfy-alert.cfg$SUF" || exit 1

if [ "$DOCDIR" != "-" ]; then
    mkdir -p "$DESTDIR$DOCDIR/smart/server" "$DESTDIR$DOCDIR/fritzdsl/server" \
        "$DESTDIR$DOCDIR/fritzwan/server" || exit 1
    inst 0644 README.md "$DESTDIR$DOCDIR/README.md" || exit 1
    for ext in temp la memory ntfy-alert; do
        mkdir -p "$DESTDIR$DOCDIR/$ext" || exit 1
        inst 0644 "extensions/$ext/README.md" "$DESTDIR$DOCDIR/$ext/README.md" || exit 1
    done
    inst 0644 extensions/smart/README.md "$DESTDIR$DOCDIR/smart/README.md" || exit 1
    inst 0644 extensions/smart/sudoers.example "$DESTDIR$DOCDIR/smart/sudoers.example" || exit 1
    inst 0644 extensions/smart/server/README.md "$DESTDIR$DOCDIR/smart/server/README.md" || exit 1
    inst 0644 extensions/smart/server/graphs-smart.cfg "$DESTDIR$DOCDIR/smart/server/graphs-smart.cfg" || exit 1
    inst 0644 extensions/fritzdsl/README.md "$DESTDIR$DOCDIR/fritzdsl/README.md" || exit 1
    inst 0644 extensions/fritzdsl/server/README.md "$DESTDIR$DOCDIR/fritzdsl/server/README.md" || exit 1
    inst 0644 extensions/fritzdsl/server/graphs-fritzdsl.cfg "$DESTDIR$DOCDIR/fritzdsl/server/graphs-fritzdsl.cfg" || exit 1
    inst 0644 extensions/fritzwan/README.md "$DESTDIR$DOCDIR/fritzwan/README.md" || exit 1
    inst 0644 extensions/fritzwan/server/README.md "$DESTDIR$DOCDIR/fritzwan/server/README.md" || exit 1
    inst 0644 extensions/fritzwan/server/graphs-fritzwan.cfg "$DESTDIR$DOCDIR/fritzwan/server/graphs-fritzwan.cfg" || exit 1
fi

exit 0
