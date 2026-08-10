# CLAUDE.md

Guidance for Claude Code (and other contributors) when working in this
repository.

## What this repository is

A collection of extensions (custom monitoring tests) for the **Xymon**
systems monitor. Every extension must run unmodified on:

- **Ubuntu** (current LTS releases)
- **Rocky Linux** (and other Enterprise-Linux derivatives)
- **FreeBSD** (currently supported releases)
- **OpenWrt/TurrisOS** (BusyBox userland; no Xymon client exists there —
  extensions run through the `standalone/` runner instead)

From this repository, native **deb**, **rpm**, **FreeBSD pkg** and
**opkg (.ipk)** packages are built.

## Hard portability rules

These rules are non-negotiable. Violating any of them breaks at least one
target platform.

### Shell

- Shebang is always `#!/bin/sh`. Scripts must be pure **POSIX sh** —
  they run under `dash` (Ubuntu default), `bash --posix` and FreeBSD
  `/bin/sh`.
- Forbidden bashisms include (not exhaustive): `[[ ]]`, arrays,
  `function name()`, `local -x`, `${var/pattern/repl}`, `$'...'`,
  `source` (use `.`), `echo -e`/`echo -n` (use `printf`), process
  substitution `<(...)`, `&>` redirection.
- Use `command -v`, never `which`.
- `shellcheck --shell=sh` must pass with zero warnings.
- Scripts must also run under **BusyBox ash with BusyBox userland**
  (OpenWrt/TurrisOS): stick to POSIX options of `awk`, `sed`, `grep`,
  `tr`, `sort` etc. — BusyBox implements little beyond POSIX. CI runs
  the test suite under BusyBox to enforce this.

### Userland tool differences (GNU vs. BSD)

- `sed -i` is **not portable** (BSD sed needs `sed -i ''`). Write to a
  temp file and `mv` instead.
- `date -d` (GNU) does not exist on FreeBSD (`date -v`/`date -r` there).
  Prefer arithmetic on epoch seconds; get epoch via `date +%s` (portable).
- No `grep -P`; stick to BRE/ERE (`grep -E`). No GNU-only `awk` features
  (use POSIX awk; the system awk on FreeBSD is BWK awk, on Ubuntu mawk).
- No `readlink -f` (not on older FreeBSD); avoid or provide a fallback.
- `ps`, `df`, `stat`, `top` have different flags/output per platform —
  always guard platform-specific invocations with a `uname` switch:

  ```sh
  case "$(uname -s)" in
      Linux)   ... ;;
      FreeBSD) ... ;;
      *)       ... ;;
  esac
  ```

- Temp files: use `mktemp` (portable enough) inside `$XYMONTMP`, and
  always clean up via `trap ... EXIT INT TERM`.

### Xymon integration

- Never hardcode Xymon paths. Use the environment that `xymonlaunch`
  provides: `$XYMON` (the xymon binary), `$XYMSRV`/`$XYMSERVERS`
  (server address), `$XYMONHOME`, `$XYMONTMP`, `$XYMONCLIENTLOGS`,
  `$MACHINE`/`$MACHINEDOTS` (client hostname).
- Known install locations (for packaging only, never in scripts):
  - Debian/Ubuntu: `/usr/lib/xymon/client`
  - EL/Rocky (EPEL xymon-client): `/usr/share/xymon-client` (check the
    actual package used; Terabithia builds use `/usr/lib64/xymon/client`)
  - FreeBSD (ports `net-mgmt/xymon-client`): `/usr/local/www/xymon/client`
- Status reports go through `$XYMON $XYMSRV "status ..."` — never call a
  hardcoded binary path or open sockets yourself.
- Do not assume a full Xymon client installation: on OpenWrt/TurrisOS
  the environment and `$XYMON` are provided by `standalone/xymon-run.sh`
  and `standalone/xymon-send.sh`. Anything an extension needs beyond
  the documented environment variables breaks the standalone mode.
- One extension reports exactly **one column**. Column names are
  lowercase, max ~8 chars, no dots.
- Colors: `green` (ok), `yellow` (warning), `red` (critical), `clear`
  (test not applicable / missing prerequisites). Use `clear`, not `red`,
  when a platform lacks the required tool or interface.

## Repository conventions

- New extension → new directory `extensions/<name>/` containing:
  - `<name>.sh` — the script (executable, POSIX sh)
  - `<name>.cfg` — default config, only if the extension is configurable;
    read from `$XYMONHOME/etc/<name>.cfg` with sane built-in defaults so
    the extension works without a config file
  - `README.md` — purpose, column name, thresholds, platform notes
  - `server/` — everything the **Xymon server** needs, if the extension
    produces RRD graphs. Never tell users to edit a stock config file:
    ship ready-made drop-in files, one per Xymon config file, all named
    `<name>.cfg`:
    - `server/xymonserver.d/<name>.cfg` — `TEST2RRD`, `NCV_*`/
      `SPLITNCV_*`, `GRAPHS`/`GRAPHS_<column>` (append with `NAME+=`,
      leading comma, and note that this requires the file to be read
      after the stock settings)
    - `server/graphs.d/<name>.cfg` — the `[graphname]` definitions
    - `server/rrddefinitions.d/<name>.cfg` — RRA archives, rarely needed
    - `server/README.md` — how to install them, verify, and alert

    This works because Xymon reads *every* config file through the same
    reader (`stackfgets()`, `lib/stackio.c`), which understands
    `include`, `directory` and the `optional` prefix — the manual
    documents it only for `hosts.cfg`/`alerts.cfg`. Confirmed in the
    sources for `graphs.cfg` (`load_gdefs()`), `rrddefinitions.cfg`
    (`load_rrddefs()`) and `xymonserver.cfg` (`loadenv()`).
- Add a `tasks.d` snippet for the extension under
  `packaging/common/tasks.d/<name>.cfg` so all three packages ship it.
- The installed file list lives in exactly one place,
  `packaging/common/stage.sh` — extend it whenever an extension is
  added, renamed or gains new installed files, and check that all four
  packagings (`packaging/deb`, `packaging/rpm`, `packaging/freebsd`,
  `packaging/opkg`) still cover the change (conffiles lists, plist,
  etc.). A change is not complete until all package definitions are
  consistent.
- Version is maintained in one place (`VERSION` file at the repo root)
  and consumed by all package builds.

## Build & test commands

```sh
make test       # shellcheck + unit tests — run this before every commit
make deb        # build .deb  (requires Debian/Ubuntu tooling)
make rpm        # build .rpm  (requires rpmbuild)
make freebsd    # build .pkg  (requires FreeBSD pkg(8))
make opkg       # build .ipk  (plain tar+gzip, builds anywhere)
```

`make deb|rpm|freebsd` only work on the matching platform; CI builds
all packages. Never mark packaging work as verified unless the
corresponding build actually ran.

## Style

- Indentation: 4 spaces, no tabs (except in Makefiles).
- `set -u` at the top of every script; check exit codes explicitly
  (`set -e` is too surprising in sh — do not rely on it).
- Quote all variable expansions: `"$var"`.
- Keep scripts self-contained; shared code lives in
  `extensions/lib/common.sh` and is sourced with
  `. "$XYMONHOME/ext/lib/common.sh"` only when genuinely reused.
- Comments and documentation in English.
