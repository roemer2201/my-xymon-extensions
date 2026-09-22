#!/bin/sh
# stage-server.sh - copy all installable files of the SERVER package
# into a package staging tree. Counterpart of stage.sh (which stages
# the client package); the server-side file list lives here and only
# here.
#
# usage: stage-server.sh DESTDIR BINDIR ETCDIR DOCDIR [CFGSUFFIX]
#
#   DESTDIR    staging root (buildroot)
#   BINDIR     absolute path of the directory for the server-side
#              collector programs, i.e. the server's ext/ directory
#              (Debian/Ubuntu: /usr/lib/xymon/server/ext)
#   ETCDIR     absolute path of the Xymon SERVER config directory,
#              i.e. the one holding xymonserver.cfg, graphs.cfg and
#              rrddefinitions.cfg (Debian/Ubuntu: /etc/xymon)
#   DOCDIR     absolute path of the documentation directory,
#              or "-" to skip the docs
#   CFGSUFFIX  optional suffix appended to config files
#              (FreeBSD would use ".sample"; unused so far)
#
# The argument order mirrors stage.sh (staging root, program directory,
# config directory, ..., docs). Both directories are arguments and not
# constants here, so a packaging with a different layout only has to pass
# its own paths: the files that name them carry @BINDIR@/@ETCDIR@
# placeholders and are rewritten on the way into the staging tree.
#
# What lands where: the drop-in files of every extension go into the
# subdirectory of ETCDIR that Xymon reads them from - xymonserver.d,
# graphs.d, rrddefinitions.d, tasks.d. The server-only powerline collector,
# its private config and read-only helper are staged here as well.
# Nothing is written into a stock Xymon
# config file; whether those directories are actually read is the
# packaging's business (see packaging/deb-server/postinst).
#
# Note for Debian/Ubuntu: ETCDIR is /etc/xymon for both the server and
# the client, so this must never install anything the client package
# - or any other package - also ships. It uses the server
# drop-in directories above, which belong to the server alone (the
# client uses clientlaunch.d and xymonclient.d), and skips the file
# names another package already claims (SKIP_EXTENSIONS below). Powerline's
# config uses my-xymon-extensions-server, never the client's package directory;
# tests/run.sh asserts both.
#
# Must be run from the repository root.
set -u

if [ $# -lt 4 ]; then
    echo "usage: $0 DESTDIR BINDIR ETCDIR DOCDIR [CFGSUFFIX]" >&2
    exit 1
fi

DESTDIR=$1
BINDIR=$2
ETCDIR=$3
DOCDIR=$4
SUF=${5:-}

case "$BINDIR" in /*) ;; *) echo "BINDIR must be absolute" >&2; exit 1 ;; esac
case "$ETCDIR" in /*) ;; *) echo "ETCDIR must be absolute" >&2; exit 1 ;; esac

# No install(1) here - same reason as in stage.sh.
inst() { # inst MODE SRC DST
    cp "$2" "$3" && chmod "$1" "$3"
}

# Same, but resolve the @BINDIR@/@ETCDIR@ placeholders on the way. Writing
# the output straight to the destination avoids "sed -i", which is not
# portable. Files without placeholders pass through unchanged, so this is
# safe to use for every config file.
instsub() { # instsub MODE SRC DST
    sed -e "s|@BINDIR@|$BINDIR|g" -e "s|@ETCDIR@|$ETCDIR|g" "$2" > "$3" &&
        chmod "$1" "$3"
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
EXTENSIONS="smart temp la memory opkg fritzdsl fritzwan wifi if_link lxc xymonext powerline"

skipped() { # skipped NAME
    for skip in $SKIP_EXTENSIONS; do
        [ "$1" = "$skip" ] && return 0
    done
    return 1
}

for ext in $EXTENSIONS; do
    skipped "$ext" && continue
    for dropin in xymonserver.d graphs.d rrddefinitions.d tasks.d; do
        src="extensions/$ext/server/$dropin/$ext.cfg"
        [ -f "$src" ] || continue
        mkdir -p "$DESTDIR$ETCDIR/$dropin" || exit 1
        instsub 0644 "$src" "$DESTDIR$ETCDIR/$dropin/$ext.cfg$SUF" || exit 1
    done
done

# The first server-side collector. Keep this entirely out of stage.sh so a
# combined client/server installation never schedules the same test twice.
mkdir -p "$DESTDIR$BINDIR" "$DESTDIR$ETCDIR/my-xymon-extensions-server" || exit 1
for file in powerline.sh powerline-read.sh; do
    inst 0755 "extensions/powerline/$file" "$DESTDIR$BINDIR/$file" || exit 1
done
for file in powerline-parse.awk powerline-state.awk; do
    inst 0644 "extensions/powerline/$file" "$DESTDIR$BINDIR/$file" || exit 1
done
for file in powerline.cfg powerline.map; do
    instsub 0644 "extensions/powerline/$file" "$DESTDIR$ETCDIR/my-xymon-extensions-server/$file$SUF" || exit 1
done

if [ "$DOCDIR" != "-" ]; then
    mkdir -p "$DESTDIR$DOCDIR" || exit 1
    inst 0644 README.md "$DESTDIR$DOCDIR/README.md" || exit 1
    for ext in $EXTENSIONS; do
        mkdir -p "$DESTDIR$DOCDIR/$ext" || exit 1
        inst 0644 "extensions/$ext/server/README.md" \
            "$DESTDIR$DOCDIR/$ext/README.md" || exit 1
    done
    instsub 0644 extensions/powerline/powerline.sudoers \
        "$DESTDIR$DOCDIR/powerline/powerline.sudoers" || exit 1

    # The drop-ins that are not installed (see SKIP_EXTENSIONS) ship
    # here instead, so they can be put in place by hand.
    for ext in $SKIP_EXTENSIONS; do
        for dropin in xymonserver.d graphs.d rrddefinitions.d; do
            src="extensions/$ext/server/$dropin/$ext.cfg"
            [ -f "$src" ] || continue
            mkdir -p "$DESTDIR$DOCDIR/$ext/$dropin" || exit 1
            instsub 0644 "$src" "$DESTDIR$DOCDIR/$ext/$dropin/$ext.cfg" || exit 1
        done
    done
fi

exit 0
