#!/bin/sh
# Build the .rpm package with rpmbuild.
# EL/Rocky layout: XYMONHOME=/usr/lib64/xymon/client (Terabithia builds);
# override with: sh build.sh --define 'xymonhome /path/to/client'
# (extra arguments are passed through to rpmbuild).
#
# Two environment variables cover a Xymon client that was compiled and
# installed by hand instead of from a package (they work through
# "make rpm" as well, which cannot pass arguments on):
#   RPM_XYMONHOME  the client directory - the one that holds bin/, etc/
#                  and ext/ - e.g. /usr/local/xymon/client
#   RPM_CLIENTDEP  "no": the package does not require the xymon-client
#                  rpm. A hand-built client is in no rpm database, so
#                  dnf could never satisfy that dependency.
# Example:
#   RPM_XYMONHOME=/usr/local/xymon/client RPM_CLIENTDEP=no make rpm
# Arguments given on the command line come last and therefore win over
# both variables.
set -u

cd "$(dirname "$0")/../.." || exit 1

case "${RPM_CLIENTDEP:-yes}" in
    yes|Yes|YES|1|true) ;;
    no|No|NO|0|false) set -- --without clientdep "$@" ;;
    *)
        echo "RPM_CLIENTDEP must be yes or no, not: ${RPM_CLIENTDEP}" >&2
        exit 1
        ;;
esac
if [ -n "${RPM_XYMONHOME:-}" ]; then
    # The value ends up in an rpm macro and in the installed paths.
    case "${RPM_XYMONHOME}" in
        /*) ;;
        *)
            echo "RPM_XYMONHOME must be an absolute path, not: ${RPM_XYMONHOME}" >&2
            exit 1
            ;;
    esac
    case "${RPM_XYMONHOME}" in
        *[!A-Za-z0-9/._+-]*)
            echo "RPM_XYMONHOME contains characters a package path must not have: ${RPM_XYMONHOME}" >&2
            exit 1
            ;;
    esac
    set -- --define "xymonhome ${RPM_XYMONHOME%/}" "$@"
fi

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
