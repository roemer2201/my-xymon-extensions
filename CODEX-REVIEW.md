# Repository-wide code review

Review performed: 2026-09-08; report finalized: 2026-09-09.

Repository: `roemer2201/my-xymon-extensions`

Reviewed baseline: `07ad86a2ae8ca84ef9f92827c9ffa20b7d64f282` (`main`, version `0.18.0`)

Review branch: `codex/full-code-review-2026-09-08`

This is a review of the existing repository, not just the latest commit.
Only this report is changed on the review branch; no fixes, configuration
changes, package installations, or production-device operations are included.
The report is in English to follow the repository's `CLAUDE.md` convention.
File/line references below refer to the baseline above.

## Summary

**19 actionable findings: 3 P1, 16 P2.** The principal risks are unsafe
privileged file writes, an overbroad sudo permission, false healthy statuses,
incorrect time-series data, and incomplete Debian upgrade handling.

P1 means a security-boundary problem or a serious monitoring failure to fix
with high priority under the stated conditions. P2 means a functional,
operational, or test-coverage defect to fix in the normal release cycle.
These are review priorities, not CVSS scores. There is no claim that every
installation is affected by every finding.

| ID | Priority | Finding |
| --- | --- | --- |
| R01 | P1 | Predictable state paths permit symlink-based writes with the runner's privileges |
| R02 | P1 | The advertised read-only sudo rule permits arbitrary smartctl arguments |
| R03 | P1 | An unreadable configured disk is reported as healthy |
| R04 | P2 | Interface/container glob filters expand against the working directory |
| R05 | P2 | Required containers missing from the inventory are not reported |
| R06 | P2 | Substring cgroup matching can attribute the parent's resources to a container |
| R07 | P2 | Distinct container names collapse into the same metric name |
| R08 | P2 | Invalid hwmon readings suppress valid thermal fallback and remain green |
| R09 | P2 | Partial df failures are silently treated as successful disk checks |
| R10 | P2 | A single fresh opkg feed hides stale feeds |
| R11 | P2 | Missing DSL CRC data resets the baseline and invents subsequent errors |
| R12 | P2 | A 32-bit WAN counter reset is always interpreted as a wrap |
| R13 | P2 | Backslashes in FRITZ!Box credentials are changed by curl's config parser |
| R14 | P2 | Extensions discard delivery failures and return success |
| R15 | P2 | The advertised hang detector only evaluates completed runs |
| R16 | P2 | The server Debian package omits two required migration scripts |
| R17 | P2 | The server package collision test reads a file before generating it |
| R18 | P2 | Human-readable status text is still fed to NCV in four extensions |
| R19 | P2 | if_link totals assume five-minute polls, but standalone defaults to ten |

## Scope and verification

The baseline has 414 tracked files. Review covered all production shell
scripts, their configuration interfaces, server-side metric/graph mappings,
packaging, the test runner and relevant fixtures, and operational guidance.

| Area | Coverage |
| --- | --- |
| Local health checks | `disk`, `if_link`, `la`, `lxc`, `memory`, `opkg`, `smart`, `temp`, `wifi` |
| Remote pollers | `fritzdsl`, `fritzwan`; credentials, SOAP parsing, counters and thresholds |
| Instrumentation/transport | `xymonext.sh`, `xymonext-send.sh`, standalone runner and sender |
| Server configuration | All extension graph/NCV snippets and the if_link RRD definitions |
| Packaging | Common staging, Debian client/server, RPM, FreeBSD and OpenWrt scripts/manifests |
| Tests/operations | `tests/run.sh`, fakes/fixtures, Makefile, CI workflow, launch/cron configuration, sudoers and relevant README guidance |

Executed checks:

| Check | Result |
| --- | --- |
| `make unittest` | Exit 0, `All tests passed.`; repeated successfully, but see R17 |
| POSIX shell syntax checks with `sh -n` | Passed for tracked shell scripts, maintainer scripts and fake commands |
| `make test` | **Not completed:** ShellCheck is absent; Make stops at `shellcheck: not found` |
| `make deb deb-server opkg` | All three package builds succeeded |
| Server `.deb` control archive inspection | Confirmed missing `preinst`/`postrm`, R16 |
| 15 additional isolated behavioral probes | All 15 reproduced the targeted defects; two exercise the shared R04 bug |
| `cvtsudoers -f json extensions/smart/sudoers.example` | Parsed successfully; confirmed the unrestricted command specification in R02 |

The additional probes used fake tools, temporary sysfs/proc/cgroup trees,
synthetic state, an intentionally failing sender, and a sacrificial symlink
target. Credential parsing was checked with the real curl parser using a
dummy password and a refused loopback connection, not a FRITZ!Box.
Probe inputs and observed results are described with each finding.

Execution was on Linux with `/bin/sh`. Native FreeBSD, Rocky Linux, BusyBox,
real LXC, real storage/routers, and a live Xymon/RRDtool server were not
available for end-to-end validation. RPM and FreeBSD builds were inspected
but not executed. The existing suite also skipped `/usr/bin/time`, which is
absent here. The FreeBSD CI job is commented out; CI configuration is not
evidence of a successful native-platform run. Graph/parser findings below
identify explicitly where the evidence is configuration or protocol analysis.

## Findings

### R01 — P1: Put privileged state and logs in an owned private directory

Locations: `extensions/xymonext/xymonext.sh:131,335-340`;
`standalone/xymon-run.sh:56-57,81-86,142`;
`standalone/standalone.cfg:48-54`; `standalone/crontab.example:3,11`.

The documented standalone setup runs from root's crontab with `XYMONTMP=/tmp`.
The wrapper accepts an existing `/tmp/xymonext.d` without checking its owner
or permissions and truncates `<state-directory>/<extension>` through a normal
shell redirection. A local user able to pre-create that directory can populate
it with symlinks. A subsequent privileged monitoring run writes through them.
This is not an arbitrary-content write, but it can truncate/replace a file
writable by the runner. Kernel protection for symlinks directly inside sticky
`/tmp` is insufficient if the link resides inside an attacker-owned,
non-sticky subdirectory. Predictable standalone log redirections have a related
risk where the platform's shared-directory protections permit following them.

Verification: a temporary `xymonext.d/fake` symlink pointed to a sacrificial
file containing `ORIGINAL`. Running a harmless fake extension replaced the
target with the six-field state record. This verifies the write primitive;
no cross-user exploitation or privileged target modification was performed.

Fix: provision an owner-controlled, restrictive runtime/log directory;
reject untrusted existing paths before use. Write state atomically via
unpredictable temporary files inside that validated directory. Add regression
tests for a pre-existing foreign directory, symlinked state and symlinked logs.

### R02 — P1: The sudoers example does not enforce read-only disk access

Location: `extensions/smart/sudoers.example:9-16`.

The rule grants `xymon` passwordless root execution of `/usr/sbin/smartctl`
without an argument restriction. Despite the comment promising read-only
queries, this authorizes smartctl's state-changing options too, including
disabling SMART and changing supported drive settings. Compromise of the
monitoring account therefore gives more privileged device control than the
documented permission boundary. The commented FreeBSD alternative has the
same issue when activated.

Verification: the actual sudoers parser (`cvtsudoers -f json`) returns a
root command grant with `authenticate: false` and no argument restriction.
No privileged command or device-setting operation was executed. This is a
policy-analysis finding, not a claim of arbitrary root command execution.

Fix: expose a root-owned read-only helper with a strict device/option
allowlist, or equivalent exact sudoers command restrictions. Do not forward
unvalidated arbitrary smartctl options through a supposedly read-only rule.
Test both permitted queries and rejected state-changing invocations.

### R03 — P1: An unreadable configured disk must not produce an all-healthy report

Locations: `extensions/smart/smart.sh:461-495,608-610,774-792,879-893`.

`OVERALL` starts green. When smartctl cannot open a configured device, the
script appends a per-device clear note and continues without changing the
aggregate status. It still increments the checked-device count. With no
threshold notes, the summary says `All monitored disks are healthy`, even if
no disk supplied health data. Unreadable eMMC data has the same aggregation
problem. A removed disk or lost device-access permission can thus silently
turn an important check into a reassuring green status.

Reproduction: configure the existing `tests/smart/fakesmartctl`, `USE_SUDO=no`,
`MMC_DEVICES=none`, and `device /dev/nonexistent`. Observed: a green SMART
status, `All monitored disks are healthy`, an open-device error and
`Checked 1 device(s)` in the same report.

Fix: distinguish successful health checks, intentional skips and failed
checks. An unavailable explicitly monitored disk needs a visible non-healthy
aggregate result; a completely inapplicable check can remain clear. Never
claim successful validation when all reads failed. Test mixed and all-failed
sets separately from the intentionally supported standby case.

### R04 — P2: Preserve configured globs until matching the monitored name

Locations: `extensions/if_link/if_link.sh:126-135`;
`extensions/lxc/lxc.sh:137-146`.

Both `match_any` functions iterate with `for ma_p in $2`. That performs
pathname expansion as well as the desired word splitting. A configured `*`
or `lan*` can become filenames in the current working directory before the
`case` expression sees it. Selection and exclusion policies consequently
depend on unrelated filesystem contents. In LXC this can suppress required
container alarms, not just graphs.

Reproduction, from the repository root: with the shipped fake sysfs tree,
`IF_LINK_INTERFACES='*'` reports clear and says no interface matches. With the
normal LXC fixture and `LXC_REQUIRED='*'`, the stopped `thunderbird-test`
remains optional and the column is green.

Fix: disable pathname expansion in a carefully scoped parsing operation,
preserving the caller's shell state, or tokenize without shell glob expansion.
Keep glob interpretation only in `case`. Test from working directories both
with and without files matching the configured patterns.

### R05 — P2: Compare the required container set against the inventory

Locations: `extensions/lxc/lxc.sh:252-270,521-550`;
`extensions/lxc/lxc.cfg:25-27`.

Required/autostart membership is evaluated only for containers returned by
`lxc-ls`. A named required container absent from that inventory is never
visited, counted down or mentioned. An empty inventory exits clear before
the expectation checks. This misses a deleted/unmounted container definition
even though the configuration says that exactly the required containers must
run. Explicit names in the UCI autostart list have the same absence problem.

Reproduction: use the normal LXC fixtures with `LXC_REQUIRED=db01`, where
`db01` does not exist. Observed: green, `4 of 5 container(s) running`, and no
mention of `db01`. This does not depend on the glob-expansion issue in R04.

Fix: detect missing literal required/autostart names after inventory, define
how unmatched required globs should be reported, and distinguish failed
inventory acquisition from a genuinely empty host. Test absence, stopped
state and command failure as separate cases.

### R06 — P2: Match cgroup components structurally, not by substring

Location: `extensions/lxc/lxc.sh:301-322`.

`cgroup_root_of` selects the first path component containing the container
name anywhere. For the valid name `a`, `/machine.slice/lxc.payload.a/init.scope`
matches `machine.slice`, so resource reads use the parent slice. CPU and RAM
can include unrelated workloads, and the process-RSS fallback can assign
other containers' processes to this container.

Reproduction: a fake init PID had that cgroup path; `machine.slice` contained
10 MiB and `lxc.payload.a` contained 1 MiB. With `LXC_RAM=cgroup` and a 5 MiB
red threshold, the extension emitted `a_ram : 10.0` and a red status instead
of reporting the container's 1 MiB.

Fix: recognize exact supported layouts such as `lxc.payload.<name>`,
`lxc/<name>` and the appropriate systemd unit form, with component boundaries.
Test short names, ancestor substrings and sibling containers.

### R07 — P2: Detect or prevent metric-name collisions

Locations: `extensions/lxc/lxc.sh:124-132,523,672-675`.

Sanitization lowercases names, replaces non-alphanumeric characters with
underscores and collapses underscores. Different valid container names
therefore lose their identity before SPLITNCV. The human-readable status
remains distinct, making the corrupted metric mapping difficult to notice.

Reproduction: define running containers `web-1` and `web_1`, with 1 MiB and
2 MiB cgroup memory respectively. One data message contains both
`web_1_ram : 1.0` and `web_1_ram : 2.0`. They cannot form independent histories
under the configured per-name RRD mapping. The exact treatment of duplicate
updates was not tested on a live server.

Fix: use a deterministic collision-resistant encoding, or detect collisions
and refuse ambiguous metrics with a visible diagnostic. Keep identifiers
stable across polls and inventory order. Audit the similar sanitizers in
interface, Wi-Fi and SMART naming rather than assuming they are injective.

### R08 — P2: Count valid temperature readings separately from discovered sensors

Locations: `extensions/temp/temp.sh:146-147,167-179,205-218`.

`NSENSORS` increments before the plausibility check. An implausible hwmon
reading therefore suppresses the thermal-zone fallback, which runs only when
that count is zero. Combining an initially green aggregate with clear does
not remove the green status. A host with no usable hwmon temperature can
report green while a readable thermal-zone sensor would trigger an alarm.

Reproduction: provide one hwmon reading of 491000 millidegrees and a thermal
zone of 120000. Observed: green, one ignored 491.0 C sensor, no temperature
metrics and no 120.0 C reading. Default critical temperature is 90 C.

Fix: track valid measurements separately, try fallback when none are usable,
and report clear/unknown when no valid reading remains. Preserve the existing
behavior for an invalid sensor alongside a genuinely healthy one.

### R09 — P2: Surface partial df failures

Locations: `extensions/disk/disk.sh:130-133,209-211`.

The script captures `DFRC` but only uses it when no filesystem line parsed.
If df reports some filesystems and fails to read another, its stderr is
discarded and the remaining rows can produce green. The filesystem with the
I/O/availability problem disappears from the check without a warning.

Reproduction: set `DISK_DF` to `tests/disk/fakedf`, `FAKEDF_RC=1` and
`FAKEDF_OUTPUT` to `tests/disk/data/df-turris.txt`. Observed: green with the
usable filesystem rows, no indication that df failed.

Fix: preserve diagnostic stderr, retain valid rows, and mark the aggregate
as incomplete/non-healthy on a nonzero df exit. Format diagnostics so they
remain invisible to the server's unusually permissive disk RRD parser.

### R10 — P2: Evaluate the age of every relevant opkg feed

Location: `extensions/opkg/opkg.sh:138-160`.

`lists_state` returns fresh if it finds any file newer than the reference.
A partially successful feed update can leave one list fresh and another
stale. Later polls neither refresh nor warn about the stale list, potentially
missing available updates while claiming that packages are current.

Reproduction: make a lists directory containing one current file and one
file three days old; use the existing fake opkg with no reported upgrades.
With default `OPKG_MAXAGE=24` and `OPKG_UPDATE=auto`, only `list-upgradable`
was called. The report was green and claimed the lists had been updated
within 24 hours.

Fix: check all configured/relevant feeds, including missing lists, or persist
the outcome of a complete feed refresh. Test a partially failed refresh and
the next poll, not only all-fresh or all-stale directories.

### R11 — P2: Do not store a fabricated zero CRC baseline

Locations: `extensions/fritzdsl/fritzdsl.sh:335-349,364-369`.

An unavailable or malformed statistics response leaves CRC unset, but the
persisted state substitutes zero and advances the timestamp. The next valid
cumulative counter is then interpreted as entirely new errors. A brief data
gap can create a false critical CRC-rate alarm even when no errors occurred.

Reproduction: poll a synthetic total of 10000 CRC errors, poll once with an
empty statistics response, then return the same total 300 seconds after that
gap's timestamp. The state changed from 10000 to 0; the next report was red
with `CRC errors: 2000.0/min`, against the default 300/min critical threshold.

Fix: preserve the timestamp/counter pair of the last valid measurement, or
invalidate the baseline and prime it on recovery. Never represent missing
data as a real counter value. Keep uptime validity independent of CRC validity.

### R12 — P2: Distinguish 32-bit counter resets from wraps

Locations: `extensions/fritzwan/fritzwan.sh:125-136,337-352`.

Every negative 32-bit delta gets 2^32 added. For valid 32-bit current and
previous counters, that always produces a nonnegative result; the subsequent
negative-value check cannot detect a reboot reset despite its comment.
Device restarts can thus inject nearly 4 GiB of nonexistent traffic and
trigger utilization alarms. This is separate from the documented limitation
that multiple wraps cannot be inferred from two samples.

Reproduction: previous RX/TX counters 1000000, current counters 5000, width
32, elapsed time 300 seconds. Observed: 114505928 bit/s in both directions;
with the fixture's 100/40 Mbit/s capacities and a 90% critical threshold,
the status was red at 114.5% downstream and 286.3% upstream utilization.

Fix: include an uptime/restart indicator when available, and reject deltas
that cannot plausibly fit the link capacity and elapsed interval. If a
reset cannot be distinguished safely, report an unknown rate and re-prime
instead of asserting a valid measurement.

### R13 — P2: Escape credentials for curl's configuration-file syntax

Locations: `extensions/fritzdsl/fritzdsl.sh:191-196`;
`extensions/fritzwan/fritzwan.sh:210-217`.

The scripts interpolate credentials into a double-quoted curl config value
without escaping backslashes. Shell quoting does not protect against this
second parser. The current warning only excludes double quotes; an otherwise
supported password containing a backslash is silently changed.

Verification: giving real curl the generated config text
`user = "monitor:abc\def"` and inspecting its `--libcurl` output produced
`CURLOPT_USERPWD, "monitor:abcdef"`. Thus valid credentials can cause repeated
authentication failures. Curl documents backslash escape handling for
double-quoted config values in its [official manual](https://curl.se/docs/manpage.html#-K).

Fix: correctly encode backslashes and quotes for curl config syntax and
define/reject unsupported control characters. Test ordinary punctuation,
literal backslashes and escape-like sequences without exposing real secrets.

### R14 — P2: Propagate transport failures to the runner

Representative locations: `extensions/memory/memory.sh:81-91,153-154`;
`extensions/smart/smart.sh:892-893`; equivalent endings in the other check
scripts. Related instrumentation: `extensions/xymonext/xymonext-send.sh:47-66`.

The extension sends its report and then explicitly exits zero, discarding
the sender's failure. Checks with status and data messages can also overwrite
an earlier send error with a later success. The wrapper and standalone runner
therefore see a successful check when no report was delivered. The counting
shim records attempted bytes/messages before delivery and can label them sent.

Reproduction: run `memory.sh` against `tests/memory/meminfo` with
`XYMON=/bin/false` and a nonempty `XYMSRV`. Observed: exit 0 despite the
deterministically failing transport.

Fix: aggregate and return delivery failures without turning a successfully
delivered red health status into a process failure. Preserve failures from
either status or data, and distinguish attempted from successful sends in
instrumentation. Test all-failed and mixed-success sends.

### R15 — P2: The wall-clock thresholds do not detect a still-running hang

Locations: `extensions/xymonext/xymonext.sh:277-340,381-392`;
`extensions/xymonext/README.md:89-95`.

The wrapper waits synchronously for the child before recording state or
evaluating wall-time thresholds. While a child remains stuck, other wrappers
continue to publish its previous green result. After `XYMONEXT_MAXAGE`, that
entry is silently omitted. With the sequential standalone runner, a stuck
check also prevents later checks in that invocation from running. This does
not satisfy the documented early hang-detection behavior; it detects a slow
run only after that run ends.

Reproduction: seed a previous green result, launch a fake sleeping extension
with a 1-second critical threshold, and invoke another harmless extension
after 1.3 seconds. The first child was still running, but the aggregate report
and its old row were green. The probe terminated its temporary process group.

Fix: record in-progress state before launching the child and evaluate its
age independently, or implement a bounded watchdog/timeout with appropriate
child-process cleanup and an independent reporting path. Test a child that
never returns, not just one that sleeps and eventually exits.

### R16 — P2: Include all Debian server maintainer scripts in the built package

Location: `packaging/deb-server/build.sh:31-34`;
related files: `packaging/deb-server/preinst`, `postinst`, `postrm`.

The build copies only `postinst` into `DEBIAN`. The repository contains
`preinst` and `postrm` with the matching `dpkg-maintscript-helper` migration
calls, but dpkg never receives them. The missing preparation phase means
obsolete temp conffiles are not staged for removal; unmodified renamed
conffiles can be treated as locally modified during post-installation and
replace newly shipped defaults. Abort/cleanup phases are missing as well.
This affects upgrades from the older names/versions handled by those scripts,
not necessarily a clean installation.

Verification: `make deb-server` succeeded. Inspecting the resulting archive
with `dpkg-deb --ctrl-tarfile ... | tar -tf -` listed only `conffiles`,
`control`, and `postinst`. Migration consequences were checked against the
installed helper's `prepare_*`/`finish_*` code, without installing a package
into the host OS. A full historical-package upgrade was not executed.

Fix: copy and chmod all three maintainer scripts, as the client build does.
Assert their presence in the binary package, then test upgrades with both
modified and untouched historical conffiles, plus abort/purge paths.

### R17 — P2: Generate the server path list before the collision assertion

Locations: `tests/run.sh:2433-2446,2475`.

The test concatenates `client-paths` and `server-paths` before creating the
latter. Because the suite uses `set -u`, not fail-fast handling for this
command, cat's error does not set `FAIL`. The resulting list contains only
client paths, and the test announces that the server's conflicting temp
paths are absent without checking them.

Verification: both complete unit-suite runs printed
`cat: <tmp>/server-paths: No such file or directory`, then the three
successful collision messages and `All tests passed.` This explains why the
passing suite is weaker than its documented packaging guarantee.

Fix: produce both lists before using either, and explicitly fail if list
generation/concatenation fails. Add a regression that deliberately stages a
conflicting server temp path and confirms that the assertion fails.

### R18 — P2: Fence all human-readable status text away from NCV

Locations: `extensions/smart/smart.sh:728-745`;
`extensions/fritzdsl/fritzdsl.sh:388-402`;
`extensions/fritzwan/fritzwan.sh:412-429`;
`extensions/wifi/wifi.sh:461-482`; their `server/xymonserver.d/*.cfg` files.

These extensions send separate numeric data messages but also send unfenced
human-readable lines with equals signs. Changing `name : value` to
`name=value` does not exclude a line from NCV. Their SPLITNCV configurations
accept unspecified names with `*:GAUGE`, so display text can create unwanted
datasets. SMART's unprefixed metric-detail lines can additionally conflate
different drives in a bogus shared dataset. Existing SMART/Wi-Fi comments
and the SMART assertion near `tests/run.sh:213-216` encode the wrong assumption.

Evidence: normal fixtures produce numeric display lines such as
`sync rate down=116797 up=46719 kbit/s`; none of these four scripts emits the
skip fences already used by temp, if_link, lxc and xymonext. This is an
output/configuration finding, not a live-server RRD creation test. Xymon's
[NCV documentation](https://xymon.sourceforge.io/xymon/help/manpages/man8/xymond_rrd.8.html)
specifies both separators, processing of status and data messages, and the
`ncv_skipstart`/`ncv_skipend` mechanism.

Fix: fence the complete human-readable status body and leave only intended
metric lines visible. Apply the existing `ncv_view` regression strategy to
all four extensions, including warning and error reports, and verify the
resulting dataset set on a real server.

### R19 — P2: Align if_link's total calculation with the standalone interval

Locations: `extensions/if_link/server/graphs.d/if_link.cfg:50-57`;
`standalone/crontab.example:11`; `packaging/opkg/postinst:6-7`;
`standalone/standalone.cfg:35`.

The graph divides a per-poll GAUGE by 300 before integrating it with TOTAL.
That conversion assumes a 300-second poll interval. The shipped standalone
schedule runs every 600 seconds and enables if_link, giving a systematic
factor-of-two error even with perfectly regular polling. The server README
acknowledges the five-minute assumption, but the default standalone setup
does not satisfy it; this is more than the documented small jitter drift.

Verification: configuration and dimensional analysis. A sample of two
changes held over 600 seconds contributes `2 / 300 * 600 = 4` to the total,
not two. No RRDtool execution was available; real archive heartbeat/gaps may
add missing data, but cannot make this conversion generally correct.

Fix: send an elapsed-time-normalized rate or use an appropriate counter
representation and adjust the graph, or consistently enforce/document the
required interval in every supported installation path. Regression-test
identical event streams at both 300 and 600 seconds with RRDtool.

## Recommended follow-up and acceptance criteria

1. Address R01/R02 before relying on the supplied privileged deployment
   examples on a multi-user host; add permission-boundary tests.
2. Fix false-success and missing-coverage behavior (R03-R05, R08-R10, R14-R15)
   with negative-path fixtures. Distinguish unavailable data from measured
   healthy values without changing deliberately inapplicable checks to red.
3. Repair Debian migration packaging and the ineffective assertion (R16-R17),
   then perform actual isolated historical-version upgrade/rollback tests.
4. Correct resource identity, counter validity and graph ingestion (R06-R07,
   R11-R13, R18-R19); verify the exact server datasets and graph units.
5. Run the full ShellCheck/unit gate and the native BusyBox, Rocky and
   FreeBSD build/runtime checks. Add live Xymon/RRDtool integration coverage;
   local string assertions alone do not validate the server's interpretation.

No additional module-specific correctness finding was confirmed for `la` or
the memory calculation itself; the shared delivery issue still applies.
Intentional configuration sourcing, clear statuses on unsupported platforms,
and the documented single-wrap limitation were not treated as defects by
themselves. This review is evidence-based but is not a guarantee that no
other bugs or platform-specific issues exist.
