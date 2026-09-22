# RPM spec for my-xymon-extensions.
#
# Default layout matches the Terabithia xymon-client builds
# (XYMONHOME=/usr/lib64/xymon/client). Override at build time for other
# layouts, e.g.:
#   rpmbuild ... --define 'xymonhome /usr/share/xymon-client'
%{!?xymonhome: %global xymonhome /usr/lib64/xymon/client}

Name:           my-xymon-extensions
Version:        %{?pkgver}%{!?pkgver:0.0.0}
Release:        1%{?dist}
Summary:        Portable Xymon client extensions
License:        TBD
URL:            https://github.com/roemer2201/my-xymon-extensions
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch
Requires:       smartmontools
Recommends:     curl
# "xymon-client" matches the Terabithia and EPEL package names;
# rebuild with --define 'xymonclientpkg <name>' for other builds.
%{!?xymonclientpkg: %global xymonclientpkg xymon-client}
Requires:       %{xymonclientpkg}

%description
Custom monitoring tests (extensions) for the Xymon systems monitor.

Included extensions:
* smart - S.M.A.R.T. disk health monitoring for SATA/ATA, NVMe and
  basic SAS disks, plus eMMC wear/pre-EOL health (via mmc-utils),
  with vendor-normalized metrics, thresholds and per-disk RRD
  graphing support.
* temp - all hardware temperature sensors from the Linux
  hwmon/thermal sysfs, per-sensor thresholds and RRD graphing.
* la - load average with per-CPU-core thresholds (task disabled by
  default: the Xymon client already covers this on full clients).
* memory - memory utilization in percent (task disabled by default:
  the Xymon client already covers this on full clients).
* disk - filesystem usage from df with global and per-mount
  thresholds, reporting into the standard "disk" column for
  clientless hosts (task disabled by default: the Xymon client
  already covers this on full clients).
* opkg - pending package updates on opkg-based systems
  (OpenWrt/TurrisOS; task disabled by default: hosts with a full
  Xymon client have no opkg).
* fritzdsl - AVM FRITZ!Box DSL line monitoring via TR-064 (curl):
  line state, sync rate, noise margin, attenuation and error counters
  with thresholds and RRD graphing support; polls the box from the
  Xymon server, no software on the box.
* fritzwan - AVM FRITZ!Box WAN throughput monitoring (curl): physical
  link state, average throughput, link capacity and utilization from
  the box's 64-bit UPnP counters (TR-064 fallback), with optional
  utilization thresholds and RRD graphs.
* wifi - Wi-Fi access point metadata via iw/nl80211 (task disabled by
  default: full clients are rarely APs): client counts, channel
  utilization, airtime, throughput, TX retries and noise floor with
  RRD graphing; informational only.
* if_link - network interface link state changes from the kernel's
  carrier counters: counts every link down/up transition per port,
  including short flaps between two polls, with optional per-port
  thresholds and RRD graphs; Linux-only, green until thresholds are
  configured.
* xymonext - what the extensions above cost this host: wall clock
  time, CPU time and the number of bytes each test sends to the
  Xymon server, measured on every run and reported in one
  "xymonext" column with RRD graphs per test. The clientlaunch.d
  snippets call the extensions through its wrapper; measuring can be
  turned off in xymonext.cfg.

%prep
%setup -q

%install
sh packaging/common/stage.sh "%{buildroot}" \
    "%{xymonhome}/ext" \
    "%{xymonhome}/etc" \
    "%{xymonhome}/etc/clientlaunch.d" \
    "%{_docdir}/%{name}"

%files
%{xymonhome}/ext/smart.sh
%{xymonhome}/ext/temp.sh
%{xymonhome}/ext/la.sh
%{xymonhome}/ext/memory.sh
%{xymonhome}/ext/disk.sh
%{xymonhome}/ext/opkg.sh
%config(noreplace) %{xymonhome}/etc/my-xymon-extensions/smart.cfg
%config(noreplace) %{xymonhome}/etc/my-xymon-extensions/temp.cfg
%config(noreplace) %{xymonhome}/etc/my-xymon-extensions/la.cfg
%config(noreplace) %{xymonhome}/etc/my-xymon-extensions/memory.cfg
%config(noreplace) %{xymonhome}/etc/my-xymon-extensions/disk.cfg
%config(noreplace) %{xymonhome}/etc/my-xymon-extensions/opkg.cfg
%dir %{xymonhome}/etc/my-xymon-extensions
%dir %{xymonhome}/etc/clientlaunch.d
%config(noreplace) %{xymonhome}/etc/clientlaunch.d/smart.cfg
%config(noreplace) %{xymonhome}/etc/clientlaunch.d/la.cfg
%config(noreplace) %{xymonhome}/etc/clientlaunch.d/memory.cfg
%config(noreplace) %{xymonhome}/etc/clientlaunch.d/disk.cfg
%config(noreplace) %{xymonhome}/etc/clientlaunch.d/opkg.cfg
%{xymonhome}/ext/fritzdsl.sh
%config(noreplace) %{xymonhome}/etc/my-xymon-extensions/fritzdsl.cfg
%config(noreplace) %{xymonhome}/etc/clientlaunch.d/fritzdsl.cfg
%{xymonhome}/ext/fritzwan.sh
%config(noreplace) %{xymonhome}/etc/my-xymon-extensions/fritzwan.cfg
%config(noreplace) %{xymonhome}/etc/clientlaunch.d/fritzwan.cfg
%{xymonhome}/ext/wifi.sh
%config(noreplace) %{xymonhome}/etc/my-xymon-extensions/wifi.cfg
%config(noreplace) %{xymonhome}/etc/clientlaunch.d/wifi.cfg
%{xymonhome}/ext/if_link.sh
%config(noreplace) %{xymonhome}/etc/my-xymon-extensions/if_link.cfg
%config(noreplace) %{xymonhome}/etc/clientlaunch.d/if_link.cfg
%{xymonhome}/ext/lxc.sh
%config(noreplace) %{xymonhome}/etc/my-xymon-extensions/lxc.cfg
%config(noreplace) %{xymonhome}/etc/clientlaunch.d/lxc.cfg
%{xymonhome}/ext/claude.sh
%{xymonhome}/ext/claude-expiry.sh
%config(noreplace) %{xymonhome}/etc/my-xymon-extensions/claude.cfg
%config(noreplace) %{xymonhome}/etc/clientlaunch.d/claude.cfg
%{xymonhome}/ext/xymonext.sh
%{xymonhome}/ext/xymonext-send.sh
%config(noreplace) %{xymonhome}/etc/my-xymon-extensions/xymonext.cfg
%{_docdir}/%{name}/

%pre
# Up to 0.19.0 the config files sat straight in etc/, 0.20.0 moved them
# to etc/my-xymon-extensions/ - and on rpm migrated nothing: the package
# installed fresh defaults in the new place, which the extensions read
# in preference, and the upgrade renamed an edited old file to .rpmsave.
# Note which files in the new place may be replaced with the admin's
# copy: those that do not exist yet (rpm is about to create them from
# the package) and those the installed package reports as unmodified.
# The move itself happens in posttrans, once rpm is done with the old
# files. Nothing here may fail the installation.
state=%{_localstatedir}/lib/rpm-state/%{name}
new=%{xymonhome}/etc/my-xymon-extensions
rm -rf "$state"
mkdir -p "$state" || exit 0
: > "$state/replaceable"
verify=""
if [ "$1" -ge 2 ]; then
    verify=$(rpm -V --nodeps %{name} 2>/dev/null)
fi
for cfg in smart temp la memory disk opkg fritzdsl fritzwan wifi \
    if_link lxc claude xymonext; do
    if [ ! -e "$new/$cfg.cfg" ]; then
        echo "$cfg" >> "$state/replaceable"
    elif [ "$1" -ge 2 ] && ! echo "$verify" | grep -q " $new/$cfg.cfg\$"; then
        echo "$cfg" >> "$state/replaceable"
    fi
done
exit 0

%posttrans
# Second half of the migration prepared in pre. The admin's copy is the
# old file if it is still there (never owned by rpm, e.g. a tarball
# install) or the .rpmsave the upgrade made of an edited one; an
# unmodified old file is gone by now and needs nothing. It replaces the
# new file only where pre allowed it - an edited new file is never
# overwritten, the admin is told instead.
state=%{_localstatedir}/lib/rpm-state/%{name}
old=%{xymonhome}/etc
new=%{xymonhome}/etc/my-xymon-extensions
for cfg in smart temp la memory disk opkg fritzdsl fritzwan wifi \
    if_link lxc claude xymonext; do
    if [ -f "$old/$cfg.cfg.rpmsave" ]; then
        src="$old/$cfg.cfg.rpmsave"
    elif [ -f "$old/$cfg.cfg" ]; then
        src="$old/$cfg.cfg"
    else
        continue
    fi
    dst="$new/$cfg.cfg"
    if [ -f "$dst" ] && [ "$(cksum < "$src")" = "$(cksum < "$dst")" ]; then
        rm -f "$src"
    elif [ ! -f "$dst" ] || grep -qx "$cfg" "$state/replaceable" 2>/dev/null; then
        mkdir -p "$new"
        if [ -f "$dst" ]; then
            mv -f "$dst" "$dst.rpmnew"
        fi
        if mv -f "$src" "$dst"; then
            echo "my-xymon-extensions: moved your $src to $dst"
        fi
    else
        echo "my-xymon-extensions: WARNING: $src and $dst are both"
        echo " edited; only the latter is read. Merge, then delete $src."
    fi
done
rm -rf "$state"
exit 0

%post
cat <<'EOF'
my-xymon-extensions: the per-extension configuration lives in
 %{xymonhome}/etc/my-xymon-extensions/ (up to 0.19.0 it sat straight
 in %{xymonhome}/etc). A config you had edited in the old place is
 moved over at the end of this transaction; the package default is
 then kept next to it as <name>.cfg.rpmnew.
To activate the "smart" extension:
 1. Grant the xymon user access to smartctl - see
    %{_docdir}/%{name}/smart/sudoers.example
 2. Make sure clientlaunch.cfg loads the client drop-in directory
    (add this line once if it is missing):
      directory %{xymonhome}/etc/clientlaunch.d
    NOTE: up to version 0.14.0 the snippets went to etc/tasks.d and
    that is what the line said. tasks.d belongs to the SERVER's
    xymonlaunch (tasks.cfg) - on a host that is server and client,
    a snippet there is picked up by both launchers and the extension
    runs twice. Point the line at clientlaunch.d and delete any
    leftovers in etc/tasks.d (rpm keeps edited ones as .rpmsave).
 3. Restart the Xymon client service.
The FRITZ!Box extensions "fritzdsl" and "fritzwan" ship disabled:
 configure %{xymonhome}/etc/my-xymon-extensions/fritzdsl.cfg resp. fritzwan.cfg, then
 remove the DISABLED line from the matching clientlaunch.d snippet
 and restart the client on the polling host (normally the Xymon
 server).
The "wifi" extension ships disabled too: enable it (remove the
 DISABLED line from the clientlaunch.d snippet) only on a Linux
 access point with iw installed.
The "if_link" extension (link state changes per network interface)
 is active out of the box and adds an "if_link" column. It stays
 green until you configure thresholds in %{xymonhome}/etc/my-xymon-extensions/if_link.cfg.
The "lxc" extension ships disabled: on an LXC host, remove the
 DISABLED line from %{xymonhome}/etc/clientlaunch.d/lxc.cfg. Which
 containers are supposed to run is detected automatically
 (lxc.start.auto, /etc/config/lxc-auto, lxc-autostart); LXC_REQUIRED
 in %{xymonhome}/etc/my-xymon-extensions/lxc.cfg overrides that with an explicit list.
The "claude" extension ships disabled: it reports how much longer the
 Claude Code login of an account is valid (yellow 10 days before it
 expires, red 5 days). The credentials file is mode 0600 in a private
 home directory, so allow the xymon user to run the reader as root -
 see %{_docdir}/%{name}/claude/sudoers.example, which ships one line
 for the "root" account - list the accounts to check in
 CLAUDE_ACCOUNTS in %{xymonhome}/etc/my-xymon-extensions/claude.cfg and uncomment the task
 in %{xymonhome}/etc/clientlaunch.d/claude.cfg.
Every task now runs through %{xymonhome}/ext/xymonext.sh, which
 measures the extension and adds an "xymonext" column with runtime,
 CPU time and traffic per test. Set XYMONEXT_ENABLE="no" in
 %{xymonhome}/etc/my-xymon-extensions/xymonext.cfg to run the extensions directly again.
RRD graphs need a one-time setup on the Xymon SERVER (not here):
 ready-made drop-in files for its xymonserver.d, graphs.d and
 rrddefinitions.d directories ship in
 %{_docdir}/%{name}/<extension>/server/ - copy them over and restart
 Xymon there; see the README.md next to them.
EOF

%changelog
* Tue Sep 22 2026 roemer2201 <r.oliver@web.de> - 0.23.1-1
- the config move of 0.20.0 now actually keeps edited settings on rpm.
  Up to 0.23.0 the package installed fresh defaults in
  etc/my-xymon-extensions/, the extensions read those in preference,
  and the upgrade renamed an edited etc/<name>.cfg to .rpmsave - so the
  extension silently ran on its defaults, contrary to what the 0.20.0
  post-install text said. %pre now notes which new files may be
  replaced (not there yet, or unmodified according to rpm -V), and
  %posttrans moves the edited old file or its .rpmsave over them,
  keeping the package default as .rpmnew. Hosts that already went
  through 0.20.0-0.23.0 are repaired by this upgrade as well; where
  both files were edited nothing is overwritten and a warning names
  them. FreeBSD and opkg get the same migration in their install
  scripts
- the config file headers and the claude launch snippet named the old
  $XYMONHOME/etc/<name>.cfg path
- server package (deb only): the build shipped postinst but not preinst
  and postrm, so its dpkg-maintscript-helper conffile migrations never
  ran their preinst half
- server package, powerline: the collector config is no longer included
  into xymonserver.cfg - as environment it silently overrode every
  --config; the task passes --config instead. The privileged helper gets
  /dev/null as stdin. An adapter absent for POWERLINE_RETENTION_DAYS
  (default 30) is forgotten, so state and messages stop growing. Every
  status carries a legend for PB, MPDU and BER

* Tue Sep 22 2026 roemer2201 <r.oliver@web.de> - 0.23.0-1
- no change to this package. The server package restructures the powerline
  status-page graphs: two catch-all patterns became fifteen specific ones,
  so one graph now carries one metric family at one order of magnitude.
  Before this, ".+_(?:pass|fail|ack|collision)" put 38 series into a single
  graph whose BER sums in the millions flattened every MPDU counter onto the
  zero line, and ".+_(?:reported|interval)_pct" re-drew all 16 series the
  specific ratio graphs already showed. The same over-broad matching left 28
  per-second RRDs per adapter pair - every slot and ALL rate - written for
  months and drawn by nothing, because the rate pattern only ever matched
  rx_pb_*. The series counts are per adapter pair and multiply with each
  further peer, so the split is finer than one pair needs

* Tue Sep 22 2026 roemer2201 <r.oliver@web.de> - 0.22.0-1
- no change to this package. The server package gains the sudo rule for
  the powerline collector as a real conffile,
  /etc/sudoers.d/my-xymon-extensions-server, installed with the rule
  commented out; powerline ships disabled, so the privilege is not
  granted before the admin asks for it. The client package keeps
  shipping its two sudoers files (smart, claude) as documentation only:
  it runs on Debian, Rocky, FreeBSD and OpenWrt with four different
  helper paths, and the claude rule needs one line per account, so a
  single installable file would be either wrong or too permissive

* Tue Sep 22 2026 roemer2201 <r.oliver@web.de> - 0.21.1-1
- packaging: the build scripts are executable again. Four of the five
  packaging/*/build.sh carried the execute bit and the server one did
  not, so running ./packaging/deb-server/build.sh on a build host first
  needed a chmod +x. That uncommitted mode change then made git pull
  refuse the merge, the tree stayed on an older commit, and the package
  built from it carried that older version - which from the outside
  looks exactly like a forgotten version bump. stage-server.sh and
  tests/powerline/run.sh were missing the same bit
- tests: the packaging section pins both halves of that failure now.
  Every .sh file in the repository must be executable, and the newest
  %changelog entry here must match the VERSION file. A release that
  forgets either one fails "make test" instead of surprising someone on
  the build host

* Tue Sep 22 2026 roemer2201 <r.oliver@web.de> - 0.21.0-1
- no change to this package. The version follows the repository-wide
  VERSION file, which 0.21.0 moved for the new server-only powerline
  collector; that one ships exclusively in my-xymon-extensions-server
  (tasks.d, the server's ext/ and the my-xymon-extensions-server config
  directory), so the client package is identical to 0.20.0-1. This
  entry was missing from the 0.21.0 release and is recorded here

* Mon Sep 21 2026 roemer2201 <r.oliver@web.de> - 0.20.0-1
- the per-extension config files move out of the shared Xymon etc
  directory into one of this package's own:
  $XYMONHOME/etc/my-xymon-extensions/<name>.cfg. On Debian/Ubuntu
  /etc/xymon belongs to the Xymon client, the Xymon server AND
  hobbit-plugins at the same time, and thirteen files with names like
  memory.cfg, disk.cfg or temp.cfg sat in the middle of it - a
  collision waiting to happen (hobbit-plugins already ships a temp.yaml
  there, and its temp plugin collided with ours in three drop-in
  directories before). The launch snippets stay in clientlaunch.d:
  that one is Xymon's own drop-in directory and has to be. Every
  extension reads the new location first and falls back to the old
  path, so a file left behind - on rpm and FreeBSD, where nothing is
  moved for you, or on a host installed from the tarball - keeps being
  used instead of silently reverting the extension to its defaults.
  The deb moves the files with dpkg-maintscript-helper, edits
  included, chained after the 0.14.0/0.16.0 migrations
- standalone runner: claude-expiry.sh is no longer picked up as an
  extension when TESTS is empty (the "run everything installed" mode).
  It is the privileged reader of the claude extension, called with an
  account name; run on its own it prints its usage and exits non-zero,
  which would have shown up as a failing test

* Mon Sep 21 2026 roemer2201 <r.oliver@web.de> - 0.19.0-1
- claude: new extension - validity of the Claude Code login in one
  "claude" column. Of the two timestamps in
  $HOME/.claude/.credentials.json only refreshTokenExpiresAt says how
  long the login lasts; the access token in expiresAt is renewed
  automatically whenever Claude runs, so an expired one is normal on
  an idle host and is reported as information only. Yellow at 10 days
  left, red at 5 (CLAUDE_WARN/CLAUDE_CRIT), which is the point: a
  headless session - claude --remote-control in a service, a cron job,
  an agent - dies silently when the refresh token expires, and the
  repair is an interactive "claude /login" on the host. Several
  accounts per host are supported (CLAUDE_ACCOUNTS), since the login
  is per user. The file is mode 0600 in a private home directory, so
  reading it is confined to claude-expiry.sh, which is called through
  sudo, takes a user NAME rather than a path - so the sudoers rule
  pins the accounts that may be queried - and prints the two
  timestamps and the subscription type, never token material. Hosts
  without a login report "clear", not red, and so does a missing sudo
  rule; ships disabled

* Fri Aug 21 2026 roemer2201 <r.oliver@web.de> - 0.18.0-1
- lxc: new extension - LXC container status and resource usage in one
  "lxc" column. Which containers are supposed to run is derived from
  the three places the host itself uses, so nothing is configured
  twice: lxc.start.auto (the AUTOSTART column of lxc-ls), the OpenWrt
  UCI list /etc/config/lxc-auto - whose init script starts containers
  without lxc.start.auto, so the flag alone misses them - and
  lxc-autostart -L, which lists only containers it would start now and
  is therefore empty on a healthy host, never a complete list on its
  own. A container from that set that is not running turns the column
  red, every other stopped container is green and marked "not
  autostarted"; LXC_REQUIRED/LXC_OPTIONAL/LXC_IGNORE override the
  detection. Per container it graphs memory, CPU and network traffic
  through split-NCV, i.e. one RRD file per container and metric, so
  creating or destroying a container never disturbs an existing graph.
  CPU comes from the cgroup's cpu.stat (cpuacct.usage on cgroup v1),
  the cgroup being located through the container's init process rather
  than by guessing a path; memory from memory.current, with a fallback
  that sums the RSS of the container processes from /proc in a single
  awk pass - needed on OpenWrt/TurrisOS, where no controller is
  delegated to the container cgroups, so memory.current is missing or
  reads 0 and lxc-ls -F RAM shows 0.00MB; traffic from the counters of
  lxc-info (optional package), reported from the container's point of
  view - lxc-info measures the host side of the veth pair, where TX is
  what goes INTO the container. Ships disabled on full clients and is
  in the default TESTS list of the standalone runner
- every extension now forces LC_ALL=C. awk formats floating point
  numbers according to LC_NUMERIC, so an extension that inherited a
  locale such as de_DE - through an ENVFILE, a systemd unit or a cron
  environment - sent its metrics as "14,9". The server's NCV parser
  drops those silently: the affected graphs simply stay empty, with
  nothing in any log to say why. Numbers in the status text were
  affected the same way. Reproduced with the test suite, which failed
  71 of its assertions under de_DE.UTF-8 and passes under any locale
  now

* Mon Aug 10 2026 roemer2201 <r.oliver@web.de> - 0.17.0-1
- revert the 0.16.0 file naming: the drop-ins keep their plain
  <extension>.cfg names. Instead of renaming everything for one clash,
  the packages simply do not install the three paths Debian's
  hobbit-plugins already owns - clientlaunch.d/temp.cfg,
  graphs.d/temp.cfg and xymonserver.d/temp.cfg. Those three files ship
  as documentation (<docdir>/temp/clientlaunch.d/ and
  <docdir>/temp/server/) and are copied in by hand; everything else is
  installed as before. On rpm/FreeBSD the clash does not exist, but the
  layout is kept identical across platforms so the documentation is
  the same everywhere
- temp: the graph section is [temp] again (the 0.16.0 rename to
  [tempext] is reverted). extensions/temp/server/README.md now spells
  out the three cases - hobbit-plugins absent, present but its temp
  plugin unused (the normal one: overwrite its two files), or actually
  in use (give this extension its own column via TEMP_COLUMN) - plus
  the TEST2RRD="temp=ncv,$TEST2RRD" form that makes the mapping
  independent of the drop-in read order
- deb: existing installations are migrated with
  dpkg-maintscript-helper, chained over all previous layouts
  (tasks.d -> clientlaunch.d -> prefixed -> plain), and the temp
  snippet is removed from the package with rm_conffile - an edited one
  is kept as .dpkg-bak. The post-install of both packages says what to
  copy where for temp

* Mon Aug 10 2026 roemer2201 <r.oliver@web.de> - 0.16.0-1
- packaging: every file installed into one of Xymon's shared drop-in
  directories is now named my-xymon-extensions-<extension>.cfg. Those
  directories belong to no single package: hobbit-plugins ships a
  temp.cfg in clientlaunch.d, graphs.d and xymonserver.d, so installing
  the server package on a host with hobbit-plugins failed outright
  ("trying to overwrite /etc/xymon/graphs.d/temp.cfg, which is also in
  package hobbit-plugins"), and the client package would have hit the
  same wall in clientlaunch.d
- temp: the graph section is renamed [temp] -> [tempext] and
  GRAPHS/GRAPHS_temp follow. hobbit-plugins defines a [temp] graph of
  its own reading a dataset named "temp" where split-NCV writes
  "lambda"; with two sections of one name the file parsed last wins
  silently, so the two definitions had to stop sharing a name (same
  reason la uses [laext]). Its xymonserver.d entry TEST2RRD=,temp also
  competes with ours: TEST2RRD is first-match-wins and their "temp"
  maps the column to an RRD module xymond_rrd does not have - i.e. no
  RRD at all - so ours has to be read first, which the file name now
  guarantees (drop-ins are read alphabetically). Both packages can be
  installed side by side again; the server package's post-install says
  what to do when hobbit-plugins' temp plugin is actually in use
- the deb packages migrate the old file names with
  dpkg-maintscript-helper mv_conffile, chained after the 0.15.0 move
  out of tasks.d, so local modifications survive both hops. New test:
  nothing may be installed into a shared drop-in directory without the
  package prefix

* Mon Aug 10 2026 roemer2201 <r.oliver@web.de> - 0.15.0-1
- packaging: the xymonlaunch snippets move from the Xymon server's
  drop-in directory tasks.d to the client's clientlaunch.d, where they
  belong. tasks.d is read by the SERVER's xymonlaunch (its tasks.cfg),
  clientlaunch.d by the client's - and on Debian the server's tasks.cfg
  includes the client's list as well, while the client's init exits
  when xymond is installed, so exactly one xymonlaunch runs per host.
  Consequence of the old location: on a host that is server and client,
  a snippet in tasks.d was picked up by the server's launcher, and once
  more through the "directory /etc/xymon/tasks.d" line the package used
  to ask admins to add to clientlaunch.cfg - the extension ran twice.
  In the new location nothing has to be added on Debian/Ubuntu at all,
  since the init script generates the include list for clientlaunch.d
  itself. The deb migrates existing files with dpkg-maintscript-helper
  mv_conffile (preinst/postinst/postrm), keeping local modifications,
  and its post-install points out a leftover tasks.d line in
  clientlaunch.cfg. On rpm an edited old snippet under etc/tasks.d is
  left behind as .rpmsave and can be deleted; the new files are at
  etc/clientlaunch.d. The snippet sources moved to
  packaging/common/clientlaunch.d/ accordingly; no extension script
  changed

* Mon Aug 10 2026 roemer2201 <r.oliver@web.de> - 0.14.0-1
- new package my-xymon-extensions-server (.deb only for now): installs
  the server-side drop-in configuration of every extension into
  /etc/xymon/xymonserver.d, graphs.d and rrddefinitions.d as
  conffiles, plus the per-extension server READMEs. Depends on the
  Debian "xymon" package; independent of the client package. Its file
  list lives in packaging/common/stage-server.sh, the counterpart of
  stage.sh. Debian specifics that shaped it: server and client share
  /etc/xymon and "xymon" depends on "xymon-client", so both packages
  can be installed on one host - the two file lists are kept disjoint
  (the client owns <name>.cfg and its launch snippets, the server
  package only the
  three drop-in directories) and the test suite plus a CI step verify
  that dpkg accepts them together. The package does not edit
  xymonserver.cfg/graphs.cfg/rrddefinitions.cfg, which are conffiles of
  the xymon package; its post-install detects which drop-in directory
  is not read yet and prints the "optional directory" line to add
  (normally only rrddefinitions.d, which Debian does not ship), and it
  leaves restarting Xymon to the admin. No rpm content changes

* Mon Aug 10 2026 roemer2201 <r.oliver@web.de> - 0.13.0-1
- server side: ship every extension's Xymon server configuration as
  drop-in files instead of instructions to edit stock config files.
  Xymon reads all of its config files through one reader
  (lib/stackio.c), so "include", "directory" and "optional" work in
  every one of them - verified in the sources for graphs.cfg
  (load_gdefs, web/showgraph.c), rrddefinitions.cfg (load_rrddefs,
  xymond/xymond_rrd.c) and xymonserver.cfg (loadenv, lib/environ.c),
  none of which is documented in the manual. The TEST2RRD/NCV/GRAPHS
  settings of every extension now live in
  server/xymonserver.d/<name>.cfg, matching the existing
  server/graphs.d and server/rrddefinitions.d layout; temp, la, memory
  and opkg gained a server/ directory (their settings were prose in
  the client README before). Documentation only on the client side -
  no extension script changed. New consistency test: stage.sh installs
  every server-side file and the FreeBSD pkg-plist lists exactly the
  staged set

* Mon Aug 10 2026 roemer2201 <r.oliver@web.de> - 0.12.0-1
- xymonext: new extension - measures what the client extensions cost
  the host. A wrapper runs each extension unchanged and records its
  wall clock time (/proc/uptime, /usr/bin/time -p on FreeBSD), the
  CPU time of the whole process tree (the POSIX "times" builtin, so
  no external tool is needed) and the number of bytes it sent to the
  server (a shim in front of $XYMON). One "xymonext" column carrying
  the table of all measured tests, split-NCV RRD graphs per test and
  metric, thresholds on the wall clock time to catch a hanging test;
  the task snippets and the standalone runner call the extensions
  through the wrapper, which can be switched off in xymonext.cfg

* Mon Aug 10 2026 roemer2201 <r.oliver@web.de> - 0.11.2-1
- smart: make the two DWPD graphs readable. A lifetime DWPD of 0.0034 is
  a normal value, and with rrdtool's defaults the y-axis of the smartdwpd
  and smartdwpdrecent graphs came out labelled "3.0 m" to "4.0 m" (milli)
  and autoscaled to the data range, so a drift of three ten-thousandths
  filled the whole graph and looked alarming. The two blocks in
  server/graphs.d/smart.cfg now set -X 0 (fix the SI exponent, plain
  decimals instead of an "m" prefix), -L 6 (room for labels like 0.004),
  -l 0 (anchor at zero, so the height shows the true magnitude) and -Y
  (alternative y-grid for the resulting narrow range). Graph definitions
  only - no change to the extension or its metrics

* Mon Aug 10 2026 roemer2201 <r.oliver@web.de> - 0.11.1-1
- if_link: stop long-range graphs from diluting single link changes
  into fractions. The extension only ever sends whole numbers, but
  Xymon creates RRD files with AVERAGE archives only, so a graph longer
  than 48 hours divides a flap by the consolidation factor of the view:
  a measured 2-change flap was drawn as 0.39 over 5 days, 0.20 over 12
  days and 0.07 over 40 days. New server-side archive definition
  (server/rrddefinitions.d/if_link.cfg) adds MAX archives next to
  Xymon's default AVERAGE ones, and the graph now draws its line from
  MAX - same visible height in every time range - plus an exact
  "(total)" event count for the shown window, integrated from the
  AVERAGE archive. Note that the per-slot values stay fractional and
  cannot be made whole: RRDtool aligns its 5-minute grid to the epoch,
  so a poll at a fixed offset inside the grid has every value split
  across two slots (2 changes -> 1.33 + 0.67 at an offset of 100 s).
  The dataset type therefore stays GAUGE - ABSOLUTE would store a rate
  per second and make the raw values less readable without fixing this.
  Existing installations have to drop their if_link RRD files once,
  since rrddefinitions.cfg is only consulted when a file is created;
  the client script is unchanged

* Sun Aug 09 2026 roemer2201 <r.oliver@web.de> - 0.11.0-1
- if_link: new extension - network interface link state changes from
  the kernel's carrier_changes counter (fallback: carrier_up_count +
  carrier_down_count), so even flaps that start and end between two
  polls are counted; dynamic interface discovery (physical Ethernet
  ports including DSA switch ports, with glob-based include/exclude
  lists and switches for wireless and virtual devices), green by
  default with optional global and per-port thresholds, split-NCV RRD
  graphing; active out of the box (it needs nothing but sysfs) and in
  the default TESTS list of the standalone runner

* Tue Jul 28 2026 roemer2201 <r.oliver@web.de> - 0.10.4-1
- temp: keep implausible sensor readings out of the RRD. Values
  outside TEMP_PLAUSIBLE_MIN..MAX were already reported as "clear"
  and left out of the NCV comment block, but the server's NCV parser
  treats "=" like ":" and so picked the bogus value up from the
  human-readable "&clear NAME = 491.0 C" line anyway. That whole part
  of the status message is now fenced off with the parser's
  ncv_skipstart/ncv_skipend markers, which also stops the normal
  display lines from creating a duplicate RRD dataset each

* Tue Jul 28 2026 roemer2201 <r.oliver@web.de> - 0.10.3-1
- disk: stop the Xymon server from creating bogus filesystem RRDs.
  The table header no longer says "Filesystem": that word made the
  server's disk RRD handler use the Windows format and name the RRD
  after the device column, so hosts whose first df row is a tmpfs or
  an overlay (OpenWrt) got "disk,tmpfs.rrd" instead of
  "disk,tmp.rrd". Footer notes and the "clear" messages are now
  prefixed with "&clear", the only reliable way to keep a line that
  contains a "/" out of that handler - short notes were still picked
  up and produced a nameless "disk.rrd" (and, before, "disk(,dev.rrd")

* Tue Jul 14 2026 roemer2201 <r.oliver@web.de> - 0.10.2-1
- disk: new extension - filesystem usage from "df -P -k" for
  clientless hosts (standalone runner), reporting into the standard
  "disk" column: global and per-mount thresholds, configurable
  exclude globs (/dev and /rom hidden by default), df-style table in
  the status parsed by the Xymon server's built-in disk RRD handler
  (stock graphs, no server-side setup); the task snippet ships
  disabled on full clients, which report "disk" themselves

* Mon Jul 13 2026 roemer2201 <r.oliver@web.de> - 0.9.0-1
- opkg: new extension - pending package update monitoring for
  opkg-based systems (OpenWrt/TurrisOS): refreshes the package lists
  itself when they are missing or stale (they live in RAM on
  OpenWrt), yellow on available updates, red when an update matches
  a configurable list of security-relevant package patterns, clear
  where opkg does not exist; NCV lines for RRD graphing; the task
  snippet ships disabled on full clients

* Sun Jul 12 2026 roemer2201 <r.oliver@web.de> - 0.8.0-1
- wifi: new extension - Wi-Fi access point metadata via iw/nl80211
  and (on OpenWrt) ubus/hostapd and iwinfo: client counts per SSID
  interface, channel utilization and noise floor per radio, interface
  throughput, client airtime and TX retry/failure rates computed from
  a state file between polls; informational only (green/clear),
  split-NCV RRD graphing; task snippet ships disabled on full clients

* Sat Jul 11 2026 roemer2201 <r.oliver@web.de> - 0.5.0-1
- fritzdsl: new extension - AVM FRITZ!Box DSL line monitoring via
  TR-064 (curl): line state, sync rate, noise margin, attenuation
  and error counters with thresholds, CRC-rate check and split-NCV
  RRD graphing; ships disabled until credentials are configured
- fritzwan: new extension - AVM FRITZ!Box WAN throughput monitoring:
  physical link state, average throughput, link capacity and
  utilization computed from the box's 64-bit UPnP byte counters
  (TR-064 32-bit fallback with wrap correction), optional
  utilization thresholds, split-NCV RRD graphing; ships disabled
  until configured

* Sat Jul 11 2026 roemer2201 <r.oliver@web.de> - 0.4.0-1
- new extensions temp, la and memory: local health metrics for
  clientless hosts (Turris Omnia / OpenWrt via the standalone runner)
  - hwmon/thermal temperature sensors, load average with per-core
  thresholds, memory utilization; NCV lines for RRD graphing; the
  la/memory task snippets ship disabled on full clients

* Fri Jul 10 2026 roemer2201 <r.oliver@web.de> - 0.3.0-1
- smart: eMMC health monitoring (Linux) via mmc-utils - EXT_CSD life
  time estimation mapped to the wear metric, PRE_EOL_INFO as health
  verdict; clear hints when mmc-utils or smartmontools are missing
  for present devices

* Thu Jul 09 2026 roemer2201 <r.oliver@web.de> - 0.2.0-1
- 0.2.0: standalone runner for clientless hosts added to the repo
  (shipped in the opkg package only; no rpm content changes)

* Mon Jul 06 2026 roemer2201 <r.oliver@web.de> - 0.1.0-1
- Initial package: smart extension (SMART disk monitoring, SATA + NVMe)
