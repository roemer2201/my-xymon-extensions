# powerline - server-side PLC monitoring

POSIX sh collector for HomePlug adapters reachable on the server's Ethernet
segment. This is a **server-only** extension in my-xymon-extensions-server.
It is disabled on installation. See [server setup](server/README.md).

Each adapter gets its own HOST.powerline status and MAC-pair/receive-slot
graphs. TX and RX are relative to that adapter, not always to the server.
The PHY values are negotiated rates, not measured application throughput.
The collector never resets PLC counters or changes device settings.

Requires Linux, open-plc-utils (plcstat and plcrate), iproute2, flock,
sudo, POSIX awk/sh and the Xymon server environment. QCA7500 operation is
based on the supplied verified outputs, not an upstream support guarantee.
Only the server package installs these files; client platforms are unchanged.

Run --help for configuration/environment/CLI precedence and dry-run usage.
All quality thresholds ship as off; topology and collection errors still
affect status. State is persistent, not kept in /tmp.
