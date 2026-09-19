#!/bin/sh
# SPDX-License-Identifier: MIT
# stdout is a complete private table; never modifies nftables or configuration.
# OpenWrt's functions.sh intentionally reads unset optional variables.
set -e
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH LC_ALL=C
. /lib/functions.sh
die() { echo "配置错误: $*" >&2; exit 1; }
number() {
    case "$1" in ''|*[!0-9]*|0[0-9]*) die "$3 必须是十进制整数";; esac
    [ ${#1} -le 9 ] && [ "$1" -ge 0 ] && [ "$1" -le "$2" ] || die "$3 超出范围"
}
boolean() { case "$1" in 0|1) :;; *) die "$2 必须是 0 或 1";; esac; }
mac_check() {
    echo "$1" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || die 'MAC 格式错误'
    case "$1" in 00:00:00:00:00:00|?[13579bdf]:*) die 'MAC 必须是非零单播地址';; esac
}
ports=''
port() {
    case "$1" in ''|*[!a-zA-Z0-9_.:-]*) die '端口名称不合法';; esac
    [ ${#1} -le 15 ] || die '端口名过长'
    ports="${ports}${ports:+, }\"$1\""
}
config_load zbox-device-limit
globals=0
global_check() { globals=$((globals + 1)); [ "$1" = global ] || die '全局配置必须命名为 global'; }
config_foreach global_check global
[ "$globals" = 1 ] || die '需要且只能有一个 global 配置'
config_get enabled global enabled 0
config_get mode global mode whitelist
config_get down global download_rate 4000
config_get up global upload_rate 4000
config_get burst global burst_bytes 128000
boolean "$enabled" enabled
case "$mode" in whitelist|blacklist) :;; *) die '名单模式不合法';; esac
number "$down" 10000000 download_rate
number "$up" 10000000 upload_rate
number "$burst" 100000000 burst_bytes
config_list_foreach global ports port
if [ -z "$ports" ]; then
    [ "$enabled" = 0 ] || die '启用前至少选择一个 LAN/Wi-Fi 成员端口'
    ports='"__zdl_unset__"'
fi
seen=' '
count=0
validate_device() {
    local mac active policy dr ur
    count=$((count + 1)); [ "$count" -le 256 ] || die '最多 256 条设备配置'
    config_get mac "$1" mac
    mac=$(echo "$mac" | tr A-F a-f)
    mac_check "$mac"
    case "$seen" in *" $mac "*) die "重复 MAC: $mac";; esac
    seen="$seen$mac "
    config_get active "$1" enabled 1
    config_get policy "$1" policy member
    config_get dr "$1" download_rate "$down"
    config_get ur "$1" upload_rate "$up"
    boolean "$active" device.enabled
    case "$policy" in member|custom|unlimited) :;; *) die '设备策略不合法';; esac
    number "$dr" 10000000 device.download_rate
    number "$ur" 10000000 device.upload_rate
}
config_foreach validate_device device
echo '# Generated from UCI. Do not edit.'
echo 'table bridge zbox_device_limit {'
for direction in upload download; do
    echo " set ${direction}_per_mac { type ether_addr; size 4096; flags dynamic,timeout; }"
done
emit_device() {
    local active mac policy rate
    config_get active "$1" enabled 1
    [ "$active" = 1 ] || return 0
    config_get mac "$1" mac
    mac=$(echo "$mac" | tr A-F a-f)
    config_get policy "$1" policy member
    if [ "$policy" = unlimited ] || { [ "$policy" = member ] && [ "$mode" = whitelist ]; }; then
        echo "  ether $addr $mac counter return"
        return 0
    fi
    rate=$default
    [ "$policy" != custom ] || config_get rate "$1" "${direction}_rate" "$default"
    if [ "$rate" -gt 0 ]; then
        echo "  ether $addr $mac limit rate over $((rate * 125)) bytes/second burst $burst bytes counter drop"
    fi
    # Stop here even when under limit: never apply the default bucket again.
    echo "  ether $addr $mac counter return"
}
for direction in upload download; do
    if [ "$direction" = upload ]; then addr=saddr; hook=input; iface=iifname; default=$up
    else addr=daddr; hook=output; iface=oifname; default=$down; fi
    echo " chain $direction {"
    echo "  type filter hook $hook priority -10; policy accept;"
    echo "  $iface != { $ports } return"
    echo '  ether type != { ip, ip6 } return'
    echo "  ether $addr & 01:00:00:00:00:00 == 01:00:00:00:00:00 return"
    echo '  counter comment "eligible"'
    config_foreach emit_device device
    if [ "$mode" = whitelist ] && [ "$default" -gt 0 ]; then
        echo "  update @${direction}_per_mac { ether $addr timeout 10m limit rate over $((default * 125)) bytes/second burst $burst bytes } counter drop"
    fi
    echo ' }'
done
echo '}'
