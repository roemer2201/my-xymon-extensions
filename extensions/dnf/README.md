# dnf — package update status (Rocky Linux, RHEL, AlmaLinux)

Xymon client extension that reports whether a dnf-managed host has
package updates pending — the dnf counterpart of the `apt` check from
Debian's `hobbit-plugins`, and built the same way: it only **reads**
what the system already knows and never downloads anything. Reports
one status column plus eight values for RRD graphs.

- **Column:** `dnf` (override with `DNF_COLUMN`)
- **Platforms:** hosts with dnf 4. Developed and tested against
  dnf 4.20 on Rocky Linux 10. The dnf code it relies on (cache-only
  mode, exit codes, the output of `check-update` and `updateinfo`)
  reads the same in dnf 4.14, the version of EL9, but it was not run
  there; EL8 is untested. dnf5 (Fedora 41 and later) is detected and
  reports `clear`, as do hosts without dnf (Debian/Ubuntu, FreeBSD,
  OpenWrt).
- **Requires:** nothing beyond dnf itself — no root rights, no sudo
  rule, no network access. Root has to keep dnf's system cache
  current, which `dnf-makecache.timer` does on a stock EL host.
- **Note:** the `clientlaunch.d` snippet ships **enabled in the rpm
  package** and disabled everywhere else, where there is no dnf.

## What it checks

| Check | Source | Default color |
|-------|--------|---------------|
| no enabled package repository | `dnf -C repolist --enabled` | `yellow` |
| repository metadata missing or older than `DNF_MAXAGE` hours | mtime of the files in `/var/cache/dnf/<repo>-<hash>/repodata/` | `yellow` |
| security updates | `dnf -C updateinfo summary --updates --security`, `dnf -C updateinfo list --updates --security [--with-cve]` | critical, important: `red`; moderate, low, unknown: `yellow` |
| other updates | `dnf -C check-update`, minus the packages above | `yellow` |
| reboot pending | dnf's own `Security: kernel-core-… is the currently running version` lines | `yellow` |
| a dnf command fails or times out | exit code | `yellow`, "update status unknown" |
| dnf not installed, or dnf5 | — | `clear` |

Every color can be changed in [dnf.cfg](dnf.cfg); `green` keeps a
finding in the report without coloring the column, and
`DNF_REBOOT_COLOR="off"` removes the reboot check altogether.

Packages dnf does not offer — excluded in `dnf.conf` or held by the
versionlock plugin — never show up in `check-update` and so do not
count as pending. A security advisory for such a package is still
listed, marked "not offered by check-update".

### Why `-C` on every call

dnf keeps one metadata cache **per user**. Called without `-C` by the
xymon user, it downloads its own copy of all repository metadata into
`/var/tmp/dnf-<user>-*` — on every host, and again whenever it expires
(95 MB on the host this was developed on). With `-C`/`--cacheonly` an
unprivileged user reads the system cache in `/var/cache/dnf` instead
(dnf(8): "This switch allows a regular user read-only access to the
system cache"). So this extension is only as current as that cache —
which is exactly what the metadata age check watches.

If you ran `dnf` as the xymon user before, the private cache it left
behind is not used any more and can go:

```sh
rm -rf /var/tmp/dnf-xymon-*
```

(dnf recreates a small directory of that name for its log files.)

### The metadata age

libdnf takes the age of a repository from the mtime of its cached
primary metadata and touches that file on every successful refresh —
also when the metadata did not change upstream. The extension reads
the same mtime, per repository (other files in the cache do not count:
the file lists, for one, are downloaded on demand). dnf's own "Last
metadata expiration check" line only reports the *freshest*
repository, so one repository that stopped refreshing would hide
behind the others.

`DNF_MAXAGE` (default 72 hours) has to stay above the largest
`metadata_expire` of your repositories, or a repository is reported
shortly before dnf refreshes it. dnf's default is 48 hours;
`dnf repolist -v` shows the value per repository:

```sh
LC_ALL=C dnf -C repolist -v --enabled | grep -E '^Repo-(id|expire)'
```

A repository without any cache is reported by name. If dnf then
refuses to work at all (`Cache-only enabled but no cache for '…'`),
the column says "update status unknown" until root ran
`dnf makecache`.

## The status message

The message starts with an overview, so that a Xymon alert mail shows
the findings in its first lines; the package lists follow:

```
dnf: 12 security update(s) (1 critical, 11 important notice(s)), 8 other update(s), reboot pending

Rocky Linux 10.2 (Red Quartz)

Security updates pending: 12 package(s), 19 notice(s), 24 CVE(s)
&red     1 critical security notice(s) - 1 package(s)
&red    11 important security notice(s) - 6 package(s)
&yellow     6 moderate security notice(s) - 5 package(s)
&yellow     1 low security notice(s) - 0 package(s)
&yellow Other updates pending: 8 package(s)
&yellow Reboot pending: the running kernel is older than an installed kernel security update
&green Repository metadata current: 7 enabled, 0.3 to 5.9 hour(s) old (limit: 72)

Security updates (12 package(s), most severe first) - install with "dnf upgrade --security":
&red Critical  ca-certificates.noarch 2026.2.92_v9.0.319-100.3.el10_2 (baseos) - 1 notice(s), 1 CVE(s): RLSA-2026:88455
&red Important buildah.x86_64 2:1.43.1-7.el10_2 (appstream) - 3 notice(s), 4 CVE(s): RLSA-2026:63332 RLSA-2026:64777 RLSA-2026:88262
...
```

- **Notices** are security advisories (RLSA-…), counted per severity
  as `dnf updateinfo summary` counts them. **Packages** are counted
  under the worst severity among their advisories — hence "1 low
  notice, 0 packages" above: the package that notice belongs to also
  has an important one.
- A package that is several updates behind appears once, with all
  advisories in between and the number of distinct CVEs they fix.
  `DNF_SHOW_CVES="yes"` lists the CVE ids below each package.
- The whole status travels as one command line argument (128 KiB at
  most on Linux), so a report longer than 100000 bytes is cut at the
  end. The overview is at the top and always complete.

## Configuration

Every setting is an environment variable with a built-in default and
can also be set in `$XYMONHOME/etc/my-xymon-extensions/dnf.cfg`
(sourced POSIX shell; a value set there wins over the environment).
See the shipped [dnf.cfg](dnf.cfg).

| Setting | Default | Meaning |
|---------|---------|---------|
| `DNF_COLUMN` | `dnf` | Xymon column name |
| `DNF_BIN` | (auto) | dnf binary; missing → `clear` |
| `DNF_CACHEDIR` | `/var/cache/dnf` | dnf's system cache |
| `DNF_MAXAGE` | `72` | hours before cached metadata counts as stale; `0` = no age check |
| `DNF_TIMEOUT` | `120` | seconds per dnf call (needs `timeout(1)`); `0` = off |
| `DNF_LIFETIME` | `30` | status validity in minutes (see below) |
| `DNF_UPDATES_COLOR` | `yellow` | updates without a security advisory |
| `DNF_SEC_CRITICAL_COLOR` | `red` | critical security advisories |
| `DNF_SEC_IMPORTANT_COLOR` | `red` | important security advisories |
| `DNF_SEC_MODERATE_COLOR` | `yellow` | moderate security advisories |
| `DNF_SEC_LOW_COLOR` | `yellow` | low security advisories |
| `DNF_SEC_UNKNOWN_COLOR` | `yellow` | security advisories without a severity (EPEL) |
| `DNF_REBOOT_COLOR` | `yellow` | running kernel older than an installed security update; `off` = no check |
| `DNF_SHOW_CVES` | `no` | `yes`: list every CVE id below its package |

## Poll interval and cost

The task runs every 5 minutes, like the `apt` and `yum` checks of
hobbit-plugins. That is what the graphs need: Xymon's RRD files expect
a value at least every 10 minutes, a longer interval leaves gaps.

A run starts dnf three times while nothing is pending (`--version`,
`repolist`, `check-update`) and six times while updates are pending
(the three `updateinfo` queries on top). Each start loads the cached
metadata of all enabled repositories. If that is too much for a
compute node, raise `INTERVAL` in `clientlaunch.d/dnf.cfg` **and**
`DNF_LIFETIME` to more than the new interval — the column works as
before, only the graphs get gaps. The `xymonext` column shows what the
test actually costs on a host.

## Graphing (Xymon server setup)

Together with the status, the extension sends a `data` message with
eight values (none when the update status is unknown):

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

Plain NCV on the server turns them into one `dnf.rrd` per host. The
needed configuration is shipped as ready-made drop-in files in
[`server/`](server/) — copy `server/xymonserver.d/dnf.cfg` into the
server's `xymonserver.d/` and `server/graphs.d/dnf.cfg` into its
`graphs.d/`, then restart Xymon. On a Debian/Ubuntu Xymon server the
`my-xymon-extensions-server` package installs both. See
[server/README.md](server/README.md).

## Not covered

- **dnf5** and **yum 3** (EL7) — other commands and output formats.
- Packages that were not installed from a repository, and broken or
  half-installed packages (the `apt` check lists both).
- Services that still run old code after an update
  (`dnf needs-restarting`); only the kernel is covered, through dnf's
  own check.

## Dry run

Without the Xymon environment the script prints its messages instead
of sending them:

```sh
sh "$XYMONCLIENTHOME/ext/dnf.sh"
```
