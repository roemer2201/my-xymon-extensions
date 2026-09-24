#!/bin/sh
# stage-server.sh - copy all installable files of the SERVER package
# into a staging tree. Counterpart of stage.sh; the server file list
# lives here and only here.
#
# usage: stage-server.sh DESTDIR BINDIR ETCDIR DOCDIR SUDOERSDIR [CFGSUFFIX]
#
#   DESTDIR    staging root
#   BINDIR     server ext/ directory (Debian: /usr/lib/xymon/server/ext)
#   ETCDIR     server config directory (Debian: /etc/xymon)
#   DOCDIR     documentation directory, or "-"
#   SUDOERSDIR sudoers.d (Debian: /etc/sudoers.d), or "-"; not below ETCDIR
#   CFGSUFFIX  optional config file suffix (unused so far)
#
# Files naming these paths carry @BINDIR@/@ETCDIR@ and are rewritten on
# the way. Drop-ins go to xymonserver.d, graphs.d, rrddefinitions.d and
# tasks.d; nothing touches a stock config file. On Debian the client
# shares /etc/xymon, so nothing here may be a path the client package or
# another package ships (see SKIP_EXTENSIONS; tests/run.sh checks it).
#
# Must be run from the repository root.
set -u

if [ $# -lt 5 ]; then
    echo "usage: $0 DESTDIR BINDIR ETCDIR DOCDIR SUDOERSDIR [CFGSUFFIX]" >&2
    exit 1
fi

DESTDIR=$1
BINDIR=$2
ETCDIR=$3
DOCDIR=$4
SUDOERSDIR=$5
SUF=${6:-}

case "$BINDIR" in /*) ;; *) echo "BINDIR must be absolute" >&2; exit 1 ;; esac
case "$ETCDIR" in /*) ;; *) echo "ETCDIR must be absolute" >&2; exit 1 ;; esac
case "$SUDOERSDIR" in
    -|/*) ;;
    *) echo "SUDOERSDIR must be absolute or \"-\"" >&2; exit 1 ;;
esac

# No install(1) here - same reason as in stage.sh.
inst() { # inst MODE SRC DST
    cp "$2" "$3" && chmod "$1" "$3"
}

# Same, resolving @BINDIR@/@ETCDIR@ (no "sed -i": not portable).
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
EXTENSIONS="smart temp la memory opkg fritzdsl fritzwan wifi if_link lxc xymonext powerline fritz-wifi"

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

# The server-only powerline collector; never in stage.sh, or a combined
# client/server host would run it twice.
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

# The server-only fritz-wifi collector (TR-064 over curl); never in
# stage.sh either. Its password file is NOT installed: it holds secrets,
# must belong to xymon with mode 600, and a conffile would be neither.
inst 0755 extensions/fritz-wifi/fritz-wifi.sh "$DESTDIR$BINDIR/fritz-wifi.sh" || exit 1
instsub 0644 extensions/fritz-wifi/fritz-wifi.cfg \
    "$DESTDIR$ETCDIR/my-xymon-extensions-server/fritz-wifi.cfg$SUF" || exit 1

# powerline's sudo rule, installed with the rule commented out (powerline
# ships disabled). Mode 0440; no dot in the name (sudo would ignore it);
# not "xymon", which hobbit-plugins owns.
if [ "$SUDOERSDIR" != "-" ]; then
    mkdir -p "$DESTDIR$SUDOERSDIR" || exit 1
    instsub 0440 extensions/powerline/powerline.sudoers \
        "$DESTDIR$SUDOERSDIR/my-xymon-extensions-server$SUF" || exit 1
fi

if [ "$DOCDIR" != "-" ]; then
    mkdir -p "$DESTDIR$DOCDIR" || exit 1
    inst 0644 README.md "$DESTDIR$DOCDIR/README.md" || exit 1
    for ext in $EXTENSIONS; do
        mkdir -p "$DESTDIR$DOCDIR/$ext" || exit 1
        inst 0644 "extensions/$ext/server/README.md" \
            "$DESTDIR$DOCDIR/$ext/README.md" || exit 1
    done
    # Reference copy of the sudo rule.
    instsub 0644 extensions/powerline/powerline.sudoers \
        "$DESTDIR$DOCDIR/powerline/powerline.sudoers" || exit 1
    # Template for the fritz-wifi password file.
    inst 0644 extensions/fritz-wifi/fritz.passwd.example \
        "$DESTDIR$DOCDIR/fritz-wifi/fritz.passwd.example" || exit 1

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
