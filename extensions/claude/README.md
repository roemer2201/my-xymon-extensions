# claude — Claude Code login validity

Xymon client extension that reports how much longer the **Claude Code
login** of one or more accounts on this host is valid, in a single
status column.

- **Column:** `claude` (override with `CLAUDE_COLUMN`)
- **Platforms:** any host where Claude Code is installed — Linux
  (Debian/Ubuntu, Rocky/EL), FreeBSD, and OpenWrt/TurrisOS via the
  standalone runner. Hosts without a login report `clear`.
- **Requires:** nothing but a POSIX shell — no `jq`. Where the Xymon
  client does not run as root, one sudo rule per checked account (see
  [sudoers.example](sudoers.example)).
- **Note:** the shipped `clientlaunch.d` snippet is **disabled by
  default**: most hosts run no Claude Code, and the check needs the
  sudo rule set up first.

## What is checked, and why

Claude Code stores its OAuth tokens per account in
`$HOME/.claude/.credentials.json`. Two expiry timestamps live in there,
and only one of them is the login:

| Field | What it is | Reported as |
|---|---|---|
| `refreshTokenExpiresAt` | **the login.** When it passes, nothing renews itself any more and somebody has to run `claude /login` interactively | thresholds, colors the column |
| `expiresAt` | the access token — valid for hours, renewed automatically whenever Claude runs | information only |

Alarming on the access token would be a permanent false alarm: on a
host where nobody has used Claude for a day, it is expired and that is
perfectly normal.

The check earns its place on hosts that run Claude Code **headless** —
`claude --remote-control` from a systemd unit, a cron job, an agent.
Such a session stops working the moment the refresh token expires, it
fails silently, and the repair needs a human at a terminal. The default
thresholds give ten days' warning.

## Thresholds and colors

| Setting | Default | Meaning |
|---|---|---|
| `CLAUDE_WARN` | `10` | yellow at or below this many days left |
| `CLAUDE_CRIT` | `5` | red at or below this many days left |

| Situation | Color |
|---|---|
| more than `CLAUDE_WARN` days left | green |
| `CLAUDE_WARN` days or less | yellow |
| `CLAUDE_CRIT` days or less, or already expired | red |
| account has no credentials file (not logged in, no Claude Code) | clear |
| credentials file unreadable, or no sudo rule for the helper | clear |
| account listed in `CLAUDE_ACCOUNTS` does not exist | yellow |
| credentials file without a `refreshTokenExpiresAt` field | yellow |

Only `green`/`yellow`/`red`/`clear` are sent — never `blue`/`purple`,
those are managed by the server.

A host that simply has no Claude Code login stays `clear` rather than
red on purpose: the extension ships with `CLAUDE_ACCOUNTS="root"` and
would otherwise go red on every host in the network. The same goes for
a missing sudo rule — that is a setup step on the monitoring side, not
a fault of the monitored host.

## Several accounts

The login is per user account, so a host can have several, expiring on
different days. List them space separated:

```sh
CLAUDE_ACCOUNTS="root deploy alice"
```

Every account gets its own line in the status message; the worst one
determines the column color.

## Privileges: why a helper, and why it takes a user name

The credentials file is mode `0600` in a private home directory. The
Xymon client runs as an unprivileged user (`xymon`) and cannot read it,
and `xymonlaunch` has no way to run a single task under another
account.

All reading therefore happens in a separate, deliberately tiny script,
[`claude-expiry.sh`](claude-expiry.sh), which the extension calls
through `sudo`:

- It takes **exactly one argument, a user name** — never a path. The
  sudoers rule names the accounts that may be asked about, so the rule
  cannot be turned into a way of reading arbitrary files as root.
- It prints **only** the two timestamps and the subscription type.
  Token material never leaves the script, not even truncated.

Install the rule with `visudo -f /etc/sudoers.d/xymon-claude`; the
shipped [sudoers.example](sudoers.example) contains a ready line for
the `root` account and shows how to add more.

Hosts where the extension already runs as root — the standalone runner
from root's crontab, OpenWrt/TurrisOS — need no rule at all. Set
`CLAUDE_SUDO="no"` there (or leave it at `auto`, which notices).

## Configuration

Every setting is an environment variable with a built-in default and
can also be set in `$XYMONHOME/etc/my-xymon-extensions/claude.cfg` (sourced POSIX shell; a
value set there wins over the environment). See the shipped
[claude.cfg](claude.cfg).

Known limitation: the credentials file is looked up at
`$HOME/.claude/.credentials.json` of each account. An account that
moves that directory with `CLAUDE_CONFIG_DIR` is not found and reports
`clear`.

## Example status message

```
status myhost.claude yellow Mon Sep 21 22:40:03 CEST 2026 - root: login expires in 8 day(s)

&yellow root - login valid for 8 more day(s), until 2026-09-30 17:18 CEST [pro]
       access token expired 2026-09-21 06:02 CEST, renewed at the next Claude run
&clear deploy - no Claude Code login (/home/deploy/.claude/.credentials.json does not exist)

&clear Thresholds: yellow at 10 day(s) left, red at 5 day(s).
&clear Checked account(s): root deploy
&clear A login is renewed by running "claude /login" as that account -
&clear interactively, it cannot be automated.
```

## Alerting (Xymon server setup)

No server-side configuration is needed for the column itself. The
column produces no RRD graphs — a countdown that drops by one a day
and jumps back up on renewal says nothing a graph would make clearer.

To be notified instead of having to look, add a rule to `alerts.cfg`
on the server, e.g.:

```
HOST=%.* SERVICE=claude COLOR=red,yellow
    MAIL you@example.com REPEAT=24h
```

## Manual test

```sh
# as root, or as the user the Xymon client runs as
/usr/lib/xymon/client/ext/claude.sh

# check the sudo rule by itself
sudo -n -u xymon sudo -n /usr/lib/xymon/client/ext/claude-expiry.sh root
```

Without `$XYMON`/`$XYMSRV` in the environment the status message is
printed instead of sent, which is what makes this useful for testing.

## OpenWrt / TurrisOS

Runs through the standalone runner (see
[standalone/README.md](../../standalone/README.md)). It is installed
but not in the default `TESTS` list — add `claude` there on a router
that actually runs Claude Code:

```
TESTS="disk if_link la lxc memory opkg smart temp wifi claude"
```

Dry run: `/usr/lib/xymon-standalone/xymon-run.sh -n claude`
