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
| P1 | LXC cgroup identity | Substring matching accepted a parent whose name contained the container name, attributing its resources to the container or losing its metrics. | Match complete known LXC cgroup components (plain name, lxc.payload.NAME, lxc@NAME.service). |
| P2 | SMART/eMMC | Failed device queries and polls containing only skipped disks could still claim every monitored disk was healthy. smartctl query-error bits were ignored. | Query failures warn; a poll without usable measurements stays clear. Recognized standby remains an intentional skip, without waking the disk. |
| P2 | LXC inventory | Two failed lxc-ls calls were reported as no configured containers. | Distinguish a successful empty inventory from a failed query; report unknown/yellow with the diagnostic. Preserve the old-tool fallback. |
| P2 | Disk coverage | df could return usable rows and a failure for an inaccessible filesystem, yet the column stayed green and its diagnostic was discarded. | Retain the useful rows, warn about incomplete coverage and include stderr without confusing the Xymon disk parser. |
| P2 | opkg feed age | One fresh package feed hid other stale feeds. | Treat the feed set as stale when any existing feed exceeds the age limit. |
| P2 | Standalone path validation | An extension argument such as ../escape was used in executable and log paths. | Validate plain extension names before either opening a log or executing a file; reject helper names. |
| P2 | Standalone transport | A whitespace-only server list returned success without sending. Failed stdin spooling could send partial data. OpenBSD nc lacked socket shutdown at stdin EOF. | Reject empty recipient lists and invalid timeout settings; check spooling; detect/use nc -N where supported. |
| P2 | FRITZ!Box exposure baseline | Failed optional exposure-settings queries silently removed fields from the baseline, producing spurious change alerts and accepting an incomplete snapshot. | Mark offered-service query failures partial/yellow, preserve the last baseline and send an unknown portmap value. |
| P3 | Standalone documentation | Future-extension instructions still pointed at the old config directory and claimed the IPK included server-only collectors. | Document the current config path, package split and failure semantics. |

## Verification

- The original full fixture suite passed before changes.
- The new isolated cross-extension suite has 37 assertions; 36 fail against
  the original commit and all pass with the corrections. It covers both
  symlink-clobber paths, cwd collisions, a cgroup-parent collision, query
  failures, partial df output, mixed-age feeds, status/data transport
  failures, wrapper exit preservation and standalone path/EOF behavior.
- The existing FRITZ!Box replay suite additionally checks that one failed
  exposure-settings query warns, sends U and preserves the old baseline.
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
- [smartmontools exit bit definitions](https://github.com/smartmontools/smartmontools/blob/main/src/smartctl.h)
