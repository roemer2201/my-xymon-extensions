# fritz-wifi test fixtures

Recorded on 2026-09-23 from a FRITZ!Powerline 1260E (firmware 157.08.25)
over TR-064, masked by the device owner (MAC addresses AA:BB:CC:DD:EE:FF,
IPv4 192.0.2.1, serial numbers SERIAL):

- `tr64desc.xml` - device description (verbatim, including the services
  2 and 3 on one line)
- `getinfo1.xml`, `getinfo2.xml`, `getinfo3.xml` - GetInfo of the
  WLANConfiguration instances 1-3 (2.4 GHz, 5 GHz, disabled guest access)
- `total3.xml` - GetTotalAssociations of the disabled instance 3
- `fault713.xml` - HTTP 500 SOAP fault for an invalid client index
- `generic1.xml` - GetGenericAssociatedDeviceInfo of the one client on
  instance 1 (2.4 GHz), recorded on 2026-09-24 with the collector's
  `--debug` output. Speed 1 and signal 1 are the device's values (a
  low-power client; they vary between polls)
- `unauthorized.html` - HTTP 401 body for a wrong or empty password

Synthesized from the SCPD element names and the values measured by hand
(no 5 GHz client was connected during the recording); its layout is
that of the recorded `generic1.xml`:

- `generic2.xml` - GetGenericAssociatedDeviceInfo with one client
  (5 GHz: 866 Mbit/s, signal 91, width 80)
- `fault502.xml` - the HTTP 500 SOAP fault for a request body the device
  cannot parse: `fault713.xml` with the error code 502 and the
  description "XML error" observed on the device (for a self-closing
  action element, and for the empty body of curl's `--digest` probe)

`fakecurl` derives the remaining variants (client counts, a network that
is not up, protocol errors) from these files at runtime. The action that
returns the Wi-Fi keys appears nowhere here, and fakecurl refuses every
action outside the read-only list.
