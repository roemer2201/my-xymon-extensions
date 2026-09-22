# Normalize verified open-plc-utils stdout; never parse stderr as data.
# Modes: topology, rates, stats. Output is pipe-delimited ASCII records.
# Version: 1.0.0 (2026-09-22)

function mac(s, t) {
    t = tolower(s); gsub(/:/, "", t)
    return (length(t) == 12 && t ~ /^[0-9a-f]+$/) ? t : ""
}
function number(s) { return s ~ /^[0-9]+([.][0-9]+)?$/ }
function integer(s) { return s ~ /^[0-9]+$/ }
function pct(s) { return s ~ /^[0-9]+([.][0-9]+)?%$/ && s + 0 <= 100 }
function emit(k, v) {
    sub(/%$/, "", v)
    print "sample|" adapter "|" peer "|" k "|" v
}
function counts(prefix, pass, fail, err) {
    if (!integer(pass) || !integer(fail) || !pct(err)) { bad = 1; return }
    emit(prefix "_pass", pass); emit(prefix "_fail", fail)
    emit(prefix "_reported_pct", err)
}

# Topology is grouped by the queried LOC adapter. Deduplicate discoveries
# later, retaining every observed local/remote link.
mode == "topology" && ($1 == "LOC" || $1 == "REM") {
    m = mac($4); b = mac($5)
    if (NF < 9 || m == "" || b == "" || ($2 != "CCO" && $2 != "STA")) {
        bad = 1; next
    }
    if ($1 == "LOC") { loc = m; locals++ }
    else {
        if (loc == "" || !number($6) || !number($7)) { bad = 1; next }
        print "edge|" loc "|" m
        print "edge|" m "|" loc
    }
    print "node|" m "|" $1 "|" b
    rows++
    next
}

# A result must identify both endpoints and the requested adapter.
mode == "rates" && ($4 == "TX" || $4 == "RX") {
    a = mac($2); p = mac($3)
    if (a != adapter || p == "" || !number($5) || tolower($6) != "mbps") {
        bad = 1; next
    }
    peer = p
    emit(tolower($4) "_phy_mbps", $5)
    rows++
    next
}

# TX contains an unlabelled MPDU collision count; RX has one field less.
mode == "stats" && ($1 == "TX" || $1 == "RX") {
    d = tolower($1)
    if ((d == "tx" && NF != 8) || (d == "rx" && NF != 7) || seen[d]++) {
        bad = 1; next
    }
    counts(d "_pb", $2, $3, $4)
    if (!integer($5) || !integer($6) || !pct($NF)) { bad = 1; next }
    emit(d "_mpdu_ack", $5); emit(d "_mpdu_fail", $6)
    emit(d "_mpdu_reported_pct", $NF)
    if (d == "tx") {
        if (!integer($7)) bad = 1
        else emit("tx_mpdu_collision", $7)
    }
    rows++
    next
}

# Slot statistics belong to the receiving endpoint only. ALL is not a slot
# and must not be added to the per-slot counters.
mode == "stats" && ($1 ~ /^[0-9]+$/ || $1 == "ALL") {
    if (NF != 8 || slots[$1]++) { bad = 1; next }
    if ($1 == "ALL") {
        prefix = "rx_all"
        counts(prefix "_pb", $2, $3, $4)
        counts(prefix "_ber", $5, $6, $7)
        if (!pct($8)) bad = 1
        else emit("rx_all_fec_reported_pct", $8)
        all++
    } else {
        prefix = "rx_slot" ($1 + 0)
        if (!number($2) || $1 + 0 > 255) { bad = 1; next }
        emit(prefix "_phy_mbps", $2)
        counts(prefix "_pb", $3, $4, $5)
        counts(prefix "_ber", $6, $7, $8)
    }
    rows++
    next
}

# Reject unexpected nonblank output instead of turning a changed format into
# missing devices. The sole permitted non-data lines are known headers.
NF && !(mode == "topology" && $1 == "P/L") &&
      !(mode == "stats" && ($1 == "DIR" || $1 == "PHY")) { bad = 1 }
END {
    if (bad || !rows || (mode == "topology" && !locals) ||
        (mode == "stats" && (!seen["tx"] || !seen["rx"] || !all))) exit 1
}
