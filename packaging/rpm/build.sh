#!/bin/sh
# Build the .rpm package with rpmbuild.
# EL/Rocky layout: XYMONHOME=/usr/lib64/xymon/client (Terabithia builds);
# override with: sh build.sh --define 'xymonhome /path/to/client'
# (extra arguments are passed through to rpmbuild).
set -u

cd "$(dirname "$0")/../.." || exit 1

if ! command -v rpmbuild >/dev/null 2>&1; then
    echo "rpmbuild not found - .rpm packages need the rpm-build tooling" >&2
    exit 1
fi

PKG=my-xymon-extensions
VERSION=$(cat VERSION) || exit 1
TOP=$(pwd)/build/rpm

rm -rf "$TOP"
mkdir -p "$TOP/BUILD" "$TOP/RPMS" "$TOP/SOURCES" "$TOP/SPECS" "$TOP/SRPMS" || exit 1

# Source tarball from the working tree (only what the build needs)
STAGE="$TOP/SOURCES/${PKG}-${VERSION}"
mkdir -p "$STAGE" || exit 1
cp -R extensions packaging README.md VERSION "$STAGE"/ || exit 1
(cd "$TOP/SOURCES" && tar -czf "${PKG}-${VERSION}.tar.gz" "${PKG}-${VERSION}") || exit 1
rm -rf "$STAGE"

rpmbuild -bb \
    --define "_topdir $TOP" \
    --define "pkgver $VERSION" \
    "$@" \
    packaging/rpm/my-xymon-extensions.spec || exit 1

echo "Created:"
find "$TOP/RPMS" -name '*.rpm'
