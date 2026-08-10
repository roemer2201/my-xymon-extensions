# Packaging

Native packages for the three target platforms are built from the
top-level Makefile; the version comes from the `VERSION` file:

```sh
make deb        # on Debian/Ubuntu   -> build/my-xymon-extensions_<ver>-1_all.deb
make deb-server # on Debian/Ubuntu   -> build/my-xymon-extensions-server_<ver>-1_all.deb
make rpm        # on Rocky/EL        -> build/rpm/RPMS/noarch/*.rpm
make freebsd    # on FreeBSD         -> build/freebsd/out/*.pkg
make opkg       # on any platform    -> build/opkg/out/*.ipk (OpenWrt/TurrisOS)
```

deb/rpm/freebsd only build on their own platform (`dpkg-deb`,
`rpmbuild`, `pkg(8)`); the .ipk is plain tar+gzip and builds anywhere.
CI builds all of them.

All targets except `deb-server` build the **client** package; their
file list is maintained in exactly one place, `common/stage.sh`, which
every one of those builds calls. The **server** package has its own
list in `common/stage-server.sh` — it installs entirely different
files into an entirely different tree.

## Install layout per platform

| | ext script | config (`smart.cfg`, `tasks.d/`) | docs |
|---|---|---|---|
| deb | `/usr/lib/xymon/client/ext/` | `/etc/xymon/` (conffiles; reachable as `$XYMONCLIENTHOME/etc` via Debian's symlink) | `/usr/share/doc/my-xymon-extensions/` |
| deb-server | — (no client files) | `/etc/xymon/{xymonserver,graphs,rrddefinitions}.d/` (conffiles) | `/usr/share/doc/my-xymon-extensions-server/` |
| rpm | `/usr/lib64/xymon/client/ext/` | `/usr/lib64/xymon/client/etc/` (`%config(noreplace)`) | `/usr/share/doc/my-xymon-extensions/` |
| FreeBSD | `/usr/local/www/xymon/client/ext/` | `/usr/local/www/xymon/client/etc/` (`@sample`) | `/usr/local/share/doc/my-xymon-extensions/` |
| opkg | `/usr/lib/xymon-standalone/ext/` | `/etc/xymon-standalone/` (conffiles; incl. `standalone.cfg`, no `tasks.d/` — no xymonlaunch; `/usr/lib/xymon-standalone/etc` is a symlink to it) | none (flash space) |

The opkg package targets hosts **without** a Xymon client
(OpenWrt/TurrisOS): it additionally ships the standalone runner
(`xymon-run.sh`/`xymon-send.sh` from `standalone/`) and is driven by
cron instead of xymonlaunch — see `standalone/README.md`.

The rpm layout defaults to the Terabithia xymon-client builds
(`XYMONHOME=/usr/lib64/xymon/client`). For a different layout rebuild
with:

```sh
sh packaging/rpm/build.sh --define 'xymonhome /usr/share/xymon-client'
```

## Activation after installation

The packages deliberately do **not** edit `clientlaunch.cfg` (it is
owned by the xymon-client package). After installing, once per host:

1. Install the sudoers rule (see `smart/sudoers.example` in the docs
   directory).
2. Ensure `clientlaunch.cfg` contains a `directory` include for the
   `tasks.d` directory shown in the table above, e.g. on Debian:
   `directory /etc/xymon/tasks.d`
3. Restart the Xymon client.

The post-install output of the deb/rpm packages repeats these steps
with the platform's concrete paths.

## The server package (`deb-server`)

Every extension that produces RRD graphs also needs a few lines on the
Xymon **server**. `my-xymon-extensions-server` installs them, as
conffiles, into the drop-in directories Xymon reads them from:

| | installed to |
|---|---|
| `TEST2RRD`, `NCV_*`/`SPLITNCV_*`, `GRAPHS*` | `/etc/xymon/xymonserver.d/<ext>.cfg` |
| graph definitions | `/etc/xymon/graphs.d/<ext>.cfg` |
| RRA archives (if_link only) | `/etc/xymon/rrddefinitions.d/if_link.cfg` |
| per-extension server docs | `/usr/share/doc/my-xymon-extensions-server/<ext>/` |

It depends on `xymon` (the Debian server package), the client package
depends on `xymon-client` — they are installed independently, or
together on a host that is both.

### The /etc/xymon overlap

On Debian/Ubuntu the server and the client share one config directory,
`/etc/xymon`, and `xymon` depends on `xymon-client`, so on a Xymon
server both of our packages are a realistic combination. dpkg refuses
to install two packages that ship the same path, so the two file lists
must stay disjoint:

- client: `/etc/xymon/<name>.cfg` and `/etc/xymon/tasks.d/<name>.cfg`
- server: only the three drop-in directories above

`tests/run.sh` stages both with the Debian paths and fails if a single
path appears in both; the CI job additionally installs both packages
with dpkg and compares the file lists it recorded.

### What the package does not do

It does not edit `xymonserver.cfg`, `graphs.cfg` or
`rrddefinitions.cfg` — conffiles of the `xymon` package; editing them
would make dpkg prompt on its next upgrade. `deb-server/postinst`
instead checks whether each drop-in directory is read at all and prints
the missing `optional directory` line. Debian wires up `xymonserver.d`
and `graphs.d` itself, but ships no `rrddefinitions.d`, so that one is
normally the single TODO. It also does not restart Xymon — the
post-install prints `service xymon restart` and leaves the timing to
the admin.

## Server-side files in the client packages

The client packages (deb, rpm, FreeBSD) additionally carry the same
drop-in files as **documentation**, for servers that are not
Debian/Ubuntu or where the server package is not used:

```
<docdir>/<extension>/server/README.md
<docdir>/<extension>/server/xymonserver.d/<extension>.cfg
<docdir>/<extension>/server/graphs.d/<extension>.cfg
<docdir>/<extension>/server/rrddefinitions.d/<extension>.cfg   (if_link only)
```

Nothing installs them into a Xymon config directory — copy them over by
hand (see the top-level README, "Server-side setup: drop-in
directories"). The opkg package ships no docs at all; take the files
from the repository there.

`tests/run.sh` checks that `common/stage.sh` installs every one of
these files and that `freebsd/pkg-plist` lists exactly the staged set.

## Common files

- `common/stage.sh` — single source of truth for what the **client**
  packages install where; called by all four client builds with
  platform-specific paths.
- `common/stage-server.sh` — the same for the **server** package
  (currently only `deb-server`).
- `common/tasks.d/*.cfg` — xymonlaunch task snippets shipped by all
  three packages (one per extension).
