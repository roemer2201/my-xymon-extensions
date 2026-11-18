# dnf — package update status (Rocky Linux, RHEL, AlmaLinux)

Xymon client extension that reports whether a dnf-managed host has
package updates pending — the dnf counterpart of the `apt` check from
Debian's `hobbit-plugins`, and built the same way: it only **reads**
what the system already knows and never downloads anything. Reports
one status column plus eight values for RRD graphs.

- **Column:** `dnf` (override with `DNF_COLUMN`)
- **Platforms:** hosts with dnf 4. Developed against dnf 4.20 on
  Rocky Linux 10; CI runs it against the real dnf and repositories of
  Rocky Linux 9 and 10. EL8 is untested. dnf5 (Fedora 41 and later) is
  detected and reports `clear`, as do hosts without dnf (Debian/Ubuntu,
  FreeBSD, OpenWrt).
- **Requires:** nothing beyond dnf itself — no root rights, no sudo
  rule, no network access. Root has to keep dnf's system cache
  current, which `dnf-makecache.timer` does on a stock EL host.
- **Note:** the `clientlaunch.d` snippet ships **enabled in the rpm
  package** and disabled everywhere else, where there is no dnf.

## What it checks

| Check | Source | Default color |
|-------|--------|---------------|
| no enabled package repository | `dnf -C repolist --enabled` | `yellow` |
| repository metadata missing or older than `DNF_MAXAGE` hours | mtime of the cached primary metadata in `/var/cache/dnf/<repo>-<hash>/repodata/` | `yellow`; missing: results marked incomplete |
| security updates | `dnf -C updateinfo summary --updates --security`, `dnf -C updateinfo list --updates --security [--with-cve]` | critical, important: `red`; moderate, low, unknown: `yellow` |
| other updates | `dnf -C check-update`, minus the packages above | `yellow` |
| reboot pending | dnf's own `Security: kernel-core-… is the currently running version` lines | `yellow` |
| a dnf command fails or times out, or its output cannot be read | exit code, package rows | `yellow`, "update status unknown" |
| dnf not installed, or dnf5 | — | `clear` |

Every color can be changed in [dnf.cfg](dnf.cfg); `green` keeps a
finding in the report without coloring the column, and
`DNF_REBOOT_COLOR="off"` removes the reboot check altogether.

A package excluded in `dnf.conf` (`excludepkgs`) is invisible here:
dnf then lists neither its update nor its security advisories
(observed with dnf 4.20), so nothing about it is pending. If DNF
returns a security advisory for a package that `check-update` did not
list, the advisory still appears, marked "not offered by
check-update". An update listed by `check-update` is a candidate;
DNF can still rule it out when resolving an upgrade transaction.

`check-update` ends with an "Obsoleting Packages" section: pairs of a
package that obsoletes an installed one and, indented below it, the
installed package. A package that replaces another one under a new
name counts as an update. Some packages obsolete older builds of their
own name (seen with the kmod packages of the CentOS Kmods SIG); dnf
then pairs installed builds with themselves and exits with 100,
although `dnf upgrade` has nothing to do. Each pair is therefore
checked on its own: it is no update if the obsoleting package is
already installed (repository `@…`) or identical to the package below
it (same `name.arch` and `[epoch:]version-release`). Wrapped rows are
reassembled before comparison. A package counts once as soon as one of
its pairs is an update. If all pairs are skipped and no other updates
are found, the column reports "packages up to date".

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

A repository without cached primary metadata is reported by name.
If DNF skips it, the column marks the results as incomplete and still
shows any updates it found. No graph data is sent for that run. If
DNF refuses to work at all (`Cache-only enabled but no cache for '…'`),
the column says "update status unknown". Run `dnf makecache` as root
to rebuild missing metadata.

### How soon a new advisory shows up

The extension sees what root's cache holds, so a new advisory appears
in the column only after dnf has refreshed that repository. On EL the
refresh is `dnf makecache --timer`, started by `dnf-makecache.timer`
(dnf 4.20.0: `OnBootSec=10min`, `OnUnitInactiveSec=1h`,
`RandomizedDelaySec=60m`). That command does real work at most every
`metadata_timer_sync` (dnf.conf, default 3 hours; otherwise "Metadata
cache refreshed recently") and then refreshes every repository whose
metadata has expired **or expires within that period**
(`update_cache()` in `dnf/base.py`). Roughly:

```
delay  <=  mirror sync  +  metadata_expire of the repository
           +  timer slack (up to ~2 h: 1 h inactive + 60 min random)
           +  the poll interval of this test (5 min)
```

Often it is less, because a repository is refreshed up to
`metadata_timer_sync` before it expires. Measured on Rocky Linux 10.3
(`dnf config-manager --dump`, `systemctl cat dnf-makecache.timer`):
`baseos` and `appstream` with `metadata_expire = 21600` (6 h), `epel`
with `86400` (24 h) - so up to about 7-8 hours for a Rocky advisory and
about 25-26 hours for an EPEL one.

To see security advisories sooner, lower `metadata_expire` for the
repositories that carry them (`dnf config-manager --save
--setopt=baseos.metadata_expire=7200`, in seconds, or the line in the
`.repo` file), and with it `metadata_timer_sync` in
`/etc/dnf/dnf.conf`: as long as that stays at 3 hours, the timer
refreshes no more often than that. The price is
network traffic: every refresh asks the mirror for the repository's
`repomd.xml`, and downloads the metadata again whenever it changed.
Keep `DNF_MAXAGE` above the largest `metadata_expire` either way.

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
| `DNF_REUSE` | `60` | minutes dnf's answers may be reused while nothing changed (see below); `0` = ask dnf every run |
| `DNF_REUSE_WATCH` | `/etc/dnf /etc/yum.repos.d /etc/distro.repos.d /var/lib/rpm /usr/lib/sysimage/rpm` | a change below these paths means "ask dnf again" |

## Poll interval and cost

The task runs every 5 minutes, like the `apt` and `yum` checks of
hobbit-plugins. That is what the graphs need: Xymon's RRD files expect
a value at least every 10 minutes, a longer interval leaves gaps.

A run that asks dnf starts it three times while nothing is pending
(`--version`, `repolist`, `check-update`) and six times while updates
are pending (the three `updateinfo` queries on top); `check-update`
and `updateinfo` load the cached metadata of all enabled repositories.
On a Rocky Linux 10.3 host with 9 repositories including EPEL that
took about 8 s wall clock and 7.6 s CPU (`xymonext`).

Their answers only change when root refreshes the cache, a package is
installed or removed, the dnf configuration changes or the host
reboots. So a run reuses the answers of `check-update` and
`updateinfo` from an earlier run - at most `DNF_REUSE` minutes old
(60) - while all of this holds:

- same dnf version, same enabled repositories, same mtime of each
  repository's primary metadata (a refresh touches it, see "The
  metadata age"), same dnf binary and cache directory;
- same boot id (`/proc/sys/kernel/random/boot_id`), so dnf's
  running-kernel check is redone after a reboot;
- nothing below `DNF_REUSE_WATCH` - the dnf configuration, the repo
  files and the rpm database - is newer than the saved answers; a new
  or deleted file changes its directory's mtime.

Only the answers are reused: `--version` and `repolist` still run, and
the report - colors, metadata age, overview, `data` message - is built
anew every time. A reused run says so at the end of the status. The
answers are kept in `$XYMONTMP/dnf-reuse.<column>`, written under a
temporary name and renamed; a failed dnf call leaves nothing to reuse,
and a missing or damaged file just means dnf is asked. Set
`DNF_REUSE=0` to ask dnf on every run.

If even that is too much for a compute node, raise `INTERVAL` in
`clientlaunch.d/dnf.cfg` **and** `DNF_LIFETIME` to more than the new
interval — the column works as before, only the graphs get gaps. The
`xymonext` column shows what the test actually costs on a host.

## Graphing (Xymon server setup)

Together with the status, the extension sends a `data` message with
eight values. It sends none while the update status is unknown or
incomplete - a dnf command failed, or an enabled repository has no
cached primary metadata - so the graphs show a gap instead of counts
that leave a repository out:

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

To run it exactly as the xymon user sees it, with nothing but the
variables xymonlaunch would set (`XYMON`/`XYMSRV` unset: nothing is
sent):

```sh
sudo -u xymon env -i PATH=/usr/bin:/usr/sbin XYMONHOME=<client> \
    XYMONTMP=<client>/tmp MACHINE=<host> sh <client>/ext/dnf.sh
```

## Verifying on a real host

A pending security update can be produced on purpose, without touching
anything the host depends on:

1. Pick a **leaf package** (nothing else requires it) that has a
   security advisory in the current repositories:
   `dnf repoquery --installed --whatrequires <pkg>` prints nothing, and
   `dnf -q updateinfo list --security --all <pkg>` lists an advisory.
2. Fetch an older, **signed** build of it from the distribution's
   archive (Rocky Linux: the vault of an earlier minor release), and
   check the signature: `rpm -K <pkg>.rpm` must report
   `digests signatures OK`.
3. Downgrade: `dnf downgrade ./<pkg>.rpm`.
4. Run the test (see [Dry run](#dry-run)) and compare its counts with
   `dnf -C -q updateinfo list --updates --security --with-cve`: the
   package, its severity, the advisory and the number of distinct CVEs
   must agree.
5. Put the package back: `dnf upgrade <pkg>`.

Verified this way on Rocky Linux 10.3: `wget-1.24.5-5.el10` from the
Rocky Linux 10.1 vault was reported as one moderate security update
(RLSA-2026:62142, 2 CVEs), with the same counts as `dnf updateinfo`.

Stale and missing metadata need no change to the real cache: point
`DNF_CACHEDIR` at a stand-in that has the same directory names, with
aged primary metadata, and leave one repository out:

```sh
mkdir /tmp/dnfcache
for d in /var/cache/dnf/*-*/repodata; do
    r=${d%/repodata}; mkdir -p "/tmp/dnfcache/${r##*/}/repodata"
    touch -d '4 days ago' "/tmp/dnfcache/${r##*/}/repodata/primary.xml.zck"
done
rm -r /tmp/dnfcache/<repo id>-*     # one repository without metadata
DNF_CACHEDIR=/tmp/dnfcache sh <client>/ext/dnf.sh
```

The column turns yellow, names every repository as too old and the
missing one as without metadata, marks the result "partial results"
and sends no `data` message. dnf itself still reads the real cache, so
the update lists stay as they are.
