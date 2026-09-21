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
Use stable peer/slot metric keys and split NCV; keep snapshots and interval
metrics distinct. Unknown measurements must remain graph gaps, not zeros.
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

Plan committed before implementation. Continue on this branch, inspect git
status and history before editing, and preserve any newer work. No merge or
production deployment authorized. Once implementation is complete, replace
this paragraph with validation results and remaining installation steps.
