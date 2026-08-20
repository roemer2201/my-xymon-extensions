# my-xymon-extensions - top-level build entry points.
# Must stay portable between GNU make (Linux) and BSD make (FreeBSD):
# no GNU-make-only functions, plain targets and shell commands only.

SHELL = /bin/sh

all: test

test: shellcheck unittest

shellcheck:
	shellcheck --shell=sh extensions/*/*.sh standalone/*.sh tests/run.sh tests/smart/fakesmartctl tests/smart/fakemmc tests/fritzdsl/fakecurl tests/fritzwan/fakecurl tests/disk/fakedf tests/opkg/fakeopkg tests/wifi/fakeiw tests/wifi/fakeubus tests/wifi/fakeiwinfo tests/lxc/fakelxc-ls tests/lxc/fakelxc-info tests/lxc/fakelxc-autostart packaging/*/*.sh packaging/deb/postinst packaging/deb-server/postinst packaging/opkg/postinst

unittest:
	sh tests/run.sh

# Packaging targets only work on the matching platform (see CLAUDE.md
# and packaging/README.md). Output lands in build/.
deb:
	sh packaging/deb/build.sh

# The server-side counterpart: drop-in configuration for the Xymon
# server (currently .deb only).
deb-server:
	sh packaging/deb-server/build.sh

rpm:
	sh packaging/rpm/build.sh

freebsd:
	sh packaging/freebsd/build.sh

# The OpenWrt/TurrisOS .ipk is plain tar+gzip and builds anywhere.
opkg:
	sh packaging/opkg/build.sh

clean:
	rm -rf build

.PHONY: all test shellcheck unittest deb deb-server rpm freebsd opkg clean
