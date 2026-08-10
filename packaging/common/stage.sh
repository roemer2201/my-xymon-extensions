#!/bin/sh
# stage.sh - copy all installable files into a package staging tree.
# Shared by the deb, rpm and FreeBSD package builds so the file list
# lives in exactly one place.
#
# usage: stage.sh DESTDIR EXTDIR ETCDIR TASKSDIR DOCDIR [CFGSUFFIX]
#
#   DESTDIR    staging root (buildroot)
#   EXTDIR     absolute path of the Xymon client ext/ directory
#   ETCDIR     absolute path of the config directory
#   TASKSDIR   absolute path of the xymonlaunch tasks.d directory,
#              or "-" to skip the snippets (opkg: no xymonlaunch)
#   DOCDIR     absolute path of the documentation directory,
#              or "-" to skip the docs (opkg: flash space)
#   CFGSUFFIX  optional suffix appended to config files
#              (FreeBSD uses ".sample" for @sample handling)
#
# Must be run from the repository root.
set -u

if [ $# -lt 5 ]; then
    echo "usage: $0 DESTDIR EXTDIR ETCDIR TASKSDIR DOCDIR [CFGSUFFIX]" >&2
    exit 1
fi

DESTDIR=$1
EXTDIR=$2
ETCDIR=$3
TASKSDIR=$4
DOCDIR=$5
SUF=${6:-}

# No install(1) here: BusyBox on OpenWrt/TurrisOS has no install
# applet, and the opkg build must run there.
inst() { # inst MODE SRC DST
    cp "$2" "$3" && chmod "$1" "$3"
}

mkdir -p "$DESTDIR$EXTDIR" "$DESTDIR$ETCDIR" || exit 1
if [ "$TASKSDIR" != "-" ]; then
    mkdir -p "$DESTDIR$TASKSDIR" || exit 1
fi

task() { # task NAME
    [ "$TASKSDIR" = "-" ] && return 0
    inst 0644 "packaging/common/tasks.d/$1.cfg" "$DESTDIR$TASKSDIR/$1.cfg$SUF"
}

for ext in smart temp la memory disk opkg wifi if_link; do
    inst 0755 "extensions/$ext/$ext.sh" "$DESTDIR$EXTDIR/$ext.sh" || exit 1
    inst 0644 "extensions/$ext/$ext.cfg" "$DESTDIR$ETCDIR/$ext.cfg$SUF" || exit 1
    task "$ext" || exit 1
done

inst 0755 extensions/fritzdsl/fritzdsl.sh "$DESTDIR$EXTDIR/fritzdsl.sh" || exit 1
inst 0644 extensions/fritzdsl/fritzdsl.cfg "$DESTDIR$ETCDIR/fritzdsl.cfg$SUF" || exit 1
task fritzdsl || exit 1

inst 0755 extensions/fritzwan/fritzwan.sh "$DESTDIR$EXTDIR/fritzwan.sh" || exit 1
inst 0644 extensions/fritzwan/fritzwan.cfg "$DESTDIR$ETCDIR/fritzwan.cfg$SUF" || exit 1
task fritzwan || exit 1

# xymonext measures the other extensions and therefore has no task of
# its own: the tasks.d snippets above call it with the extension to
# run. Two scripts: the wrapper and the shim it puts in front of
# $XYMON to count the bytes an extension sends.
inst 0755 extensions/xymonext/xymonext.sh "$DESTDIR$EXTDIR/xymonext.sh" || exit 1
inst 0755 extensions/xymonext/xymonext-send.sh "$DESTDIR$EXTDIR/xymonext-send.sh" || exit 1
inst 0644 extensions/xymonext/xymonext.cfg "$DESTDIR$ETCDIR/xymonext.cfg$SUF" || exit 1

if [ "$DOCDIR" != "-" ]; then
    mkdir -p "$DESTDIR$DOCDIR" || exit 1
    inst 0644 README.md "$DESTDIR$DOCDIR/README.md" || exit 1

    # Client-side documentation: one README per extension.
    for ext in smart temp la memory disk opkg fritzdsl fritzwan wifi \
        if_link xymonext; do
        mkdir -p "$DESTDIR$DOCDIR/$ext" || exit 1
        inst 0644 "extensions/$ext/README.md" "$DESTDIR$DOCDIR/$ext/README.md" || exit 1
    done
    inst 0644 extensions/smart/sudoers.example "$DESTDIR$DOCDIR/smart/sudoers.example" || exit 1

    # Server-side documentation: the README plus the ready-made drop-in
    # files for the Xymon server's xymonserver.d, graphs.d and (rarely)
    # rrddefinitions.d directories. Every extension with RRD graphs has
    # them; "disk" uses the server's built-in handler and has none.
    for ext in smart temp la memory opkg fritzdsl fritzwan wifi \
        if_link xymonext; do
        mkdir -p "$DESTDIR$DOCDIR/$ext/server" || exit 1
        inst 0644 "extensions/$ext/server/README.md" \
            "$DESTDIR$DOCDIR/$ext/server/README.md" || exit 1
        for dropin in xymonserver.d graphs.d rrddefinitions.d; do
            [ -f "extensions/$ext/server/$dropin/$ext.cfg" ] || continue
            mkdir -p "$DESTDIR$DOCDIR/$ext/server/$dropin" || exit 1
            inst 0644 "extensions/$ext/server/$dropin/$ext.cfg" \
                "$DESTDIR$DOCDIR/$ext/server/$dropin/$ext.cfg" || exit 1
        done
    done
fi

exit 0
