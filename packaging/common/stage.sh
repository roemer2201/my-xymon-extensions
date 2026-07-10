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

inst 0755 extensions/smart/smart.sh "$DESTDIR$EXTDIR/smart.sh" || exit 1
inst 0644 extensions/smart/smart.cfg "$DESTDIR$ETCDIR/smart.cfg$SUF" || exit 1
inst 0644 packaging/common/tasks.d/smart.cfg "$DESTDIR$ETCDIR/tasks.d/smart.cfg$SUF" || exit 1

if [ "$DOCDIR" != "-" ]; then
    mkdir -p "$DESTDIR$DOCDIR/smart/server" || exit 1
    inst 0644 README.md "$DESTDIR$DOCDIR/README.md" || exit 1
    inst 0644 extensions/smart/README.md "$DESTDIR$DOCDIR/smart/README.md" || exit 1
    inst 0644 extensions/smart/sudoers.example "$DESTDIR$DOCDIR/smart/sudoers.example" || exit 1
    inst 0644 extensions/smart/server/README.md "$DESTDIR$DOCDIR/smart/server/README.md" || exit 1
    inst 0644 extensions/smart/server/graphs-smart.cfg "$DESTDIR$DOCDIR/smart/server/graphs-smart.cfg" || exit 1
fi

exit 0
