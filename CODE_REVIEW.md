# Full code review - 2026-10-18

Base: `58b4bb7` (main, after PR #56). Fix branch: `codex/full-code-review`.

## Scope

Read all production shell and awk code: the client extensions, server-only
powerline/fritz-wifi/fritzbox collectors, measurement wrapper and shim,
standalone runtime, package staging/build/maintainer scripts, Makefile and
CI workflow. Reviewed the accompanying configurations and test fixtures,
including Xymon status/data conventions and the graph configuration.
Changes focus on demonstrated correctness/security failures; existing
configuration precedence and platform interfaces are preserved.

## Findings and corrections

| Priority | Area | Failure before the correction | Correction |
| --- | --- | --- | --- |
| P1 | Persistent state | wifi, if_link, lxc, systemd, smart and btrfs wrote predictable `state.$$` temporary paths. A pre-created symlink could cause another file to be truncated, including during privileged standalone runs. xymonext wrote its final state directly. | Exclusively reserve random temporary files with mode 0600 and replace the final path atomically. Hidden temporary measurement files stay out of the report glob. |
| P1 | Xymon delivery | Twelve client extensions discarded failed status/data delivery through a later conditional or unconditional `exit 0`. The wrapper/runner could call a lost report successful. | Return failure from send_report and propagate it through normal and early/clear exits. The measurement wrapper still intentionally preserves its child's exit status. |
| P1 | if_link and LXC glob lists | Unquoted pattern lists expanded against cwd filenames before matching. Unrelated files could suppress monitored interfaces/containers or disable per-interface thresholds. | Disable pathname expansion while splitting pattern/word lists; retain case-based glob matching. |
| P1 | LXC cgroup identity | Substring matching accepted a parent whose name contained the container name, attributing its resources to the container or losing its metrics. | Match complete known LXC cgroup components (plain name, lxc.payload.NAME with LXC's optional -N retry suffix, lxc@NAME.service). |
| P2 | SMART/eMMC | Failed device queries and polls containing only skipped disks could still claim every monitored disk was healthy. | A device smartctl cannot open or identify warns; a poll without usable measurements stays clear. Recognized standby remains an intentional skip. The exit status is not evaluated (see follow-up). Unprivileged eMMC-only mode keeps its documented clear. |
| P2 | LXC inventory | Two failed lxc-ls calls were reported as no configured containers. | Distinguish a successful empty inventory from a failed query; report unknown/yellow with the diagnostic. Preserve the old-tool fallback. |
| P2 | Disk coverage | df could return usable rows and a failure for an inaccessible filesystem, yet the column stayed green and its diagnostic was discarded. | Retain the useful rows, warn about incomplete coverage and include stderr without confusing the Xymon disk parser. |
| P2 | opkg feed age | One fresh package feed hid other stale feeds. | Treat the feed set as stale when any existing feed exceeds the age limit. |
| P2 | Standalone path validation | An extension argument such as ../escape was used in executable and log paths. | Validate plain extension names before either opening a log or executing a file; reject helper names. |
| P2 | Standalone transport | A whitespace-only server list returned success without sending. Failed stdin spooling could send partial data. OpenBSD nc lacked socket shutdown at stdin EOF. | Reject empty recipient lists and invalid timeout settings; check spooling; detect/use nc -N where supported. |
| P2 | FRITZ!Box exposure baseline | Failed optional exposure-settings queries silently removed fields from the baseline, producing spurious change alerts and accepting an incomplete snapshot. | Mark offered-service query failures partial/yellow and preserve the last baseline. The port mapping count stays valid when the mapping list itself was complete. |
| P3 | Standalone documentation | Future-extension instructions still pointed at the old config directory and claimed the IPK included server-only collectors. | Document the current config path, package split and failure semantics. |

## Follow-up verification of the corrections

Each finding was re-checked against `58b4bb7` and the sources of the
tools involved. All findings reproduce as described. Five corrections
were adjusted:

- **SMART exit status.** The first correction warned whenever smartctl
  exit bits 0-2 were set. smartctl ORs bit 2 (`FAILSMART`) into the
  status for failed *optional* commands too, e.g. "Read SMART
  Thresholds failed" (`ataprint.cpp`), while health and attributes are
  printed in full - a permanent false yellow. Bits 0/1 (open/identify
  failed) already leave no "=== START OF" section, which the existing
  check now reports as yellow. The bit test was removed; a fixture with
  complete output and exit 4 pins this.
- **eMMC without root.** smart.sh documents that eMMC-only auto mode
  runs mmc unprivileged and shows failures as clear. The correction
  had turned this into a permanent yellow; it is clear again in exactly
  that mode and yellow otherwise.
- **LXC retry names.** LXC appends `-1`, `-2`, ... to `lxc.payload.NAME`
  while a cgroup of that name still exists (`cgfsng.c`,
  `CGROUP_CREATE_RETRY`). The exact match missed it and the directory
  fallback then picked the stale `lxc.payload.NAME`. The suffix is
  accepted now (pinned by a regression).
- **fritzfw summary.** A failed settings query reported "port mapping
  list incomplete" and an unknown mapping count although the list was
  read completely. The summary now names the incomplete settings, and
  the count is kept; the baseline is still preserved.

- **SMART summary.** An unreadable device turned the column yellow,
  but the summary line still read "All monitored disks are healthy",
  because the failure was written to the details only. It is now a
  summary note as well.

Smaller follow-ups: the standalone runner names `claude-expiry` as the
claude helper instead of "the measurement wrapper"; the disk and smart
READMEs document the new colors; the RPM changelog names the maintainer.

## Verification

- The original full fixture suite passed before changes.
- The new isolated cross-extension suite had 37 assertions (38 with the
  LXC retry-name case added in the follow-up); 36 fail against
  the original commit and all pass with the corrections. It covers both
  symlink-clobber paths, cwd collisions, a cgroup-parent collision, query
  failures, partial df output, mixed-age feeds, status/data transport
  failures, wrapper exit preservation and standalone path/EOF behavior.
- The existing FRITZ!Box replay suite additionally checks that one failed
  exposure-settings query warns, keeps the complete mapping count and
  preserves the old baseline.
- Full `make test` passes (ShellCheck 0.9.0 and all fixture suites).
- Full suite passes with BusyBox 1.36.1 shell and userland.
- `make graphcheck` passes with RRDtool 1.7.2 (powerline graphs, including U).
- Client/server Debian packages and the OpenWrt IPK build successfully.
- `git diff --check` passes.

## Limits and maintainer decisions

Tests use fixtures; no production Xymon daemon, router, disks or PLC
hardware was contacted. A native Rocky RPM build and a native FreeBSD
runtime/package build were not performed locally; the existing CI covers
RPM, while the repository currently disables its FreeBSD VM job.
No packaging layout was changed.

The repository's license and RPM License field are still explicitly TBD.
Choosing the project's license is a maintainer decision, so this review
has not invented one. Existing client settings retain their documented
config-over-environment precedence rather than being migrated wholesale.
State directories must remain controlled by the account running the
collector; private temporary files do not make an attacker-controlled
parent directory trustworthy.

## References used to check protocol/tool behavior

- [Xymon protocol and client](https://xymon.sourceforge.io/xymon/help/manpages/man1/xymon.1.html)
- [OpenBSD nc manual: -N shuts down the socket after stdin EOF](https://man.openbsd.org/nc.1)
- [smartmontools exit bit definitions](https://github.com/smartmontools/smartmontools/blob/master/smartmontools/smartctl.h)
- [smartmontools ataprint.cpp: FAILSMART for optional commands](https://github.com/smartmontools/smartmontools/blob/master/smartmontools/ataprint.cpp)
- [LXC cgfsng.c: cgroup retry suffix](https://github.com/lxc/lxc/blob/main/src/lxc/cgroups/cgfsng.c)
