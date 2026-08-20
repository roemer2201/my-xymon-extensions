#!/bin/sh
# stage.sh - copy all installable files into a package staging tree.
# Shared by the deb, rpm and FreeBSD package builds so the file list
# lives in exactly one place.
#
# usage: stage.sh DESTDIR EXTDIR ETCDIR LAUNCHDIR DOCDIR [CFGSUFFIX]
#
#   DESTDIR    staging root (buildroot)
#   EXTDIR     absolute path of the Xymon client ext/ directory
#   ETCDIR     absolute path of the config directory
#   LAUNCHDIR  absolute path of the xymonlaunch drop-in directory for
#              CLIENT tasks - clientlaunch.d, not tasks.d: the latter
#              belongs to the server's xymonlaunch (on Debian its
#              tasks.cfg reads both, so a snippet in tasks.d runs twice
#              on a host that is client and server). "-" skips the
#              snippets (opkg: no xymonlaunch at all)
#   DOCDIR     absolute path of the documentation directory,
#              or "-" to skip the docs (opkg: flash space)
#   CFGSUFFIX  optional suffix appended to config files
#              (FreeBSD uses ".sample" for @sample handling)
#
# Must be run from the repository root.
set -u

if [ $# -lt 5 ]; then
    echo "usage: $0 DESTDIR EXTDIR ETCDIR LAUNCHDIR DOCDIR [CFGSUFFIX]" >&2
    exit 1
fi

DESTDIR=$1
EXTDIR=$2
ETCDIR=$3
LAUNCHDIR=$4
DOCDIR=$5
SUF=${6:-}

# No install(1) here: BusyBox on OpenWrt/TurrisOS has no install
# applet, and the opkg build must run there.
inst() { # inst MODE SRC DST
    cp "$2" "$3" && chmod "$1" "$3"
}

# Extensions whose xymonlaunch snippet is NOT installed, because the
# file name is already taken in the shared clientlaunch.d directory:
# hobbit-plugins ships a temp.cfg of its own there, and dpkg refuses
# two packages that claim the same path. The snippet is still shipped
# as documentation - see the doc section at the end of this file and
# extensions/temp/README.md.
SKIP_SNIPPETS="temp"

mkdir -p "$DESTDIR$EXTDIR" "$DESTDIR$ETCDIR" || exit 1
if [ "$LAUNCHDIR" != "-" ]; then
    mkdir -p "$DESTDIR$LAUNCHDIR" || exit 1
fi

task() { # task NAME
    [ "$LAUNCHDIR" = "-" ] && return 0
    for skip in $SKIP_SNIPPETS; do
        [ "$1" = "$skip" ] && return 0
    done
    inst 0644 "packaging/common/clientlaunch.d/$1.cfg" \
        "$DESTDIR$LAUNCHDIR/$1.cfg$SUF"
}

for ext in smart temp la memory disk opkg wifi if_link lxc; do
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
# its own: the clientlaunch.d snippets above call it with the extension to
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
        if_link lxc xymonext; do
        mkdir -p "$DESTDIR$DOCDIR/$ext" || exit 1
        inst 0644 "extensions/$ext/README.md" "$DESTDIR$DOCDIR/$ext/README.md" || exit 1
    done
    inst 0644 extensions/smart/sudoers.example "$DESTDIR$DOCDIR/smart/sudoers.example" || exit 1

    # The launch snippets that are not installed (see SKIP_SNIPPETS)
    # ship here instead, so they can be put in place by hand.
    for ext in $SKIP_SNIPPETS; do
        mkdir -p "$DESTDIR$DOCDIR/$ext/clientlaunch.d" || exit 1
        inst 0644 "packaging/common/clientlaunch.d/$ext.cfg" \
            "$DESTDIR$DOCDIR/$ext/clientlaunch.d/$ext.cfg" || exit 1
    done

    # Server-side documentation: the README plus the ready-made drop-in
    # files for the Xymon server's xymonserver.d, graphs.d and (rarely)
    # rrddefinitions.d directories. Every extension with RRD graphs has
    # them; "disk" uses the server's built-in handler and has none.
    for ext in smart temp la memory opkg fritzdsl fritzwan wifi \
        if_link lxc xymonext; do
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
