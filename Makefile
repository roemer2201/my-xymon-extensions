# my-xymon-extensions - top-level build entry points.
# Must stay portable between GNU make (Linux) and BSD make (FreeBSD):
# no GNU-make-only functions, plain targets and shell commands only.

SHELL = /bin/sh

all: test

test: shellcheck unittest

shellcheck:
	shellcheck --shell=sh extensions/*/*.sh tests/run.sh tests/smart/fakesmartctl packaging/*/*.sh

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

clean:
	rm -rf build

.PHONY: all test shellcheck unittest deb rpm freebsd clean
