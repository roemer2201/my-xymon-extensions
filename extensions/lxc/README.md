# lxc — LXC container status and resource usage

Xymon client extension that reports every **LXC container** of a host
in one status column, with a `data` message for RRD graphing: which
containers exist, which of them run, and what each one costs in memory,
CPU and network traffic.

- **Column:** `lxc` (override with `LXC_COLUMN`).
- **Platforms:** Linux with the LXC userspace tools. Written for
  OpenWrt/TurrisOS routers running through the standalone runner
  (a Turris Omnia with LXC 6.0.5 and cgroup v2 is the reference
  system), but works on any Linux host with LXC. Hosts without
  `lxc-ls` report `clear`.
- **Colors:** `red` when a container that is supposed to run does not
  (configurable to `yellow` via `LXC_DOWN_COLOR`), `yellow` while a
  container is frozen or in a state transition, otherwise `green`.
  Resource thresholds are opt-in and off by default.

## Which containers are supposed to run

This is the whole point of the column, and it is not a setting you have
to maintain twice: the extension derives the answer from the same places
the host itself uses to start containers.

| Source | What it is | Why it is needed |
|---|---|---|
| `lxc.start.auto` | the `AUTOSTART` column of `lxc-ls -f` | the LXC-native flag |
| `/etc/config/lxc-auto` | the OpenWrt/TurrisOS UCI autostart list | that init script starts containers **without** `lxc.start.auto`, so the flag alone misses them |
| `lxc-autostart -L` | containers LXC would start right now | catches setups where neither of the above applies |

A container named by any of them must run; anything else may be stopped
and is shown as `not autostarted` without coloring the column.

`lxc-autostart -L` deserves a warning: it lists only the containers it
**would start**, i.e. running ones are filtered out. On a healthy host
it therefore prints *nothing at all*, which is why it can never be the
only source. Verified on TurrisOS 9.1.1 with LXC 6.0.5:

```
# lxc-ls -f -F NAME,STATE,AUTOSTART
NAME             STATE   AUTOSTART
jd               RUNNING 1              <- lxc.start.auto is set
thunderbird-test STOPPED 0
# lxc-autostart -L                       <- empty: jd already runs
# lxc-autostart -L -A                    <- -A ignores lxc.start.auto
thunderbird-test 0
```

Two settings override the automatic detection:

- `LXC_REQUIRED` — an explicit list of glob patterns. When set, it
  **replaces** all three sources above: exactly these containers must
  run.
- `LXC_OPTIONAL` — glob patterns that are removed from the set again,
  for containers that are autostarted but may be down without alarm.
- `LXC_IGNORE` — glob patterns that are not monitored at all: no status
  line, no metrics, no graph.

## Metrics (NCV names)

Metric names are keyed by the **sanitized** container name — lowercase,
everything outside `[a-z0-9]` replaced by `_`, so `thunderbird-test`
becomes `thunderbird_test`.

| Name | Unit | Meaning |
|------|------|---------|
| `<ct>_ram` | MiB | resident memory of the container |
| `<ct>_cpu` | percent of one core | CPU used since the previous poll |
| `<ct>_netin` | kbit/s | traffic **into** the container |
| `<ct>_netout` | kbit/s | traffic **out of** the container |
| `count_total` | count | containers defined on this host |
| `count_running` | count | containers currently running |
| `count_down` | count | containers that should run but do not |

Split-NCV puts every one of these into an RRD file of its own
(`lxc,ca_ram.rrd`, …), so adding or destroying a container never
disturbs the graph of another one — see
[server/README.md](server/README.md).

`cpu`, `netin` and `netout` are differences between two polls, computed
from a state file (`$XYMONTMP/lxc.<host>.state`); they appear with the
**second** poll and are skipped for one poll whenever a counter went
backwards, which is what a container restart looks like. Since they are
averages over the poll interval, keep that interval stable.

Everything else — state, PID, autostart source — is shown in the status
text only. That block is fenced with `<!-- ncv_skipstart -->` /
`<!-- ncv_skipend -->`, because the server's NCV parser treats `=` like
`:` and would otherwise turn every `state=RUNNING` into an RRD dataset.

## Where the numbers come from

**CPU** — `cpu.stat` (`usage_usec`) of the container's cgroup on cgroup
v2, `cpuacct.usage` on v1. Both are cumulative; the extension computes
the delta itself.

The container's cgroup is located through its init process
(`/proc/<pid>/cgroup`) rather than by guessing a path, so all the
layouts LXC uses work: `lxc.payload.<name>` on cgroup v2,
`lxc/<name>` on v1, `lxc@<name>.service` under systemd.

**RAM** — `memory.current` (v2) or `memory.usage_in_bytes` (v1) of that
cgroup. Where the memory controller does not account the container, that
file is missing or reads `0`, and `LXC_RAM="auto"` falls back to summing
the RSS of the container's processes from `/proc`.

That fallback is the normal case on OpenWrt/TurrisOS: the root
`cgroup.subtree_control` is empty there, so no controller is delegated
to the container cgroups. It is also why `lxc-ls -f -F RAM` prints
`0.00MB` for every container on such a host, and why enabling the
controller afterwards does not help — already-charged pages are not
accounted retroactively:

```
# echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control
# cat /sys/fs/cgroup/lxc.payload.ca/memory.current
0
```

The `/proc` sum counts shared pages once per process, i.e. it is a
slight over-estimate — the number is a usable trend, not an exact
figure. It costs one pass over `/proc` per poll: about 0.2 s with 300
processes on a Turris Omnia (an ARM Cortex-A9), done in a single `awk`
rather than a shell loop, which would take five times as long. Set
`LXC_RAM="cgroup"` to only ever report exact values, or `LXC_RAM="off"`
to skip the measurement.

**Network** — the `TX bytes` / `RX bytes` counters of `lxc-info -H`,
summed over all interfaces of the container. Note that `lxc-info`
measures on the **host** side of the veth pair, so its `TX` is what the
host sent *into* the container. The metrics here are named from the
container's point of view instead:

| `lxc-info` | metric here |
|---|---|
| `TX bytes` | `netin` |
| `RX bytes` | `netout` |

`lxc-info` is a separate package on OpenWrt (`opkg install lxc-info`).
Without it everything else still works — only the two traffic metrics
are missing.

## Colors

| Situation | Color |
|---|---|
| container runs | `green` |
| container stopped, not autostarted | `green` (line marked `clear`) |
| container stopped, but supposed to run | `red` (`LXC_DOWN_COLOR`) |
| container frozen and supposed to run | `red` (`LXC_DOWN_COLOR`) |
| container frozen, not autostarted | `yellow` |
| `STARTING` / `STOPPING` / `ABORTING` | `yellow` |
| RAM or CPU above a configured threshold | `yellow` / `red` |
| no `lxc-ls`, or no container defined | `clear` |

Resource thresholds are off by default: `LXC_RAM_YELLOW`/`LXC_RAM_RED`
(MiB) and `LXC_CPU_YELLOW`/`LXC_CPU_RED` (percent of one core) apply per
container.

## Configuration

Environment variables or `$XYMONHOME/etc/lxc.cfg`; the config file wins
over the environment. See the shipped [lxc.cfg](lxc.cfg) — the
extension needs none of it to work.

## Graphing (Xymon server setup)

One-time setup on the **Xymon server**, with ready-made drop-in files:
see [server/README.md](server/README.md).

## OpenWrt / TurrisOS

Runs through the [standalone runner](../../standalone/) and is part of
its default `TESTS` list. The container tools are the only requirement:

```sh
opkg install lxc lxc-info      # lxc-ls is part of the lxc package
```

Nothing is needed inside the containers — everything is read from the
host.

## Caveats

- **Memory is an estimate** where the memory controller does not account
  the containers (the OpenWrt default) — see above.
- **CPU and traffic need two polls.** A container that has just been
  started shows neither for one interval.
- **A restart looks like a counter reset** and skips those two metrics
  for one poll, rather than reporting a nonsensical spike.
- **`lxc-ls` output is parsed by column.** Only `NAME`, `STATE`, `PID`
  and `AUTOSTART` are requested, because none of their values can
  contain a space — unlike `IPV4`/`IPV6`/`INTERFACE`, which hold
  comma-separated lists. An `lxc-ls` too old for `-F` falls back to
  `lxc-ls -1`; the autostart flag then comes from the other two sources
  only.
- **Unprivileged containers of another user** are invisible: the
  extension sees what the user it runs as can see, which for the Xymon
  client is the `xymon` user and for the standalone runner is `root`.
