# fritzbox test fixtures

Derived from a read-only crawl (every Get action without input
arguments) of a FRITZ!Box 7510, FRITZ!OS 8.26 (271.08.26), on
2026-10-18, and anonymized before they went into the repository:

- addresses: IPv4 from 192.0.2.0/24 (LAN) and 198.51.100.0/24 (WAN),
  IPv6 from 2001:db8::/32
- MAC addresses: locally administered 02:00:00:... values
- serial number, UDN, host and adapter names, SIP registrar, phone
  numbers, DynDNS domain, user names and e-mail: invented
- counters, rates, margins, versions, element names and their order:
  as recorded

The `GetTotalPackets*` answers (IGD and TR-064) were recorded by a
separate read-only probe of the same box on the same day.

The SOAP envelopes are rebuilt around the recorded values; the element
names are those of the box's answers. The event log keeps the box's
German messages, including their UTF-8 umlauts - the collector must
cope with exactly those bytes. `hostlist.xml` follows the structure of
the box's `devicehostlist.lua` answer (six invented hosts).

File names: `CONTROL__ACTION[__INDEX].xml`, CONTROL being the last part
of the `/upnp/control/` URL, or the URL path with "/" -> "_" for
UPnP/IGD. `fault713.xml` ends an indexed list, `fault401.xml` (UPnP
"Invalid Action") answers an unknown action, `fault502.xml` a body the
box cannot parse, `unauthorized.html` a wrong login.
