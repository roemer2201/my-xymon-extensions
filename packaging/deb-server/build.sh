#!/bin/sh
# Build the .deb of the SERVER package with dpkg-deb (no debhelper).
# Debian/Ubuntu layout: the Xymon server keeps its configuration in
# /etc/xymon - the same directory the client uses, which is why this
# package only ever writes into the three drop-in directories that
# belong to the server (xymonserver.d, graphs.d, rrddefinitions.d).
set -u

cd "$(dirname "$0")/../.." || exit 1

if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "dpkg-deb not found - .deb packages can only be built on Debian/Ubuntu" >&2
    exit 1
fi

PKG=my-xymon-extensions-server
VERSION=$(cat VERSION) || exit 1
BUILD=build/deb-server
ROOT=$BUILD/root

rm -rf "$BUILD"
mkdir -p "$ROOT/DEBIAN" || exit 1

sh packaging/common/stage-server.sh "$ROOT" \
    /etc/xymon \
    "/usr/share/doc/$PKG" || exit 1

sed -e "s/@VERSION@/$VERSION/" packaging/deb-server/control.in > "$ROOT/DEBIAN/control" || exit 1
# cp+chmod instead of install(1) for consistency with the scripts that
# must run under BusyBox (see packaging/common/stage.sh).
cp packaging/deb-server/conffiles "$ROOT/DEBIAN/conffiles" || exit 1
chmod 0644 "$ROOT/DEBIAN/conffiles" || exit 1
cp packaging/deb-server/postinst "$ROOT/DEBIAN/postinst" || exit 1
chmod 0755 "$ROOT/DEBIAN/postinst" || exit 1

DEBFILE="build/${PKG}_${VERSION}-1_all.deb"
dpkg-deb --build --root-owner-group "$ROOT" "$DEBFILE" || exit 1

echo "Created: $(pwd)/$DEBFILE"
