#!/bin/sh
# SPDX-License-Identifier: MIT
# Restore only files owned by this installer and its one firewall section.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
backup=${1:-}
case "$backup" in /etc/zbox-device-limit-backups/*) :;; *) echo '无效备份路径' >&2; exit 1;; esac
[ "$(id -u)" = 0 ] && [ -f "$backup/manifest.txt" ] && [ -f "$backup/active" ] || exit 1
if [ -x /etc/init.d/zbox-device-limit ]; then /etc/init.d/zbox-device-limit disable || :; fi
while IFS= read -r path; do
    case "$path" in ''|/*|*..*) exit 1;; esac
    if [ -f "$backup/files/$path" ]; then
        mkdir -p "/$(dirname "$path")"
        cp -p "$backup/files/$path" "/$path"
    elif grep -qxF "$path" "$backup/absent"; then rm -f "/$path"; fi
done < "$backup/manifest.txt"
uci -q delete firewall.zbox_device_limit || :
if [ -s "$backup/firewall.section.uci" ]; then uci -m import firewall < "$backup/firewall.section.uci"; fi
uci commit firewall
temp=$(mktemp /tmp/zbox-restore.XXXXXX)
trap 'rm -f "$temp"' EXIT
if nft list table bridge zbox_device_limit >/dev/null 2>&1; then echo 'delete table bridge zbox_device_limit' > "$temp"; fi
[ "$(cat "$backup/active")" = 0 ] || cat "$backup/runtime.nft" >> "$temp"
if [ -s "$temp" ]; then nft -c -f "$temp" && nft -f "$temp"; fi
if [ "$(cat "$backup/service-enabled")" = 1 ] && [ -x /etc/init.d/zbox-device-limit ]; then /etc/init.d/zbox-device-limit enable; fi
/etc/init.d/rpcd restart
echo "已恢复安装前的文件、限速表和对应防火墙项；备份保留在 $backup"
