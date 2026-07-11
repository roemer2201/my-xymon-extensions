# my-xymon-extensions - top-level build entry points.
# Must stay portable between GNU make (Linux) and BSD make (FreeBSD):
# no GNU-make-only functions, plain targets and shell commands only.

SHELL = /bin/sh

all: test

test: shellcheck unittest

shellcheck:
	shellcheck --shell=sh extensions/*/*.sh standalone/*.sh tests/run.sh tests/smart/fakesmartctl tests/smart/fakemmc tests/fritzdsl/fakecurl packaging/*/*.sh

unittest:
	sh tests/run.sh

# Packaging targets only work on the matching platform (see CLAUDE.md
# and packaging/README.md). Output lands in build/.
deb:
	sh packaging/deb/build.sh

rpm:
	sh packaging/rpm/build.sh

freebsd:
	sh packaging/freebsd/build.sh

# The OpenWrt/TurrisOS .ipk is plain tar+gzip and builds anywhere.
opkg:
	sh packaging/opkg/build.sh

clean:
	rm -rf build

.PHONY: all test shellcheck unittest deb rpm freebsd opkg clean
