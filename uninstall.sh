#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$(id -u)" = 0 ] || exit 1
case "${1:-}" in --restore|--remove) :;; *) echo 'Usage: uninstall.sh --restore | --remove'; exit 2;; esac
backup=$(cat /etc/zbox-device-limit/.installed)
case "$backup" in /etc/zbox-device-limit-backups/*) :;; *) exit 1;; esac
[ -f "$backup/manifest.txt" ] || exit 1
[ -z "$(uci changes firewall)" ] || { echo '请先处理 firewall 暂存更改'; exit 1; }
mkdir /var/lock/zbox-device-limit-install.lock 2>/dev/null || { echo '另一个安装/卸载正在进行'; exit 1; }
trap 'rmdir /var/lock/zbox-device-limit-install.lock 2>/dev/null || :' EXIT
cp -p /etc/config/zbox-device-limit "$backup/uninstalled-config.uci"
if [ "$1" = --restore ]; then
    sh "$backup/restore.sh" "$backup"
else
    /etc/zbox-device-limit/load.sh stop
    /etc/init.d/zbox-device-limit disable
    # Retain original and current config for inspection; remove only owned files.
    uci -q delete firewall.zbox_device_limit || :
    uci commit firewall
    while IFS= read -r path; do
        case "$path" in ''|/*|*..*) exit 1;; esac
        rm -f "/$path"
    done < "$backup/manifest.txt"
    /etc/init.d/rpcd restart
    echo "应用已移除，旧规则不会自动恢复。配置与原文件保留在 $backup"
fi
