# Packaging

Native packages for the three target platforms are built from the
top-level Makefile; the version comes from the `VERSION` file:

```sh
make deb        # on Debian/Ubuntu   -> build/my-xymon-extensions_<ver>-1_all.deb
make rpm        # on Rocky/EL        -> build/rpm/RPMS/noarch/*.rpm
make freebsd    # on FreeBSD         -> build/freebsd/out/*.pkg
make opkg       # on any platform    -> build/opkg/out/*.ipk (OpenWrt/TurrisOS)
```

deb/rpm/freebsd only build on their own platform (`dpkg-deb`,
`rpmbuild`, `pkg(8)`); the .ipk is plain tar+gzip and builds anywhere.
CI builds all of them. The file list is maintained in exactly one
place, `common/stage.sh`, which every build calls.

## Install layout per platform

| | ext script | config (`smart.cfg`, `tasks.d/`) | docs |
|---|---|---|---|
| deb | `/usr/lib/xymon/client/ext/` | `/etc/xymon/` (conffiles; reachable as `$XYMONCLIENTHOME/etc` via Debian's symlink) | `/usr/share/doc/my-xymon-extensions/` |
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

## Server-side drop-in files

The packages are **client** packages, but every extension that produces
RRD graphs also needs a few lines on the Xymon **server**. Those ship
as documentation, ready to copy:

```
<docdir>/<extension>/server/README.md
<docdir>/<extension>/server/xymonserver.d/<extension>.cfg
<docdir>/<extension>/server/graphs.d/<extension>.cfg
<docdir>/<extension>/server/rrddefinitions.d/<extension>.cfg   (if_link only)
```

Each file goes into the Xymon server's directory of the same name (see
the top-level README, section "Server-side setup: drop-in directories")
— no stock Xymon config file has to be edited. The opkg package ships
no docs at all; take the files from the repository there.

`tests/run.sh` checks that `common/stage.sh` installs every one of
these files and that `freebsd/pkg-plist` lists exactly the staged set.

## Common files

- `common/stage.sh` — single source of truth for what gets installed
  where; called by all three builds with platform-specific paths.
- `common/tasks.d/*.cfg` — xymonlaunch task snippets shipped by all
  three packages (one per extension).
