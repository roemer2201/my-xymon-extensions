#!/bin/sh
# Build the OpenWrt/TurrisOS package (.ipk) with the standalone runner.
# An .ipk is just tar+gzip (control.tar.gz + data.tar.gz), so this
# builds on any platform without the OpenWrt SDK - the package is
# Architecture: all (shell scripts only).
set -u

cd "$(dirname "$0")/../.." || exit 1

PKG=my-xymon-extensions
VERSION=$(cat VERSION) || exit 1
BUILD=build/opkg
DATA=$BUILD/data
CTRL=$BUILD/control
OUT=$BUILD/out
LIBDIR=/usr/lib/xymon-standalone
ETCDIR=/etc/xymon-standalone

# All configuration lives in /etc/xymon-standalone/ (a conffile
# directory, preserved on sysupgrade); no tasks.d snippets (no
# xymonlaunch on routers) and no docs (flash space).
rm -rf "$BUILD"
mkdir -p "$DATA" "$CTRL" "$OUT" || exit 1
sh packaging/common/stage.sh "$DATA" "$LIBDIR/ext" "$ETCDIR" - - || exit 1

# No install(1) here: BusyBox on OpenWrt/TurrisOS has no install
# applet, and this build must run there.
inst() { # inst MODE SRC DST
    cp "$2" "$3" && chmod "$1" "$3"
}

# Standalone runtime + main config. The extensions read their config
# from $XYMONHOME/etc/<name>.cfg, so etc/ is a symlink to $ETCDIR.
inst 0755 standalone/xymon-run.sh "$DATA$LIBDIR/xymon-run.sh" || exit 1
inst 0755 standalone/xymon-send.sh "$DATA$LIBDIR/xymon-send.sh" || exit 1
ln -s "$ETCDIR" "$DATA$LIBDIR/etc" || exit 1
inst 0644 standalone/standalone.cfg "$DATA$ETCDIR/standalone.cfg" || exit 1

sed -e "s/@VERSION@/$VERSION/" packaging/opkg/control.in > "$CTRL/control" || exit 1
inst 0644 packaging/opkg/conffiles "$CTRL/conffiles" || exit 1
inst 0755 packaging/opkg/postinst "$CTRL/postinst" || exit 1

# GNU tar can normalize file ownership to root; with BSD tar the build
# still works, the archive then records the building user.
TAROWN=""
if tar --version 2>/dev/null | grep -q GNU; then
    TAROWN="--owner=0 --group=0 --numeric-owner"
fi

echo "2.0" > "$BUILD/debian-binary"
# shellcheck disable=SC2086  # $TAROWN is intentionally word-split
(cd "$CTRL" && tar $TAROWN -czf ../control.tar.gz .) || exit 1
# shellcheck disable=SC2086
(cd "$DATA" && tar $TAROWN -czf ../data.tar.gz .) || exit 1
# shellcheck disable=SC2086
(cd "$BUILD" && tar $TAROWN -czf "out/${PKG}_${VERSION}-1_all.ipk" \
    ./debian-binary ./control.tar.gz ./data.tar.gz) || exit 1

echo "Created: $(pwd)/$OUT/${PKG}_${VERSION}-1_all.ipk"
