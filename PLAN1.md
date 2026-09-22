# Powerline server test - approved implementation plan

## Scope and environment

Implement a POSIX sh, ASCII-only Xymon server task on branch
`claude/powerline-monitoring`. Start from current main (including PR #40).
Target installation: Ubuntu 26.04, Xymon 4.3.30-5, user xymon,
configurable Ethernet interface (eth0 initially). Poll every 5 minutes,
status lifetime 15 minutes. No PLC writes, resets or traffic generation.

## Collection and identity

Discover topology using plcstat -t. Preserve LOC/REM membership and PLC
MAC/BDA separately. Read PHY rates with plcrate -n and peer statistics
with plcstat -d both -s 0xF8 -p PEER DEVICE, from both endpoints.
Validate stdout contents, never trust a successful exit code alone.
Keep stderr for diagnostics. Each adapter reports its own powerline column
and its own direction/peer metrics. Local adapter BDA can be the server's
MAC: resolve local adapters by PLC MAC, remote adapters by BDA then PLC MAC.
Use a canonical hosts.cfg name including CLIENT aliases and included files;
optional explicit MAC-to-host mapping wins over unambiguous neighbor/IP
matching. Preserve established identity when the neighbor cache expires.
Do not guess conflicting mappings. Unknown identities send a safe synthetic
hostname to Xymon's native ghosts=log handling, with no separate ghost list.

## Topology state machine

The first successful inventory is a baseline. Each later presence change
or new adapter starts/restarts 60 minutes of yellow immediately on detection.
Keep the start of an uninterrupted change-warning episode separately from
its most recent change. At 180 minutes of uninterrupted changes/warning,
report red with the exact text `state flapping`. A full 60 minutes without
a change ends the episode (including red); a later change starts a new one.
At the exact quiet deadline, a newly observed transition is conservatively
part of the existing episode, avoiding a green gap between polls.
Persist inventory, canonical identities and timers atomically across runs
and restarts. After accepted absence report green with no disappearance
notice in the current status; retain history/state and graph gaps. Never
normalize collector/permission/parser failures as accepted absence.
Only successfully observed topology can advance presence transitions.

## Quality and graphs

Separate TX/RX PHY minimum warn/critical and PB interval-error maximum
warn/critical settings, all disabled (`off`) initially. Enabled critical
quality or collection failures override topology yellow. Config lives in
/etc/xymon/my-xymon-extensions-server/powerline.cfg, included through a
server-owned Xymon drop-in. CLI > exported environment > config > defaults.

Capture cumulative PB/MPDU counters, TX collisions, displayed ratios,
RX per-slot PHY/PB/BER fields, RX ALL fields and the final FEC-BER value.
RX slot fields are not TX slot statistics. BER ERR is a ratio of two BER
sums, not the final FEC bit error rate. Do not sum ALL and slots together.
Compute interval differences/rates from snapshots with actual timestamps;
first sample, counter resets, gaps and no-traffic ratios are unknown.
Use stable peer/slot metric keys and native trends data; keep snapshots and interval
metrics distinct. Unknown measurements must remain graph gaps, not zeros.
Implementation correction: Xymon's do_trends.c accepts RRD U values directly;
the NCV parser does not. Native trends avoids sentinel-value consolidation bugs.
Provide PHY overview and grouped detail graphs on status and trends pages.
Treat plcrate values as PHY rate, not measured application throughput.

## Integration and validation

Install only in the server package, never a duplicate client task. Ship
task, config, mapping example, sudoers example, graph/RRD drop-ins and
installation documentation. Use an unprivileged collector with a narrowly
validated root-owned helper for fixed read-only PLC operations via sudo -n.
Do not automatically grant sudo privileges or restart the user's server.
Provide header, program flow, --help, silent/verbose, env equivalents and
syslog diagnostics. Test parsers with supplied fixtures; topology loss,
appearance, repeated flapping, 180-minute escalation, quiet recovery,
restart, mapping conflicts, empty successful output, parser errors, counter
reset, no traffic, unavailable metrics, locks and delivery failures.
Run repository tests, BusyBox checks and Debian client/server package builds.
Commit implementation separately from this plan; push, do not merge.

## Source references

- https://xymon.sourceforge.io/xymon/help/manpages/man5/tasks.cfg.5.html
- https://xymon.sourceforge.io/xymon/help/manpages/man8/xymond.8.html
- https://xymon.sourceforge.io/xymon/help/manpages/man8/xymond_rrd.8.html
- https://github.com/qca/open-plc-utils/blob/master/plc/plcstat.1
- https://github.com/qca/open-plc-utils/blob/master/plc/plcrate.1
- https://github.com/qca/open-plc-utils/blob/master/plc/LinkStatistics.c

## Progress / resumption

Implementation complete on 2026-09-22; version 0.21.0. Plan was committed
before implementation. Server-only collector, privileged read-only helper,
persistent per-adapter state, identity resolution, thresholds, native trends,
11 graph definitions, packaging and installation documentation are included.

Validation completed:
- make test with ShellCheck 0.10.0 and dash: passed (including 95 Powerline
  assertions plus negative-input tests and the existing repository suite).
- Full suite under BusyBox 1.36.1 sh and userland: passed.
- make graphcheck with RRDtool 1.7.2: all 11 graphs rendered; explicit U
  samples verified as unknown, not zero.
- make deb, make deb-server, make opkg: passed. Client/server file-ownership,
  conffiles, executable placement and no duplicate client task checked.
- Changed Powerline shell files also pass ShellCheck 0.11.0. Its new SC2329
  warning flags existing unrelated smart.sh functions in the full repository;
  the full-suite check uses the Ubuntu-aligned 0.10.0 instead.
- git diff --check and ASCII checks for all new code: passed.

No real PLC commands were run and no production installation, sudo grant,
server restart or merge was performed. RPM and native FreeBSD builds were
not run in this Linux environment. Actual Xymon include wiring, ghost-list
display, hardware measurements and live web graphs remain installation-time
checks, documented in extensions/powerline/server/README.md. The package
ships POWERLINE_ENABLED=0; quality limits are off. Administrators must review
the sudoers example and dry-run output before enabling the task.

## Review of the implementation (2026-09-22, after e916ad0)

The implementation was reviewed against the actual sources of Xymon 4.x and
open-plc-utils rather than from memory. Confirmed correct: the
`data HOST.trends` wire format and that "U" reaches rrdupdate unchanged
(xymond/rrd/do_trends.c); PCRE, not POSIX regcomp, for FNPATTERN, so the
`(?:...)` groups are valid (web/showgraph.c, pcre_compile); every field
offset of `plcstat -d both -s 0xF8` including the unlabelled TX collision
count (plc/LinkStatistics.c); the FEC formula's 4160 bits per PB
(fec_bit_error_rate, 8 * 520); `-d both` and `-s 0xF8` as tool synonyms; the
LOC BDA really being the server's own NIC (plc/Topology2.c); and tasks.d as
the correct home for a server-only task (tasks.cfg.DIST includes the client
list, so clientlaunch.d would run it twice).

Six defects were found and fixed on top of e916ad0:

1. The status page showed no graphs at all. svcstatus.cgi reads
   GRAPHS_<column> only inside `if (rrd && graph)`, and find_xymon_rrd()
   resolves a column from TEST2RRD alone (lib/htmllog.c, lib/xymonrrd.c).
   The drop-in now adds the column; it is a no-op for xymond_rrd, which has
   no handler of that name.
2. The topology parser demanded nine fields but uses seven. CHIPSET and
   FIRMWARE come from a second per-device request (VS_SW_VER,
   plc/Platform.c) that prints nothing when unanswered, so one lost packet
   on the powerline produced a failed inventory and a red status for every
   adapter.
3. Removing the mapping conffile the shipped config names made awk fail on
   every poll. An absent file now means "no static mapping"; an existing but
   unreadable one is still an error.
4. A hosts.cfg name equal to another host's CLIENT alias aborted the whole
   collector permanently, over an entry unrelated to the adapters. Aliases
   are now folded in after all hosts are known, so the result no longer
   depends on file order; a real host name wins, an alias two hosts claim is
   dropped, and both cases are logged instead of stopping collection.
5. stage-server.sh hardcoded /usr/lib/xymon/server/ext while every other
   path was an argument. It now takes BINDIR, and the installed files name
   both directories through @BINDIR@/@ETCDIR@ placeholders that it resolves,
   so passing a different layout actually changes the installed task, sudoers
   example, include line and mapping path.
6. tests/run.sh built its list of server-package paths fifty lines after the
   drop-in collision check used it, so that check had never looked at the
   server package. The list is built where it is first needed, and an empty
   list now fails the suite.

The drop-in name collision check was widened at the same time. The names the
stock packages claim were read from the actual Ubuntu 24.04 package contents
(hobbit-plugins 20230301, xymon/xymon-client 4.3.30-2ubuntu0.1): 23 names in
clientlaunch.d, 7 in graphs.d, 8 in xymonserver.d, none in rrddefinitions.d,
and none in tasks.d - the xymon package ships that directory empty, which is
what makes the server-only powerline task legitimate there. The previous
check pinned only temp.cfg.

Each fix is pinned by a test that was verified to fail without it.

Deliberately not changed: the xymonserver.d drop-in keeps a plain `include`
rather than `optional include`, because a missing configuration file should
be visible as a warning in the Xymon log.

## Open TODOs (not blocking, no request pending)

- powerline.sh calls the privileged helper inside `while read < file` loops
  and so passes the loop's stdin to it. A sub-process that read stdin would
  silently truncate the loop. Add `</dev/null` to the helper invocations.
- extensions/powerline/README.md ships in no package; only
  server/README.md is installed. Either install it or fold it in.
- The inventory never prunes: `for (m in known) inventory[m] = 1` keeps a
  permanently removed adapter green forever, and its series in every trends
  message. A retention setting would bound the state file and message size.
- A backward system clock larger than the poll interval (VM snapshot, large
  NTP step) is a hard failure and reds every adapter until the clock catches
  up. Intended, but the operational consequence deserves a line in the
  server README.
- Because xymonserver.cfg includes powerline.cfg, all POWERLINE_* settings
  are already environment variables, which silently override a manual
  `--config /other/file.cfg`. The precedence is documented; the trap is not.
- The parser treats any mismatch between the queried adapter and the MAC in
  the plcrate response as a hard error for that adapter. The assumption that
  a remotely addressed device answers with its own Ethernet source address
  is standard for open-plc-utils remote management but cannot be verified
  without hardware; if it does not hold, the adapter stays red instead of
  merely lacking values.
- RPM and FreeBSD server packaging do not exist. If they are ever added,
  stage-server.sh now takes the paths as arguments, but the `tasks.d`
  layout and the helper's fixed /usr/bin tool paths would need review.

Future automatic resumption: implementation is complete; do not restart
development from this plan without a new request.
