#!/bin/sh
# stage-server.sh - copy all installable files of the SERVER package
# into a package staging tree. Counterpart of stage.sh (which stages
# the client package); the server-side file list lives here and only
# here.
#
# usage: stage-server.sh DESTDIR ETCDIR DOCDIR [CFGSUFFIX]
#
#   DESTDIR    staging root (buildroot)
#   ETCDIR     absolute path of the Xymon SERVER config directory,
#              i.e. the one holding xymonserver.cfg, graphs.cfg and
#              rrddefinitions.cfg (Debian/Ubuntu: /etc/xymon)
#   DOCDIR     absolute path of the documentation directory,
#              or "-" to skip the docs
#   CFGSUFFIX  optional suffix appended to config files
#              (FreeBSD would use ".sample"; unused so far)
#
# What lands where: the drop-in files of every extension go into the
# subdirectory of ETCDIR that Xymon reads them from - xymonserver.d,
# graphs.d, rrddefinitions.d. Nothing is written into a stock Xymon
# config file; whether those directories are actually read is the
# packaging's business (see packaging/deb-server/postinst).
#
# Note for Debian/Ubuntu: ETCDIR is /etc/xymon for both the server and
# the client, so this must never install anything the client package
# - or any other package - also ships. It stays inside the three
# drop-in directories above, which belong to the server alone (the
# client uses clientlaunch.d and xymonclient.d), and skips the file
# names another package already claims (SKIP_EXTENSIONS below);
# tests/run.sh asserts both.
#
# Must be run from the repository root.
set -u

if [ $# -lt 3 ]; then
    echo "usage: $0 DESTDIR ETCDIR DOCDIR [CFGSUFFIX]" >&2
    exit 1
fi

DESTDIR=$1
ETCDIR=$2
DOCDIR=$3
SUF=${4:-}

# No install(1) here - same reason as in stage.sh.
inst() { # inst MODE SRC DST
    cp "$2" "$3" && chmod "$1" "$3"
}

# Extensions whose drop-ins are NOT installed, because their file name
# is already taken in these shared directories: hobbit-plugins ships
# xymonserver.d/temp.cfg and graphs.d/temp.cfg of its own, and dpkg
# refuses two packages that claim the same path. Their configuration
# ships as documentation instead (see below) and is documented in
# extensions/temp/server/README.md.
SKIP_EXTENSIONS="temp"

# Every extension that produces RRD graphs. "disk" is missing on
# purpose: it reports into the standard disk column and is handled by
# the server's built-in parser, so it needs no server-side config.
EXTENSIONS="smart temp la memory opkg fritzdsl fritzwan wifi if_link xymonext"

skipped() { # skipped NAME
    for skip in $SKIP_EXTENSIONS; do
        [ "$1" = "$skip" ] && return 0
    done
    return 1
}

for ext in $EXTENSIONS; do
    skipped "$ext" && continue
    for dropin in xymonserver.d graphs.d rrddefinitions.d; do
        src="extensions/$ext/server/$dropin/$ext.cfg"
        [ -f "$src" ] || continue
        mkdir -p "$DESTDIR$ETCDIR/$dropin" || exit 1
        inst 0644 "$src" "$DESTDIR$ETCDIR/$dropin/$ext.cfg$SUF" || exit 1
    done
done

if [ "$DOCDIR" != "-" ]; then
    mkdir -p "$DESTDIR$DOCDIR" || exit 1
    inst 0644 README.md "$DESTDIR$DOCDIR/README.md" || exit 1
    for ext in $EXTENSIONS; do
        mkdir -p "$DESTDIR$DOCDIR/$ext" || exit 1
        inst 0644 "extensions/$ext/server/README.md" \
            "$DESTDIR$DOCDIR/$ext/README.md" || exit 1
    done

    # The drop-ins that are not installed (see SKIP_EXTENSIONS) ship
    # here instead, so they can be put in place by hand.
    for ext in $SKIP_EXTENSIONS; do
        for dropin in xymonserver.d graphs.d rrddefinitions.d; do
            src="extensions/$ext/server/$dropin/$ext.cfg"
            [ -f "$src" ] || continue
            mkdir -p "$DESTDIR$DOCDIR/$ext/$dropin" || exit 1
            inst 0644 "$src" "$DESTDIR$DOCDIR/$ext/$dropin/$ext.cfg" || exit 1
        done
    done
fi

exit 0
