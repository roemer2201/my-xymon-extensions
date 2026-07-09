#!/bin/sh
# Build the .deb package with dpkg-deb (no debhelper required).
# Debian/Ubuntu layout: the Xymon client lives in /usr/lib/xymon/client
# and its config in /etc/xymon ($XYMONCLIENTHOME/etc is a symlink to it).
set -u

cd "$(dirname "$0")/../.." || exit 1

if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "dpkg-deb not found - .deb packages can only be built on Debian/Ubuntu" >&2
    exit 1
fi

PKG=my-xymon-extensions
VERSION=$(cat VERSION) || exit 1
BUILD=build/deb
ROOT=$BUILD/root

rm -rf "$BUILD"
mkdir -p "$ROOT/DEBIAN" || exit 1

sh packaging/common/stage.sh "$ROOT" \
    /usr/lib/xymon/client/ext \
    /etc/xymon \
    "/usr/share/doc/$PKG" || exit 1

sed -e "s/@VERSION@/$VERSION/" packaging/deb/control.in > "$ROOT/DEBIAN/control" || exit 1
install -m 0644 packaging/deb/conffiles "$ROOT/DEBIAN/conffiles" || exit 1
install -m 0755 packaging/deb/postinst "$ROOT/DEBIAN/postinst" || exit 1

dpkg-deb --build --root-owner-group "$ROOT" \
    "build/${PKG}_${VERSION}-1_all.deb" || exit 1

echo "Created: build/${PKG}_${VERSION}-1_all.deb"
