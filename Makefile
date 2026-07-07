# my-xymon-extensions - top-level build entry points.
# Must stay portable between GNU make (Linux) and BSD make (FreeBSD):
# no GNU-make-only functions, plain targets and shell commands only.

SHELL = /bin/sh

all: test

test: shellcheck unittest

shellcheck:
	shellcheck --shell=sh extensions/*/*.sh tests/run.sh tests/smart/fakesmartctl tests/diskio/fakegstat tests/diskio/fakezpool

unittest:
	sh tests/run.sh

# Packaging targets only work on the matching platform (see CLAUDE.md).
deb rpm freebsd:
	@echo "Packaging target '$@' is not implemented yet."
	@exit 1

.PHONY: all test shellcheck unittest deb rpm freebsd
