# dnf — Xymon **server** configuration

Together with its status, the extension sends a `data` message with
eight values:

```
updates : 20
security : 12
critical : 1
important : 11
moderate : 6
low : 1
unknown : 0
cves : 24
```

`updates` and `security` count packages, `critical` to `unknown` count
pending security advisories per severity, `cves` the distinct CVEs the
pending updates fix. The Xymon server turns them into one `dnf.rrd`
per host with eight datasets, via plain **NCV**. This is a one-time
setup on the Xymon server host.

Both steps are **drop-in files**: nothing in a stock Xymon config file
has to be edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform (Debian/Ubuntu ship them ready to use, and the
`my-xymon-extensions-server` package installs both files there).

## 1. xymonserver.d/dnf.cfg

Copy the snippet shipped next to this README into the server's
drop-in directory:

```sh
cp xymonserver.d/dnf.cfg /etc/xymon/xymonserver.d/
```

```
TEST2RRD+=",dnf=ncv"
NCV_dnf="updates:GAUGE,security:GAUGE,critical:GAUGE,important:GAUGE,moderate:GAUGE,low:GAUGE,unknown:GAUGE,cves:GAUGE"
GRAPHS+=",dnfupd,dnfsec"
GRAPHS_dnf="dnfupd,dnfsec"
```

## 2. graphs.d/dnf.cfg

Copy the graph definitions shipped next to this README:

```sh
cp graphs.d/dnf.cfg /etc/xymon/graphs.d/
```

- `dnfupd` — pending updates: all packages, and those with a security
  advisory
- `dnfsec` — pending security advisories, stacked by severity, with
  the number of distinct CVEs in the legend

## 3. Restart / verify

Restart the Xymon server (a restart, not a reload — on Debian/Ubuntu
the list of included drop-in files is regenerated at start). After the
next report, check that the RRD file appears:

```
ls $XYMONVAR/rrd/<host>/dnf.rrd
```

The client sends all eight values in every message, or none at all
while the update status is unknown: plain NCV creates the RRD file
with the datasets of the first message it sees.

The graphs need a value at least every 10 minutes (Xymon's RRD
heartbeat is 600 seconds); the client task therefore runs every 5
minutes by default.

## Alerting

The column is red while a critical or important security update is
pending and yellow for everything else it reports (other updates,
stale repository metadata, a pending reboot — all configurable on the
client), so a normal `alerts.cfg` rule is enough, e.g.:

```
HOST=* TEST=dnf
    MAIL admin@example.com COLOR=red REPEAT=24h
```

The status text starts with an overview of all findings, so the first
lines of the alert mail already name them.
