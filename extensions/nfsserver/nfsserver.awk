# POSIX awk. Validate health inputs and turn host counters into rates.
# A snapshot records individual protocol and export-domain counters so that
# another, growing component cannot hide a reset or a changed set of clients.
BEGIN {
    color = "green"
    trend = out "/trends"; details = out "/details"; state = out "/next"
    print "data " machine ".trends" > trend
    print "clock", now, boot > state
    split("read write commit getattr lookup readdir open close", names, " ")
    split("6 7 21 1 3 16 0 0", v3, " ")
    split("25 38 5 9 15 26 18 4", v4, " ")
    n = split(ENVIRON["NFS_REQUIRED_PATHS"], items)
    for (i = 1; i <= n; i++) required[items[i]] = 1
    n = split(ENVIRON["NFS_REQUIRED_PORTS"], items)
    for (i = 1; i <= n; i++) requiredport[items[i]] = 1
    # Filenames are reversible for ordinary paths. Escape punctuation,
    # including the escape itself, so /a_b and /a/b remain distinct.
    for (i = 1; i <= 255; i++) ord[sprintf("%c", i)] = i
}
function html(s) {
    gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
    return s
}
function note(level, s) {
    if (level == "red" || color == "green") color = level
    if (!first[level]) first[level] = s
    print "&" level " " html(s) > details
}
function number(s) { return s ~ /^[0-9]+$/ }
function id(s,    k,c,r) {
    for (k = 1; k <= length(s); k++) {
        c = substr(s,k,1)
        r = r (c ~ /^[A-Za-z0-9_-]$/ ? c : (c == "/" ? "+" : sprintf("~%02X", ord[c])))
    }
    return r
}
function counter(key,val) {
    if (number(val)) {
        print key, val > state
        if (dt > 0 && dt <= 600 && key in prev && val+0 >= prev[key]+0)
            return (val-prev[key])/dt
    }
    return "U"
}
function section(s) { print "[" s ".rrd]" > trend }
function gauge(k,v) {
    printf "DS:%s:GAUGE:600:0:U %s\n", k, (v == "U" || v == "" ? "U" : sprintf("%.9g", v)) > trend
}
function raw(s) { return number(s) ? s : "U" }
function collect_ops(proto,indices,    i,k,idx) {
    protocols[proto] = 1
    for (i = 1; i <= 8; i++) {
        idx = indices[i]
        if (idx) {
            k = names[i]; ops[proto,k] = counter(proto "." k, $(idx+3))
        }
    }
    if (proto == "v3") ops[proto,"readdirplus"] = counter("v3.readdirplus", $20)
}
function op(k,    p,v,total) {
    if (!("v3" in protocols) && !("v4" in protocols)) return "U"
    for (p in protocols) {
        if (p == "v3" && (k == "open" || k == "close")) continue
        v = ops[p,k]
        if (v == "" || v == "U") return "U"
        total += v
    }
    return total+0
}
source == "previous" {
    if ($1 == "clock") { if ($3 == boot) dt = now - $2; next }
    if ($1 ~ /^exp\|/) { split($1, parts, /[|]/); oldmember[parts[2],parts[3]] = 1 }
    prev[$1] = $2; next
}
source == "problems" { bad[$1] = 1; next }
source == "configured" {
    # Only the first field of each logical exports(5) line is a path.
    if (continuation) { continuation = ($0 ~ /\\[[:space:]]*$/); next }
    if ($0 ~ /^[[:space:]]*(#|$)/) next
    continuation = ($0 ~ /\\[[:space:]]*$/)
    path = $1
    if (substr(path,1,1) == "\"") {
        line = $0; sub(/^[[:space:]]*"/, "", line)
        if (!match(line, /"/)) { bad["configured"] = 1; next }
        path = substr(line,1,RSTART-1)
        while (match(path, /[ \t]/)) {
            esc = substr(path,RSTART,1) == " " ? "040" : "011"
            path = substr(path,1,RSTART-1) sprintf("%c",92) esc substr(path,RSTART+1)
        }
    }
    if (path ~ /^\//) required[path] = 1
    else bad["configured"] = 1
    next
}
source == "etab" && NF && $1 !~ /^#/ {
    if ($1 !~ /^\// || NF < 2 || $2 !~ /\(.*\)$/) { bad["etab"] = 1; next }
    live[$1] = 1
    # Listed after the problems (END), so an alert mail starts with them.
    info = info "Export " html($1) "  " html($2) "\n"
    next
}
source == "ports" && NF {
    if (NF != 2 || !number($2)) { bad["ports"] = 1; next }
    port = $1 ":" $2
    if (!(port in active)) info = info "Listener " html(port) "\n"
    active[port] = 1; next
}
source == "rpc" {
    if ($1 == "th" && number($2)) threads = $2
    if ($1 == "rpc") { calls=counter("calls",$2); errors=counter("errors",$3); sawrpc=number($2) && number($3) }
    if ($1 == "fh") stale=counter("stale",$2)
    if ($1 == "io" && bytes == "yes") { rd=counter("bytes.read",$2); wr=counter("bytes.write",$3) }
    if ($1 == "proc3" && NF >= 24) collect_ops("v3",v3)
    if ($1 == "proc4ops" && NF >= 41) collect_ops("v4",v4)
    next
}
source == "cache" || source == "filecache" {
    field=$0; sub(/:.*/, "", field)
    if (number($NF)) cache[source,field] = $NF
    next
}
source == "rdma" { have_rdma = 1; transport[$1] = counter("rdma." $1,$2); next }
source == "perexport" && $1 ~ /^\// {
    path = id($1); member = id($2); epoch = $3
    # Too-long names cannot be RRD filenames; the status still lists the path.
    if (length(path) > 210 || !number(epoch) || member == "") { path=""; next }
    series[path] = 1; members[path,member] = 1
    next
}
source == "perexport" && path != "" && ($1 == "io_read:" || $1 == "io_write:") {
    k = ($1 == "io_read:" ? "read" : "write")
    key = "exp|" path "|" member "|" epoch "|" k
    rates[path,member,k] = counter(key,$2)
}
function export_rate(p,k,    m,a,v,total) {
    for (m in oldmember) {
        split(m,a,SUBSEP)
        if (a[1] == p && !(m in members)) return "U"
    }
    for (m in members) {
        split(m,a,SUBSEP)
        if (a[1] != p) continue
        v = rates[a[1],a[2],k]
        if (v == "U" || v == "") return "U"
        total += v
    }
    return total/1048576
}
END {
    for (k in bad) note("yellow","Cannot read or parse " k)
    if (!number(threads)) note("yellow","NFS thread count unavailable")
    else if (threads+0 == 0) note("red","No NFS server threads")
    else info = "NFS threads: " threads "\n" info
    if (!sawrpc && !bad["rpc"]) note("yellow","RPC counters unavailable")
    if (!bad["etab"]) for (p in required) if (!(p in live)) note("red","Missing export " p)
    if (!bad["ports"]) {
        count=0; for (p in active) count++
        if (!count) note("red","No NFS listeners")
        for (p in requiredport) if (!(p in active)) note("red","Missing listener " p)
    }
    if (info != "") {
        if (color != "green") print "" > details
        printf "%s", info > details
    }
    print color > (out "/color")
    print (color == "green" ? "NFS server running (" threads " threads)" : html(first[color])) > (out "/summary")
    section("nfsserver")
    for (i=1;i<=3;i++) gauge(names[i],op(names[i]))
    section("nfsmeta")
    for (i=4;i<=8;i++) gauge(names[i],op(names[i]))
    if ("v3" in protocols) plus=ops["v3","readdirplus"]
    gauge("readdirplus",plus)
    section("nfsrpc"); gauge("calls",calls)
    section("nfserrors"); gauge("badcalls",errors); gauge("stale",stale)
    if (bytes == "yes") {
        section("nfsbytes")
        gauge("read",rd == "U" || rd == "" ? "U" : rd/1048576)
        gauge("write",wr == "U" || wr == "" ? "U" : wr/1048576)
    }
    if (("cache","num entries") in cache) {
        entries=cache["cache","num entries"]; maxent=cache["cache","max entries"]
        section("nfscache"); gauge("entries",entries)
        section("nfscachepct"); gauge("percent",maxent+0 > 0 ? entries*100/maxent : "U")
        section("nfscachemem"); mem=cache["cache","mem usage"]
        gauge("mib",number(mem) ? mem/1048576 : "U")
    }
    # Older file caches report "total entries" (upstream 5.x without an
    # LRU count, Rocky 9.2 with one); 6.x and Rocky 9.4+ "total inodes".
    if ((("filecache","total inodes") in cache) || (("filecache","total entries") in cache)) {
        files = (("filecache","total inodes") in cache) ? cache["filecache","total inodes"] : cache["filecache","total entries"]
        section("nfsfiles"); gauge("inodes",files)
        gauge("lru",raw(cache["filecache","lru entries"]))
    }
    if (have_rdma) {
        section("nfsrdma")
        gauge("recv",transport["recv"]); gauge("read",transport["read"])
        gauge("write",transport["write"]); gauge("sq_starve",transport["sq_starve"])
    }
    for (p in series) {
        section("nfsexport," p)
        gauge("read",export_rate(p,"read")); gauge("write",export_rate(p,"write"))
    }
    for (m in oldmember) {
        split(m,a,SUBSEP); p=a[1]
        if (!(p in series)) {
            section("nfsexport," p); gauge("read","U"); gauge("write","U"); series[p]=1
        }
    }
}
