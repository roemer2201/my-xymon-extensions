# fritz-wifi - server-side Wi-Fi metadata of AVM FRITZ! devices

Server-only collector that reads the Wi-Fi metadata of AVM FRITZ!
devices (reference: FRITZ!Powerline 1260E) over TR-064 and reports it
into the `wifi` column and RRD graphs of the OpenWrt
[wifi](../wifi/) extension. Shipped in my-xymon-extensions-server and
disabled on installation. All documentation - setup, password file,
graphs, colors - is in [server/README.md](server/README.md), which is
the file the package installs.
