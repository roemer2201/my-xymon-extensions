# Pure state/identity/metric engine; no commands, networking or config eval.
# Input: validated records from powerline.sh plus the previous state file.
# Output: per-host messages, a delivery manifest, and a new atomic snapshot.

BEGIN { FS = "|"; OFS = "|"; now = ENVIRON["POWERLINE_NOW"] + 0
    hold = ENVIRON["POWERLINE_CHANGE_MINUTES"] * 60
    flap = ENVIRON["POWERLINE_FLAP_MINUTES"] * 60
    gap = ENVIRON["POWERLINE_MAX_SAMPLE_GAP"] + 0
    retention = ENVIRON["POWERLINE_RETENTION_DAYS"] * 86400
    fzmax = ENVIRON["POWERLINE_FRITZBOX_MAX_AGE"] + 0
    fzfailed = ENVIRON["POWERLINE_FRITZBOX_UPDATE_FAILED"]
}
function safehost(h) { return h ~ /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/ && length(h) < 200 }
function validmac(m) { return length(m) == 12 && m ~ /^[0-9a-f]+$/ }
function uint(v) { return v ~ /^[0-9]+$/ }
function metricname(k) { return k ~ /^[a-z][a-z0-9_]*$/ && length(k) < 80 }
function note(m, s) { notes[m] = notes[m] s "\n" }
function severity(m, n, s) { if (n > color[m]) color[m] = n; if (s != "") note(m, s) }
function canonical(h) { h = tolower(h); return (h in names) ? names[h] : "" }
function ghost(m, h) {
    h = "powerline-unknown-" m
    # Prefix collisions must not attach an unknown adapter to a real host,
    # nor to a name that hosts.cfg claims but we refused to resolve.
    while (h in claimed) h = "unknown-" h
    return h
}
function resolve(m, key, i, parts, h, candidate, conflict, explicit, ip) {
    key = m
    if (m in mapping) explicit = mapping[m]
    else if (role[m] != "LOC" && bda[m] in mapping) explicit = mapping[bda[m]]
    if (explicit != "") {
        h = canonical(explicit)
        if (h == "") {
            if (explicit in ambiguous)
                severity(m, 2, "Mapping target " explicit " is an ambiguous CLIENT alias; map to the canonical host name.")
            else
                severity(m, 2, "Mapping target is not a known Xymon host.")
            return ghost(m)
        }
        return h
    }
    # LOC BDA can identify this Xymon server: never use it for local identity.
    if (role[m] != "LOC" && bda[m] != "") key = bda[m]
    for (i = 1; i <= 2; i++) {
        candidate = ""; conflict = 0
        for (ip in ips) if (ips[ip] == key && ip in iphosts) {
            split(iphosts[ip], parts, ",")
            for (h in parts) {
                if (candidate != "" && candidate != parts[h]) conflict = 1
                candidate = parts[h]
            }
        }
        if (conflict) { severity(m, 1, "Ambiguous IP-to-host mapping; configure an explicit mapping."); return ghost(m) }
        if (candidate != "") return candidate
        if (key == m) break
        key = m
    }
    # Cache identity, not ARP reachability. Remove it only when hosts.cfg no
    # longer knows that name, or when current evidence proves a new mapping.
    h = canonical(oldhost[m])
    return h != "" ? h : ghost(m)
}
function threshold(m, metric, value, warn, crit, low, label) {
    warn = ENVIRON["POWERLINE_" metric "_WARN"]
    crit = ENVIRON["POWERLINE_" metric "_CRIT"]
    if (crit != "off" && ((low && value < crit + 0) || (!low && value > crit + 0)))
        severity(m, 2, label " critical (" sprintf("%.3f", value) ").")
    else if (warn != "off" && ((low && value < warn + 0) || (!low && value > warn + 0)))
        severity(m, 1, label " warning (" sprintf("%.3f", value) ").")
}
function metric(m, p, k, v) { values[m SUBSEP p SUBSEP k] = v }
# An occasional adapter is plugged in only now and then (powerline.map,
# third field): its comings and goings never escalate to flapping, and it
# is never forgotten. Matched like the mapping: PLC MAC or REM BDA.
function occ(m) { return (m in occasional) || (role[m] != "LOC" && bda[m] != "" && bda[m] in occasional) }
# peerdiff(old, new) - the peers in one comma list and not in the other,
# as "+mac" and "-mac" words; ndiff/nocc count them and their occasional ones.
function peerdiff(o, n,   a, b, i, x, out) {
    split(o, a, ","); split(n, b, ",")
    for (x in inold) delete inold[x]
    for (x in innew) delete innew[x]
    for (i in a) if (a[i] != "") inold[a[i]] = 1
    for (i in b) if (b[i] != "") innew[b[i]] = 1
    out = ""; ndiff = 0; nocc = 0
    for (x in innew) if (!(x in inold)) { out = out " +" x; ndiff++; if (occ(x)) nocc++ }
    for (x in inold) if (!(x in innew)) { out = out " -" x; ndiff++; if (occ(x)) nocc++ }
    return out
}
# peername(p) - "mac (host)" when the peer resolved to a host.
function peername(p) { return (p in host) ? p " (" host[p] ")" : p }

$1 == "baseline" {
    if (NF != 2 || $2 != 1 || baseline) fatal = "Invalid baseline marker"
    baseline = 1; next
}
# Host names are canonical; a CLIENT alias is only a second name for one of
# them. Collect the aliases separately and fold them in once every host is
# known (see END), so the outcome does not depend on the order of hosts.cfg.
# An unusable alias is dropped, never fatal: it usually has nothing to do
# with the adapters being monitored, and aborting would stop the whole
# collector over an unrelated entry.
$1 == "host" {
    if (!safehost($3)) { fatal = "Unsafe hostname in hosts configuration"; next }
    h = tolower($3)
    names[h] = h; claimed[h] = 1
    if (index("," iphosts[$2] ",", "," h ",") == 0)
        iphosts[$2] = iphosts[$2] (iphosts[$2] == "" ? "" : ",") h
    if ($4 != "") {
        alias = tolower($4); claimed[alias] = 1
        if (!(alias in aliashost)) aliashost[alias] = h
        else if (aliashost[alias] != h) aliashost[alias] = ""
    }
    next
}
$1 == "neighbor" {
    if ($2 in ips && ips[$2] != $3) fatal = "Conflicting neighbor entries"
    ips[$2] = $3; next
}
$1 == "map" {
    if (!validmac($2) || !safehost($3) || ($2 in mapping && mapping[$2] != tolower($3)))
        fatal = "Invalid or conflicting static mapping"
    mapping[$2] = tolower($3); next
}
$1 == "occasional" {
    if (!validmac($2)) { fatal = "Invalid occasional adapter in the static mapping"; next }
    occasional[$2] = 1; next
}
# FRITZ!Box view of an adapter, from the fritzbox collector's hand-over
# file: mac|active|update available|update result|box|age|model|name.
# Data only; a malformed line is skipped, never fatal. With several boxes
# the freshest entry wins.
$1 == "fritz" {
    if (NF != 9 || !validmac($2) || $3 !~ /^[01]?$/ || $4 !~ /^[01]?$/ || $5 !~ /^[A-Za-z_-]*$/ ||
        !safehost($6) || !uint($7) || $8 !~ /^[ -~]*$/ || $9 !~ /^[ -~]*$/) next
    if (($2 in fzbox) && fzage[$2] <= $7 + 0) next
    fzactive[$2] = $3; fzavail[$2] = $4; fzresult[$2] = $5; fzbox[$2] = $6
    fzage[$2] = $7 + 0; fzmodel[$2] = $8; fzname[$2] = $9
    if ($7 + 0 <= fzmax) fzfresh = 1
    next
}
# Field 12 holds the last change text; fields 13/14 track ordinary
# changes separately so occasional peers cannot prolong a flap sequence.
# Continue accepting the old 11- and 12-field snapshots.
$1 == "state" {
    if ((NF != 11 && NF != 12 && NF != 14) || !validmac($2) || !safehost($4) || $3 !~ /^[01]$/ ||
        $5 !~ /^(LOC|REM)$/ || !validmac($6) || $7 !~ /^[0-9]+$/ ||
        $8 !~ /^[0-9]+$/ || $9 !~ /^[0-9]+$/ || $10 !~ /^[0-9]+$/ ||
        $7 + 0 > now || $9 + 0 > now ||
        (NF == 14 && (!uint($13) || !uint($14) || $13 + 0 > now || $14 + 0 > now))) {
        fatal = "Invalid state file or clock moved backwards"; next
    }
    m = $2; known[m] = 1; previous[m] = $3; oldhost[m] = $4
    role[m] = $5; bda[m] = $6; lastseen[m] = $7 + 0
    start[m] = $8 + 0; changed[m] = $9 + 0; changes[m] = $10 + 0; oldsig[m] = $11
    event[m] = (NF >= 12 && $12 ~ /^[ -~]*$/) ? $12 : ""
    hardstart[m] = (NF == 14) ? $13 + 0 : (changes[m] ? start[m] : 0)
    hardchanged[m] = (NF == 14) ? $14 + 0 : (changes[m] ? changed[m] : 0)
    next
}
$1 == "counter" {
    if (NF != 6 || !validmac($2) || !validmac($3) || !metricname($4) || !uint($5) || !uint($6)) {
        fatal = "Invalid counter state"; next
    }
    previous_value[$2 SUBSEP $3 SUBSEP $4] = $6; previous_time[$2 SUBSEP $3 SUBSEP $4] = $5 + 0; next
}
$1 == "series" {
    if (NF != 4 || !validmac($2) || ($3 != "self" && !validmac($3)) || !metricname($4)) {
        fatal = "Invalid metric inventory"; next
    }
    series[$2 SUBSEP $3 SUBSEP $4] = 1; next
}
$1 == "node" {
    m = $2; present[m] = 1
    # A device can appear in multiple topology groups, but LOC takes priority.
    if (currentrole[m] != "LOC" || $3 == "LOC") {
        role[m] = $3; currentrole[m] = $3; bda[m] = $4
    }
    next
}
$1 == "edge" { signature[$2] = signature[$2] $3 ","; links[$2 SUBSEP $3] = 1; next }
$1 == "fault" { severity($2, 2, $3); next }
$1 == "sample" {
    if (!(($2 SUBSEP $3) in links)) next
    key = $2 SUBSEP $3 SUBSEP $4
    if (key in samples && samples[key] != $5) fatal = "Conflicting metric samples"
    samples[key] = $5; next
}
NF { fatal = "Unknown normalized/state record" }
END {
    if (fatal != "") { print fatal > "/dev/stderr"; exit 1 }
    # A name that is a host of its own, or that two hosts claim as an alias,
    # resolves to nothing. Report it on stderr (the task log) and carry on.
    for (aname in aliashost) {
        if (aname in names) {
            if (names[aname] != aliashost[aname])
                print "Ignoring CLIENT alias " aname ": it is also a host name" > "/dev/stderr"
        }
        else if (aliashost[aname] == "") {
            ambiguous[aname] = 1
            print "Ignoring CLIENT alias " aname ": claimed by more than one host" > "/dev/stderr"
        }
        else names[aname] = aliashost[aname]
    }
    for (m in present) inventory[m] = 1
    # An adapter absent for longer than the retention is forgotten: no state,
    # no status, no series. Its column then goes purple; drop it in Xymon.
    for (m in known)
        if (!retention || now - lastseen[m] <= retention || occ(m)) inventory[m] = 1
    print "baseline|1" > snapshot
    for (m in inventory) {
        current = (m in present) ? 1 : 0
        transition = (m in known) ? (current != previous[m] || (current && signature[m] != oldsig[m])) : baseline
        # What changed, for the status text; worded later, once every
        # adapter has its host. A change caused only by occasional adapters
        # (the adapter itself, or peers that are all occasional) is "soft":
        # yellow for the hold time like any change, but it does not count
        # towards flapping.
        soft = 0
        if (transition) {
            if (!(m in known)) evkind[m] = "new"
            else if (current != previous[m]) evkind[m] = current ? "back" : "gone"
            else { evkind[m] = "peers"; evpeers[m] = peerdiff(oldsig[m], signature[m]) }
            if (occ(m) || (evkind[m] == "peers" && ndiff > 0 && nocc == ndiff)) soft = 1
        }
        # Settle before an event only if the quiet deadline was passed; an
        # event exactly at the deadline must not produce a one-poll green gap.
        if (start[m] && now - changed[m] >= hold && (!transition || now - changed[m] > hold)) {
            start[m] = 0
        }
        # Ordinary changes settle independently of the yellow hold for
        # occasional peers. A soft transition neither extends nor resets
        # a still-active ordinary flap sequence.
        hardtransition = transition && !soft
        if (hardstart[m] && now - hardchanged[m] >= hold && (!hardtransition || now - hardchanged[m] > hold)) {
            hardstart[m] = 0; hardchanged[m] = 0; changes[m] = 0
        }
        if (transition) {
            if (!start[m]) start[m] = now
            changed[m] = now
            if (!soft) {
                if (!hardstart[m]) hardstart[m] = now
                hardchanged[m] = now; changes[m]++
            }
        }
        if (start[m]) {
            if (hardstart[m] && now - hardstart[m] >= flap && changes[m] > 1)
                severity(m, 2, "state flapping")
            else severity(m, 1, "Topology changed; waiting for " hold/60 " minutes of stability.")
        }
        host[m] = resolve(m)
        if (current) {
            lastseen[m] = now
            note(m, "Adapter " m " (" role[m] "). TX/RX are relative to this adapter.")
        }
        # Accepted absence intentionally has no disappearance text - except
        # for an occasional adapter, whose absence is its normal state.
        else if (occ(m) && !start[m]) note(m, "Adapter " m " is not plugged in (occasional adapter).")
        printf "%s", "" > (outdir "/" host[m] ".metrics")
        metric(m, "self", "present", current)
    }
    # The change texts need the hosts of the peers, so they come second.
    # The text of the last change stays in the state and is shown for as
    # long as the change keeps the adapter yellow.
    for (m in inventory) {
        if (evkind[m] == "new") event[m] = "New adapter detected."
        else if (evkind[m] == "back") event[m] = "Adapter is back."
        else if (evkind[m] == "gone") event[m] = "Adapter disappeared."
        else if (evkind[m] == "peers") {
            event[m] = ""; nw = split(evpeers[m], words, " ")
            for (i = 1; i <= nw; i++)
                event[m] = event[m] (event[m] == "" ? "" : " ") (substr(words[i], 1, 1) == "+" ? "Peer added: " : "Peer lost: ") peername(substr(words[i], 2)) "."
        }
        if (start[m] && event[m] != "")
            note(m, "Last change " int((now - changed[m]) / 60) " minute(s) ago: " event[m])
        if (!start[m]) event[m] = ""
        print "state", m, (m in present) ? 1 : 0, host[m], role[m], bda[m], lastseen[m]+0, start[m]+0, changed[m]+0, changes[m]+0, signature[m], event[m], hardstart[m]+0, hardchanged[m]+0 > snapshot
    }
    # Every snapshot is a GAUGE; interval rates are separately named GAUGEs.
    # Samples above 2^53 cannot be differenced reliably with portable awk.
    for (key in samples) {
        split(key, f, SUBSEP); m = f[1]; p = f[2]; k = f[3]; v = samples[key]
        metric(m, p, k, v)
        if (k ~ /_(pass|fail|ack|collision)$/) {
            metric(m, p, k "_per_second", "U")
            stem = k; sub(/_(pass|ack)$/, "", stem)
            if (stem != k) metric(m, p, stem "_interval_pct", "U")
            print "counter", m, p, k, now, v > snapshot
            dt = now - previous_time[key]
            if (key in previous_value && dt > 0 && dt <= gap && v + 0 >= previous_value[key] + 0 &&
                v + 0 <= 9007199254740991 && previous_value[key] + 0 <= 9007199254740991) {
                deltas[key] = v - previous_value[key]
                metric(m, p, k "_per_second", sprintf("%.6f", deltas[key] / dt))
            }
        }
        if (k == "tx_phy_mbps" || k == "rx_phy_mbps")
            threshold(m, toupper(substr(k, 1, 2)) "_PHY", v, "", "", 1, "PHY " k " peer " p)
    }
    # Derive ratios from counts, not differences of rounded percentages.
    for (key in deltas) {
        split(key, f, SUBSEP); m = f[1]; p = f[2]; k = f[3]
        if (k !~ /_(pass|ack)$/) continue
        stem = k; sub(/_(pass|ack)$/, "", stem)
        failkey = m SUBSEP p SUBSEP stem "_fail"
        if (!(failkey in deltas)) continue
        total = deltas[key] + deltas[failkey]
        if (total > 0) {
            ratio = 100 * deltas[failkey] / total
            metric(m, p, stem "_interval_pct", sprintf("%.6f", ratio))
            if (stem == "tx_pb" || stem == "rx_pb")
                threshold(m, toupper(substr(stem, 1, 2)) "_PB", ratio, "", "", 0, "PB error " stem " peer " p)
        }
    }
    for (link in links) {
        split(link, f, SUBSEP); m = f[1]; p = f[2]
        if (!((m SUBSEP p SUBSEP "tx_phy_mbps") in samples) || !((m SUBSEP p SUBSEP "rx_phy_mbps") in samples))
            severity(m, 2, "Incomplete PHY rate response for peer " p ".")
        note(m, "Peer " p " = " host[p] ".")
        bp = m SUBSEP p SUBSEP "rx_all_pb_pass"; bf = m SUBSEP p SUBSEP "rx_all_pb_fail"
        ep = m SUBSEP p SUBSEP "rx_all_ber_pass"; ef = m SUBSEP p SUBSEP "rx_all_ber_fail"
        metric(m, p, "rx_all_fec_interval_pct", "U")
        if (bp in deltas && bf in deltas && ep in deltas && ef in deltas && deltas[bp] + deltas[bf] > 0)
            metric(m, p, "rx_all_fec_interval_pct", sprintf("%.6f", 100 * (deltas[ep]+deltas[ef]) / (4160*(deltas[bp]+deltas[bf]))))
    }
    # The FRITZ!Box view: the box's own record of the adapter. Only a fresh
    # file counts; an update the box offers is yellow, a failed one only
    # when configured, everything else is a note.
    for (m in inventory) {
        if (m in fzbox) {
            if (fzage[m] > fzmax) {
                note(m, "FRITZ!Box view (" fzbox[m] "): stale, " int(fzage[m] / 60) " minute(s) old - is the fritzbox collector running?")
                continue
            }
            txt = "FRITZ!Box view (" fzbox[m] "): \"" fzname[m] "\", " (fzmodel[m] == "" ? "unknown model" : fzmodel[m]) ", " (fzactive[m] == "1" ? "active" : "not active")
            if (fzavail[m] == "1") severity(m, 1, txt ", firmware update available.")
            else if (fzresult[m] == "failed" && fzfailed == "yellow") severity(m, 1, txt ", last firmware update failed.")
            else if (fzresult[m] == "failed") note(m, txt ", last firmware update failed.")
            else note(m, txt ".")
            if (fzactive[m] != "1" && (m in present)) note(m, "The FRITZ!Box reports this adapter as not active.")
        }
        else if (fzfresh && (m in present)) note(m, "FRITZ!Box view: this adapter is not in the box's adapter list.")
    }
    # NCV rejects U/NaN. Native data HOST.trends passes U straight to RRD,
    # preserving gaps before consolidation, with no fabricated sentinel.
    for (key in values) series[key] = 1
    for (key in series) {
        split(key, f, SUBSEP); m = f[1]; p = f[2]; k = f[3]
        if (!(m in inventory) || (p != "self" && !(p in inventory))) continue
        h = host[m]; value = (key in values) ? values[key] : "U"
        if (m in present || start[m])
            print "a" m "_p" p "_" k " : " value > (outdir "/" h ".metrics")
        print "[powerline,a" m "_p" p "_" k ".rrd]" > (outdir "/" h ".trends")
        print "DS:value:GAUGE:600:0:U " value > (outdir "/" h ".trends")
        print "series", m, p, k > snapshot
    }
    for (m in inventory) {
        h = host[m]; hosts[h] = 1
        if (color[m] > hostcolor[h]) hostcolor[h] = color[m]
        if (notes[m] != "") printf "%s", notes[m] > (outdir "/" h ".details")
        if (index(notes[m], "state flapping")) flapping[h] = 1
    }
    for (h in hosts) {
        c = hostcolor[h] == 2 ? "red" : (hostcolor[h] == 1 ? "yellow" : "green")
        print h, c, flapping[h] ? "state flapping" : (c == "green" ? "Powerline OK" : "Powerline attention required") > manifest
    }
}
