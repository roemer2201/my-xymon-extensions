# claude — Claude Code login validity

Reports how much longer the **Claude Code login** of one or more
accounts on this host is valid, in one status column.

- **Column:** `claude` (`CLAUDE_COLUMN`)
- **Platforms:** Linux, FreeBSD, OpenWrt/TurrisOS (standalone runner).
- **Requires:** a POSIX shell (no `jq`); where the client does not run
  as root, one sudo rule per account ([sudoers.example](sudoers.example)).
- The `clientlaunch.d` snippet ships **disabled**: most hosts run no
  Claude Code, and the sudo rule has to exist first.

## What is checked

`$HOME/.claude/.credentials.json` holds two expiry timestamps:

| Field | Meaning | Used for |
|---|---|---|
| `refreshTokenExpiresAt` | **the login** - afterwards only an interactive `claude /login` helps | thresholds |
| `expiresAt` | access token, valid for hours, renewed on every Claude run | information only |

This matters for headless sessions (`claude --remote-control` in a
service, cron jobs, agents): they fail silently when the login expires.

## Colors

| Situation | Color |
|---|---|
| more than `CLAUDE_WARN` (10) days left | green |
| `CLAUDE_WARN` days or less | yellow |
| `CLAUDE_CRIT` (5) days or less, or expired | red |
| no credentials file, unreadable file, or no sudo rule | clear |
| account does not exist, or file without `refreshTokenExpiresAt` | yellow |

Missing logins and missing sudo rules are `clear`, not red: the default
`CLAUDE_ACCOUNTS="root"` would otherwise turn every host red.

## Accounts and privileges

List several accounts space separated (`CLAUDE_ACCOUNTS="root deploy"`);
each gets a line, the worst decides the color.

The credentials file is mode `0600`, so the unprivileged client reads it
through [`claude-expiry.sh`](claude-expiry.sh) via `sudo`. The helper
takes a **user name, never a path** - the sudoers rule names the allowed
accounts - and prints only timestamps and the subscription type, never
token material. Install the rule with
`visudo -f /etc/sudoers.d/xymon-claude`. Where the extension already
runs as root (standalone runner, OpenWrt) no rule is needed
(`CLAUDE_SUDO` `auto` or `no`).

## Configuration

Environment variables or
`$XYMONHOME/etc/my-xymon-extensions/claude.cfg` (sourced shell, wins over
the environment); see [claude.cfg](claude.cfg). Limitation: an account
that moves its config with `CLAUDE_CONFIG_DIR` is not found (`clear`).

## Example

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

No RRD graphs and no server configuration. To be alerted, e.g. in
`alerts.cfg`:

```
HOST=%.* SERVICE=claude COLOR=red,yellow
    MAIL you@example.com REPEAT=24h
```

## Manual test

```sh
/usr/lib/xymon/client/ext/claude.sh        # prints instead of sending without $XYMON
sudo -n -u xymon sudo -n /usr/lib/xymon/client/ext/claude-expiry.sh root
```

On OpenWrt add `claude` to `TESTS` in standalone.cfg; dry run:
`/usr/lib/xymon-standalone/xymon-run.sh -n claude`.

Note: each failed `sudo -n` (missing rule) is logged by sudo, and if
the xymon user is not in sudoers at all, sudo mails root by default
(`mail_no_user`). Set up the rule before enabling the task.
