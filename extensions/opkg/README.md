# opkg — package update status (OpenWrt/TurrisOS)

Xymon client extension that reports whether opkg-managed packages
have updates available — the opkg counterpart of the `apt` check from
Debian's `hobbit-plugins`. Reports one status column plus NCV lines
for RRD graphing.

- **Column:** `opkg` (override with `OPKG_COLUMN`)
- **Platforms:** OpenWrt/TurrisOS (or any opkg-based system) via the
  standalone runner. Hosts without opkg (Debian/EL/FreeBSD) report
  `clear`.
- **Requires:** opkg; root when `OPKG_UPDATE=auto` (the default —
  `opkg update` writes the package lists directory), plus working
  outbound access to the configured package feeds.
- **Note:** the shipped `tasks.d` snippet is **disabled by default**:
  hosts with a full Xymon client (deb/rpm/FreeBSD) have no opkg and
  the column would sit at `clear` forever. On OpenWrt/TurrisOS the
  standalone runner picks the extension up through the `TESTS` line
  in `standalone.cfg`, where it is enabled.

## What it checks

`opkg list-upgradable` is only as current as the downloaded package
lists — and on OpenWrt those live in `/tmp` (a RAM disk), so they are
gone after every reboot. The extension therefore:

1. locates the lists directory (`lists_dir` from `/etc/opkg.conf`,
   default `/var/opkg-lists`),
2. runs `opkg update` itself when the lists are missing or older than
   `OPKG_MAXAGE` hours (default 24; set `OPKG_UPDATE=never` if a
   separate cron job keeps them current),
3. parses `opkg list-upgradable` and matches every upgradable package
   name against the `OPKG_CRITICAL` glob patterns.

## Colors

| Situation | Color |
|-----------|-------|
| no updates available | `green` |
| updates available | `yellow` |
| an update matches an `OPKG_CRITICAL` pattern | `red` |
| `opkg update` failed (old lists are still evaluated) | at least `yellow` |
| lists stale and `OPKG_UPDATE=never` | at least `yellow` |
| no lists at all (update failed or disabled) | `yellow` |
| `opkg list-upgradable` failed | `yellow` |
| opkg not installed | `clear` |

`red` is reserved for pending security-relevant updates; opkg has no
security/regular update classification like apt, so the `OPKG_CRITICAL`
pattern list (dropbear, *ssl*, wpad, dnsmasq, firewall, ... — see
[opkg.cfg](opkg.cfg)) stands in for it. Trim or extend it to taste.

## Configuration

Every setting is an environment variable with a built-in default and
can also be set in `$XYMONHOME/etc/opkg.cfg` (sourced POSIX shell; a
value set there wins over the environment). See the shipped
[opkg.cfg](opkg.cfg).

| Setting | Default | Meaning |
|---------|---------|---------|
| `OPKG_COLUMN` | `opkg` | Xymon column name |
| `OPKG_BIN` | (auto) | opkg binary; missing → `clear` |
| `OPKG_UPDATE` | `auto` | `auto`: run `opkg update` when lists are missing/stale; `never` |
| `OPKG_MAXAGE` | `24` | hours before lists count as stale; `0` = no age check |
| `OPKG_CRITICAL` | see opkg.cfg | glob patterns that turn an update red |
| `OPKG_CONF` | `/etc/opkg.conf` | parsed for `lists_dir` |
| `OPKG_LISTSDIR` | (auto) | package lists directory override |
| `OPKG_TIMEOUT` | `300` | seconds for `opkg update` (needs `timeout(1)`); `0` = off |

## Graphing (Xymon server setup)

The status text contains two machine-readable lines, hidden inside an
HTML comment (the NCV parser still sees them):

```
updates : 3
critical : 1
```

Plain NCV on the server turns them into one `opkg.rrd` per host with
two datasets. The needed configuration is shipped as ready-made
drop-in files in [`server/`](server/) — copy
`server/xymonserver.d/opkg.cfg` into the server's `xymonserver.d/` and
`server/graphs.d/opkg.cfg` into its `graphs.d/`, then restart Xymon.
See [server/README.md](server/README.md).

## OpenWrt / TurrisOS

Runs through the standalone runner (see
[standalone/README.md](../../standalone/README.md)), scheduled by cron
**as root** (the default `OPKG_UPDATE=auto` writes the lists
directory):

```
*/10 * * * * /usr/lib/xymon-standalone/xymon-run.sh all
```

The extension itself is cheap; `opkg update` only actually runs when
the lists are missing or older than `OPKG_MAXAGE` hours, so a 10-minute
runner interval does not hammer the package feeds.

Dry run on the router: `/usr/lib/xymon-standalone/xymon-run.sh -n opkg`

**TurrisOS note:** Turris OS manages system upgrades through
updater-ng (`pkgupdate`), not opkg. `opkg list-upgradable` still works
and is what this extension reports; pending updater-ng approvals or
updater failures are not covered (yet).

**Portability note:** the staleness check relies on BusyBox
`date -d @epoch` and `find -newer` (`FEATURE_FIND_NEWER`), both enabled
in current OpenWrt/TurrisOS builds. If either is unavailable the check
degrades safely to "stale" (i.e. `opkg update` runs).
