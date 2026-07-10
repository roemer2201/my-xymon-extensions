#!/bin/sh
# Build the FreeBSD package with pkg-create(8).
# FreeBSD layout (ports net-mgmt/xymon-client):
# XYMONHOME=/usr/local/www/xymon/client
set -u

cd "$(dirname "$0")/../.." || exit 1

if ! command -v pkg >/dev/null 2>&1; then
    echo "pkg(8) not found - FreeBSD packages can only be built on FreeBSD" >&2
    exit 1
fi

PKG=my-xymon-extensions
VERSION=$(cat VERSION) || exit 1
BUILD=build/freebsd
STAGE=$BUILD/stage

rm -rf "$BUILD"
mkdir -p "$STAGE" "$BUILD/out" || exit 1

# Config files are staged with a .sample suffix; the @sample keywords
# in pkg-plist install/remove the real files on the target system.
sh packaging/common/stage.sh "$STAGE" \
    /usr/local/www/xymon/client/ext \
    /usr/local/www/xymon/client/etc \
    "/usr/local/share/doc/$PKG" \
    .sample || exit 1

sed -e "s/@VERSION@/$VERSION/" packaging/freebsd/MANIFEST.in > "$BUILD/MANIFEST" || exit 1

pkg create -M "$BUILD/MANIFEST" -p packaging/freebsd/pkg-plist \
    -r "$STAGE" -o "$BUILD/out" || exit 1

echo "Created:"
find "$(pwd)/$BUILD/out" -type f
