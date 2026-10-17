# fritzbox - server-side monitoring of AVM FRITZ!Box routers

Server-only collector that polls AVM FRITZ!Box routers over TR-064 and
reports the columns `fritzdsl`, `fritzwan`, `fritzsys`, `fritzlog`,
`fritzfw`, `fritzlan` and `fritztel` on each box's host, plus the
adapter list the [powerline](../powerline/) collector shows. Shipped in
my-xymon-extensions-server and disabled on installation; it replaces the
fritzdsl and fritzwan client extensions of 0.28 and earlier. All
documentation - setup, password file, columns, colors, graphs,
migration - is in [server/README.md](server/README.md), which is the
file the package installs.
