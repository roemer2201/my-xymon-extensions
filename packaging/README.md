# Packaging

Native packages for the three target platforms are built from the
top-level Makefile; the version comes from the `VERSION` file:

```sh
make deb        # on Debian/Ubuntu   -> build/my-xymon-extensions_<ver>-1_all.deb
make rpm        # on Rocky/EL        -> build/rpm/RPMS/noarch/*.rpm
make freebsd    # on FreeBSD         -> build/freebsd/out/*.pkg
```

Each target only works on its own platform (`dpkg-deb`, `rpmbuild`,
`pkg(8)`); CI builds all three. The file list is maintained in exactly
one place, `common/stage.sh`, which all three builds call.

## Install layout per platform

| | ext script | config (`smart.cfg`, `tasks.d/`) | docs |
|---|---|---|---|
| deb | `/usr/lib/xymon/client/ext/` | `/etc/xymon/` (conffiles; reachable as `$XYMONCLIENTHOME/etc` via Debian's symlink) | `/usr/share/doc/my-xymon-extensions/` |
| rpm | `/usr/lib64/xymon/client/ext/` | `/usr/lib64/xymon/client/etc/` (`%config(noreplace)`) | `/usr/share/doc/my-xymon-extensions/` |
| FreeBSD | `/usr/local/www/xymon/client/ext/` | `/usr/local/www/xymon/client/etc/` (`@sample`) | `/usr/local/share/doc/my-xymon-extensions/` |

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

## Common files

- `common/stage.sh` — single source of truth for what gets installed
  where; called by all three builds with platform-specific paths.
- `common/tasks.d/*.cfg` — xymonlaunch task snippets shipped by all
  three packages (one per extension).
