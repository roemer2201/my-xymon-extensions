# ntfy-alert - Xymon alerts as ntfy push notifications

Forwards Xymon alerts to an [ntfy](https://ntfy.sh/) server
(self-hosted or ntfy.sh) as push notifications. Publishing to ntfy is
a plain HTTP POST, so the script only needs `curl` - no ntfy client
software has to be installed anywhere.

Unlike the other extensions in this repository this is **not a client
test**: it reports no column, needs no `tasks.d` snippet and is not
started by `xymonlaunch`. Instead, `xymond_alert` on the **Xymon
server** runs it through a `SCRIPT` rule in `alerts.cfg`, once per
alert.

| | |
|---|---|
| Column | none (alert script) |
| Runs on | the Xymon server only |
| Requires | `curl`, an ntfy topic and an access token |

## What a notification looks like

* **Title**: `hostname : service is RED` (or `... recovered`)
* **Priority**: `red` → `high`, `yellow` → `default`,
  recovery → `low` (all configurable)
* **Tag/emoji**: 🔴 red, 🟡 yellow, 🟣 purple, ✅ recovered,
  🔕 disabled
* **Body**: the alert text Xymon generated (`$BBALPHAMSG`), truncated
  to the ntfy message size limit, plus the acknowledge code
* **Click action** (optional): tapping the notification opens the
  host/service status page in the Xymon web UI (`NTFY_CLICKURL`)

## Setup

1. On the ntfy server, create a topic for Xymon (e.g. `xymon`) and an
   access token for a user that may publish to it:

   ```sh
   ntfy user add xymon
   ntfy access xymon xymon write-only
   ntfy token add xymon
   ```

2. On the Xymon server, edit `ntfy-alert.cfg` (installed into the
   package's `etc/` directory, e.g. `/etc/xymon/ntfy-alert.cfg` on
   Debian/Ubuntu) and set `NTFY_URL` and `NTFY_TOKEN`. The file holds
   a secret - `chmod 600` and give it to the Xymon user.

3. Hook the script into the Xymon server's `alerts.cfg` with the
   topic as the recipient. The script path is the client `ext/`
   directory this package installs into:

   ```
   HOST=*
       SCRIPT /usr/lib/xymon/client/ext/ntfy-alert.sh xymon COLOR=red,yellow RECOVERED
   ```

   Different rules may use different topics, and a full URL as the
   recipient overrides `NTFY_URL` entirely
   (`SCRIPT ... https://other.ntfy.example.org/critical`).

4. Test it manually (as the Xymon user):

   ```sh
   BBHOSTNAME=test BBSVCNAME=demo BBCOLORLEVEL=red \
   BBALPHAMSG="manual ntfy-alert test" \
   NTFY_CFG=/etc/xymon/ntfy-alert.cfg \
       /usr/lib/xymon/client/ext/ntfy-alert.sh xymon
   ```

   The phone rings; errors go to stderr.

## Error handling

Anything that prevents the notification from going out - missing
token, missing `NTFY_URL`, no `curl`, unreachable server, HTTP error
from ntfy - is logged to stderr and the script exits non-zero.
`xymond_alert` captures stderr in its log
(`$XYMONSERVERLOGS/alert.log` on most installations), so failed
notifications are visible there. There is deliberately no silent
mode: an unconfigured alert script that eats alerts would be worse
than a noisy one.

## Configuration reference

All settings live in `$XYMONHOME/etc/ntfy-alert.cfg`
(see the shipped file for the full comments):

| Variable | Default | Meaning |
|---|---|---|
| `NTFY_URL` | *(required)* | Base URL of the ntfy server |
| `NTFY_TOKEN` | *(required)* | Access token (`tk_...`) |
| `NTFY_TOKEN_FILE` | unset | Read the token from this file instead |
| `NTFY_CLICKURL` | unset | `svcstatus.sh` CGI URL for tap-to-open |
| `NTFY_PRIO_RED` | `high` | ntfy priority for red alerts |
| `NTFY_PRIO_YELLOW` | `default` | ... for yellow (and purple) alerts |
| `NTFY_PRIO_RECOVERED` | `low` | ... for recovery/disabled notices |
| `NTFY_MAXCHARS` | `3500` | Body truncation limit |
| `CURL` | from `$PATH` | Path to curl |
| `TIMEOUT` | `15` | Seconds for the whole request |

## Platform notes

* The script itself is POSIX sh and runs on every platform this
  repository targets, but it is only *useful* where `xymond_alert`
  runs - i.e. on the Xymon server.
* The config is read from `$XYMONHOME/etc/ntfy-alert.cfg`. On
  Debian/Ubuntu and EL both the server's and the client's `etc/`
  resolve to `/etc/xymon`, so this just works. Where the server's
  `XYMONHOME` differs from the client's install directory (e.g.
  FreeBSD: server `/usr/local/www/xymon/server`, package config in
  `/usr/local/www/xymon/client/etc`), point the script at the file
  explicitly by adding `NTFY_CFG="/path/to/ntfy-alert.cfg"` to
  `xymonserver.cfg`.
* Why not the ntfy CLI? Package availability is spotty (nothing in
  the Ubuntu/EPEL repos, no OpenWrt package, and FreeBSD's
  `sysutils/ntfy` is an unrelated project of the same name) - and for
  one-way publishing it adds nothing over the HTTP API.
