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

if [ "$DOCDIR" != "-" ]; then
    mkdir -p "$DESTDIR$DOCDIR/smart/server/graphs.d" \
        "$DESTDIR$DOCDIR/fritzdsl/server/graphs.d" \
        "$DESTDIR$DOCDIR/fritzwan/server/graphs.d" \
        "$DESTDIR$DOCDIR/wifi/server/graphs.d" \
        "$DESTDIR$DOCDIR/if_link/server/graphs.d" || exit 1
    inst 0644 README.md "$DESTDIR$DOCDIR/README.md" || exit 1
    for ext in temp la memory disk opkg; do
        mkdir -p "$DESTDIR$DOCDIR/$ext" || exit 1
        inst 0644 "extensions/$ext/README.md" "$DESTDIR$DOCDIR/$ext/README.md" || exit 1
    done
    inst 0644 extensions/smart/README.md "$DESTDIR$DOCDIR/smart/README.md" || exit 1
    inst 0644 extensions/smart/sudoers.example "$DESTDIR$DOCDIR/smart/sudoers.example" || exit 1
    inst 0644 extensions/smart/server/README.md "$DESTDIR$DOCDIR/smart/server/README.md" || exit 1
    inst 0644 extensions/smart/server/graphs.d/smart.cfg "$DESTDIR$DOCDIR/smart/server/graphs.d/smart.cfg" || exit 1
    inst 0644 extensions/fritzdsl/README.md "$DESTDIR$DOCDIR/fritzdsl/README.md" || exit 1
    inst 0644 extensions/fritzdsl/server/README.md "$DESTDIR$DOCDIR/fritzdsl/server/README.md" || exit 1
    inst 0644 extensions/fritzdsl/server/graphs.d/fritzdsl.cfg "$DESTDIR$DOCDIR/fritzdsl/server/graphs.d/fritzdsl.cfg" || exit 1
    inst 0644 extensions/fritzwan/README.md "$DESTDIR$DOCDIR/fritzwan/README.md" || exit 1
    inst 0644 extensions/fritzwan/server/README.md "$DESTDIR$DOCDIR/fritzwan/server/README.md" || exit 1
    inst 0644 extensions/fritzwan/server/graphs.d/fritzwan.cfg "$DESTDIR$DOCDIR/fritzwan/server/graphs.d/fritzwan.cfg" || exit 1
    inst 0644 extensions/wifi/README.md "$DESTDIR$DOCDIR/wifi/README.md" || exit 1
    inst 0644 extensions/wifi/server/README.md "$DESTDIR$DOCDIR/wifi/server/README.md" || exit 1
    inst 0644 extensions/wifi/server/graphs.d/wifi.cfg "$DESTDIR$DOCDIR/wifi/server/graphs.d/wifi.cfg" || exit 1
    inst 0644 extensions/if_link/README.md "$DESTDIR$DOCDIR/if_link/README.md" || exit 1
    inst 0644 extensions/if_link/server/README.md "$DESTDIR$DOCDIR/if_link/server/README.md" || exit 1
    inst 0644 extensions/if_link/server/graphs.d/if_link.cfg "$DESTDIR$DOCDIR/if_link/server/graphs.d/if_link.cfg" || exit 1
fi

exit 0
