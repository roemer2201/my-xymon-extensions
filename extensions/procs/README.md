# procs — process checks

Xymon client extension that brings the standard **`procs`** column to
hosts without a Xymon client: it collects the process list with `ps`
and has it checked against PROC rules, either by the Xymon server
(default) or on the host itself.

- **Column:** `procs` (the standard Xymon column)
- **Platforms:** Linux with procps-ng (regular distributions, TurrisOS)
  or BusyBox `ps` (stock OpenWrt), FreeBSD. Reports `clear` if no
  usable `ps` is found.
- **Requires:** nothing — BusyBox userland is enough.
- **Note:** a full Xymon client already sends the process list in its
  own client message, so the shipped `clientlaunch.d` snippet is
  **disabled by default**. This extension is meant for clientless
  hosts (routers, appliances) driven by the standalone runner. Never
  enable it next to a full client.

## Two modes

### `PROCS_MODE="server"` (default)

The extension sends a minimal **client message** — the same kind of
message a full client sends, with only a `[date]` and a `[ps]`
section:

```
client router,example,com.linux
[date]
Sun Oct 18 21:20:01 CEST 2026
[ps]
  PID  PPID USER      STARTED S PRI %CPU         TIME %MEM        RSZ        VSZ CMD
    1     0 root       Oct 09 S  19  0.0     00:00:04  0.1       3364       4596 /sbin/procd
...
```

The server's `xymond_client` evaluates it like any client report: the
`PROC` rules of **`analysis.cfg`** apply, the `procs` column looks
exactly like that of a full client, and `TRACK` creates the
per-process count graphs. Add rules for the host as usual:

```
HOST=router.example.com
	PROC dnsmasq
	PROC "%^/usr/sbin/hostapd" 1 1 red
	PROC dropbear 1 0 yellow TRACK=sshd
```

Without a rule for the host the column is `clear` with "No process
checks defined" — exactly as for a full client.

**Side effect — `msgs` and `files`:** for every client message the
server also reports a `msgs` column ("No log data available") and a
`files` column ("No files checked"), both `clear` (`xymond_client`
defaults, `--no-clear-msgs`/`--no-clear-files` switch them off for
all hosts). The `cpu`, `disk`, `memory` and `ports` columns are not
touched: the message has no data for them, so the `disk`, `la` and
`memory` extensions keep their columns. To drop the two clear columns
for the host only, add the `NOCOLUMNS` tag in `hosts.cfg`:

```
192.0.2.1   router.example.com   # NOCOLUMNS:msgs,files
```

If the columns already exist, drop them once with
`xymon 127.0.0.1 "drop router.example.com msgs"` (and `files`), or
they go purple.

The server also records the client message, so the host's "Client
data" link shows the process list, and it sets the host's OS to
`linux`. The server answers a client message with the host's section
of `client-local.cfg`; the extension discards it.

### `PROCS_MODE="local"`

The rules are evaluated on the host and the column is reported as a
normal status message — for hosts whose rules should not live in the
server's `analysis.cfg`, or a server you cannot configure. The rules
go into `PROCS_RULES` in `procs.cfg`, one per line, in the syntax of
an `analysis.cfg` PROC line without the keyword:

```sh
PROCS_MODE="local"
PROCS_RULES='
dnsmasq
"%^/usr/sbin/hostapd" 1 1 red
dropbear 1 0 yellow TEXT=sshd
'
```

`NAME [MIN [MAX [COLOR]]]`, `min=`, `max=`, `color=` and `TEXT=` work
as on the server (Xymon 4.3.30, `xymond/client_config.c`), and so do
the counting, the colors and the status text
(`xymond/xymond_client.c`, `unix_procs_report()`). Differences:

- `%REGEX` is a POSIX extended regular expression (awk), not PCRE —
  no `\d`, `\s`, lazy quantifiers or lookarounds.
- `TRACK` is accepted but ignored: the count graphs are built by the
  server from the client message only.
- `HOST=`, `CLASS=`, `GROUP=`, `TIME=` and the other qualifiers are
  ignored; the rules apply to this host.

## How the process list is collected

The server finds the command in every ps line by the column offset of
`CMD` (Linux backend) or `COMMAND` (FreeBSD backend) in the **first**
line, so the listing must be column-aligned. `PROCS_PSFORMAT="auto"`
tries, in this order:

| ps | Command | Listing |
|----|---------|---------|
| procps-ng (TurrisOS, distributions) | `ps -Aww f -o pid,ppid,user,start,state,pri,pcpu,time:12,pmem,rsz:10,vsz:10,cmd` — the full Linux client's own command (retried without `f`) | unchanged |
| BusyBox with `CONFIG_DESKTOP` | `ps -o stat,pid,ppid,user,vsz,rss,args` | reformatted |
| BusyBox without it (stock OpenWrt) | `ps ww`, then plain `ps` | reformatted |
| FreeBSD | `ps -axd -ww -o pid,ppid,user,start,state,pri,pcpu,cputime,pmem,rss,vsz,command` — the full FreeBSD client's command | unchanged |

BusyBox output cannot be used as is: its header says `COMMAND`, its
columns grow past their width, and its STAT field contains blanks
(`S <`). It is rewritten into fixed columns with a `CMD` header:

```
    PID    PPID USER     STAT        VSZ        RSS CMD
   2402       - dnsmasq  S          1340          - /usr/sbin/dnsmasq -C /var/etc/dnsmasq.conf.cfg01411c ...
```

(Plain BusyBox `ps` has no PPID and RSS — shown as `-`.) A BusyBox
`ps` built without `FEATURE_PS_WIDE` cuts every line at 79
characters; rules that match the start of the command still work,
the local mode adds a note.

Find out which `ps` a host has with `ls -l "$(command -v ps)"`; on
OpenWrt, `opkg install procps-ng-ps` gives the full client's format.

## Configuration

Every setting is an environment variable with a built-in default and
can also be set in `$XYMONHOME/etc/my-xymon-extensions/procs.cfg`
(sourced POSIX shell; a value set there wins over the environment).
See the shipped [procs.cfg](procs.cfg).

| Setting          | Default  | Meaning |
|------------------|----------|---------|
| `PROCS_MODE`     | `server` | `server` (client message) or `local` |
| `PROCS_RULES`    | empty    | local mode: PROC rules, one per line |
| `PROCS_PSLIST`   | `yes`    | local mode: append the process list |
| `PROCS_COLUMN`   | `procs`  | local mode column, and the column of the `clear` status when no process list can be collected |
| `PROCS_OSTYPE`   | from ps  | server mode: client OS type (`linux`, `freebsd`) |
| `PROCS_CLASS`    | empty    | server mode: client class for `CLASS=` rules |
| `PROCS_PSFORMAT` | `auto`   | `auto`, `procps`, `busybox-desktop`, `busybox`, `freebsd` |
| `PROCS_PS`       | `ps`     | the ps command |

## OpenWrt / TurrisOS

Runs through the standalone runner (see
[standalone/README.md](../../standalone/README.md)), which has it in
its default `TESTS` list. Dry run on the router — prints the client
message (server mode) or the status (local mode) instead of sending:

```
/usr/lib/xymon-standalone/xymon-run.sh -n procs
```
