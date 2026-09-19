# SPDX-License-Identifier: MIT
# Strict importer for the legacy table seen in the supplied router log.
# Unknown statements are refused rather than silently discarded.
function reject(msg) { print "旧规则无法自动迁移: " msg > "/dev/stderr"; bad=1; exit 1 }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function bytes(n,u) {
    if (u=="bytes") return n
    if (u=="kbytes") return n*1024
    if (u=="mbytes") return n*1048576
    reject("未知速率单位 " u)
}
function parse_macs(s, a,n,i) {
    gsub(/[{},;]/," ",s); sub(/.*elements[ \t]*=/,"",s)
    n=split(s,a,/[ \t]+/)
    for(i=1;i<=n;i++) if(a[i]!="") {
        if(a[i] !~ /^[0-9a-fA-F:]+$/ || length(a[i])!=17) reject("白名单 MAC 格式")
        macs[tolower(a[i])]=1
    }
}
{
    line=$0; sub(/#.*/,"",line); line=trim(line)
    if(line=="") next
    if(line=="table bridge zbox_device_limit {") { if(table++) reject("多个表"); next }
    if(line ~ /^set (unlimited|upload_per_mac|download_per_mac)[ \t]*\{$/) {
        split(line,a,/[ \t]+/); block=a[2]; sets[block]++; next
    }
    if(line ~ /^chain (upload|download)[ \t]*\{$/) {
        split(line,a,/[ \t]+/); block=a[2]; chains[block]++; next
    }
    if(line ~ /^}[;]?$/) {
        if(block=="unlimited" && elements) { elements=0; next }
        if(block!="") block=""; else closed++; next
    }
    if(block=="unlimited") {
        if(line ~ /^type ether_addr[;]?$/) next
        if(line ~ /^elements[ \t]*=/) { elements=1; parse_macs(line); if(line ~ /}/) elements=0; next }
        if(elements) { parse_macs(line); if(line ~ /}/) elements=0; next }
        reject("未知白名单语句: " line)
    }
    if(block=="upload_per_mac" || block=="download_per_mac") {
        if(line ~ /^(type ether_addr|size 4096|flags (dynamic,timeout|dynamic, timeout))[;]?$/) next
        reject("动态集合必须是原始规则文件中的空集合: " line)
    }
    if(block=="upload" || block=="download") {
        h=block=="upload" ? "input" : "output"
        if(line == "type filter hook " h " priority -10; policy accept;") {hooks[block]++; next}
        if(line ~ /^[io]ifname != \{.*\} return[;]?$/) {
            if(substr(line,1,1)!=(block=="upload" ? "i" : "o")) reject("端口方向")
            p=line; sub(/^[^{]*\{/,"",p); sub(/\}.*/,"",p); gsub(/[",]/," ",p)
            p=trim(p); gsub(/[ \t]+/," ",p); ports[block]=p; next
        }
        if(line == "ether " (block=="upload" ? "saddr" : "daddr") " @unlimited return" ||
           line == "ether " (block=="upload" ? "saddr" : "daddr") " @unlimited return;") { exempt[block]++; next }
        if(line ~ /^ether type != \{ ip, ip6 \} return[;]?$/) {types[block]++; next}
        if(block=="download" && line ~ /^ether daddr & 01:00:00:00:00:00 == 01:00:00:00:00:00 return[;]?$/) next
        if(line ~ /^counter([;]| packets [0-9]+ bytes [0-9]+[;]?)?$/) next
        # Legacy source can use inline meters. `nft list table` expands them
        # into named dynamic sets, so runtime output alone missed this form.
        kind="update"
        if(line ~ /^meter (upload|download)_per_mac size 4096 \{/) {
            kind="meter"
            sub(/^meter /,"update @",line)
            sub(/ size 4096 \{/," {",line)
        }
        if(line ~ /^update @(upload|download)_per_mac \{ ether (saddr|daddr) timeout 10m limit rate over [0-9]+ (bytes|kbytes|mbytes)\/second burst [0-9]+ (bytes|kbytes|mbytes) \} counter( packets [0-9]+ bytes [0-9]+)? drop[;]?$/) {
            split(line,a,/[ \t]+/)
            if(a[2]!="@" block "_per_mac" || a[5]!=(block=="upload" ? "saddr" : "daddr")) reject("计量方向")
            u=a[12]; sub(/\/second/,"",u)
            rate[block]=bytes(a[11],u)/125
            burst[block]=bytes(a[14],a[15]); limits[block]++; form[block]=kind
            next
        }
    }
    reject("未识别的结构或语句: " line)
}
END {
    if(bad) exit 1
    if(table!=1 || closed!=1 || sets["unlimited"]!=1 ||
        chains["upload"]!=1 || chains["download"]!=1 || hooks["upload"]!=1 || hooks["download"]!=1 ||
        exempt["upload"]!=1 || exempt["download"]!=1 || types["upload"]!=1 || types["download"]!=1 ||
        limits["upload"]!=1 || limits["download"]!=1 || ports["upload"]=="" || ports["upload"]!=ports["download"] || burst["upload"]!=burst["download"])
        reject("缺少预期规则，或上下行端口/突发额度不一致")
    for(direction in limits) {
        expected=(form[direction]=="update" ? 1 : 0)
        if(sets[direction "_per_mac"]!=expected)
            reject("计量器与动态集合声明不一致: " direction)
    }
    if(rate["upload"]!=int(rate["upload"]) || rate["download"]!=int(rate["download"])) reject("无法精确转换为整数 Kbit/s")
    print "config global 'global'"
    print " option enabled '" enabled "'"
    print " option mode 'whitelist'"
    printf " option upload_rate '%.0f'\n option download_rate '%.0f'\n option burst_bytes '%.0f'\n",rate["upload"],rate["download"],burst["upload"]
    n=split(ports["upload"],a," ")
    for(i=1;i<=n;i++) {
        if(a[i] !~ /^[a-zA-Z0-9_.:-]+$/ || length(a[i])>15) reject("端口名不合法")
        print " list ports '" a[i] "'"
    }
    for(mac in macs) {
        print "\nconfig device"
        print " option enabled '1'\n option policy 'member'"
        print " option mac '" mac "'"
    }
}
