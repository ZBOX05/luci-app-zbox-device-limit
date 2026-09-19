#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
BASE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
candidate_input=''
case "${1:-}" in
    '') :;;
    --config) [ "$#" = 2 ] && [ -f "$2" ] || { echo 'Usage: install.sh [--config FILE]' >&2; exit 2; }; candidate_input=$2;;
    *) echo 'Usage: install.sh [--config FILE]' >&2; exit 2;;
esac
DIR=/etc/zbox-device-limit
BACKUPS=/etc/zbox-device-limit-backups
die() { echo "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die '请使用 root 安装。'
[ -f /etc/openwrt_release ] || die '此安装包只适用于 OpenWrt。'
for tool in nft uci ubus awk tar sha256sum; do command -v "$tool" >/dev/null || die "缺少依赖: $tool"; done
[ -r /lib/functions.sh ] && [ -r /usr/share/libubox/jshn.sh ] || die '缺少 OpenWrt functions.sh / jshn.sh。'
[ -f /www/luci-static/resources/form.js ] && [ -x /etc/init.d/rpcd ] || die '请先安装现代 LuCI 和 rpcd。'
[ -z "$(uci -q changes firewall)" ] && [ -z "$(uci -q changes zbox-device-limit)" ] || die '请先保存或撤销 firewall / zbox-device-limit 的命令行 UCI 暂存更改。'
[ ! -d /tmp/zbox-whitelist-menu.lock ] || die '请先退出旧白名单菜单。'
mkdir -p /var/lock
mkdir /var/lock/zbox-device-limit-install.lock 2>/dev/null || die '已有安装/卸载正在进行。'
trap 'rmdir /var/lock/zbox-device-limit-install.lock 2>/dev/null || :' EXIT
trap 'exit 130' HUP INT TERM
(cd "$BASE" && sha256sum -c SHA256SUMS) || die '安装包校验失败。'
[ -d "$BASE/root" ] || die '安装包缺少 root 目录。'
if [ -e "$DIR/.installed" ]; then
    die '已安装。为保留可追溯的回退关系，请先用 uninstall.sh --restore 恢复，再安装新版本。'
fi
# Refuse additional old autoloaders: only the known named firewall include is migrated.
extra=$(uci show firewall | awk -F= '/\.path=/ && /zbox-device-limit/ && $1!="firewall.zbox_device_limit.path" {print}')
[ -z "$extra" ] || die "发现其他旧加载项，请先检查：$extra"
for f in /etc/rc.local /etc/crontabs/root; do
    if [ -f "$f" ] && grep -v '^[[:space:]]*#' "$f" | grep -q 'zbox-device-limit'; then
        die "发现 $f 中的旧加载命令，请移除重复加载命令后重试。"
    fi
done
mkdir -p "$BACKUPS"
backup="$BACKUPS/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup/files"
cp "$BASE/manifest.txt" "$backup/manifest.txt"
# Runtime-only files also need exact restoration on rollback.
printf '%s\n' etc/zbox-device-limit/rules.nft etc/zbox-device-limit/config.good etc/zbox-device-limit/rules.nft.previous etc/zbox-device-limit/rules.nft.new etc/zbox-device-limit/config.good.new etc/zbox-device-limit/.installed >> "$backup/manifest.txt"
: > "$backup/absent"
while IFS= read -r path; do
    case "$path" in ''|/*|*..*) die '非法安装清单';; esac
    if [ -e "/$path" ]; then
        [ -f "/$path" ] && [ ! -L "/$path" ] || die "目标不是普通文件: /$path"
        mkdir -p "$backup/files/$(dirname "$path")"
        cp -p "/$path" "$backup/files/$path"
    else echo "$path" >> "$backup/absent"; fi
done < "$backup/manifest.txt"
# Complete legacy snapshot, including firewall.before and prior rule backups.
[ ! -d "$DIR" ] || tar -czf "$backup/legacy-directory.tar.gz" -C /etc zbox-device-limit
cp /etc/openwrt_release "$backup/openwrt_release"
uci export firewall > "$backup/firewall.full.uci"
awk '/^config / {take=($0=="config include '\''zbox_device_limit'\''")} take {print}' "$backup/firewall.full.uci" > "$backup/firewall.section.uci"
if uci -q get firewall.zbox_device_limit >/dev/null; then
    [ "$(uci get firewall.zbox_device_limit)" = include ] || die '同名防火墙配置不是 include，停止。'
fi
if nft list table bridge zbox_device_limit > "$backup/runtime.nft" 2>/dev/null; then
    echo 1 > "$backup/active"
else
    : > "$backup/runtime.nft"; echo 0 > "$backup/active"
fi
old_enabled=0
if [ -x /etc/init.d/zbox-device-limit ] && /etc/init.d/zbox-device-limit enabled; then old_enabled=1; fi
echo "$old_enabled" > "$backup/service-enabled"

if [ -n "$candidate_input" ]; then
    cp "$candidate_input" "$backup/candidate.uci"
elif [ -f /etc/config/zbox-device-limit ]; then
    cp /etc/config/zbox-device-limit "$backup/candidate.uci"
elif [ -f "$DIR/rules.nft" ]; then
    enabled=$(uci -q get firewall.zbox_device_limit.enabled || cat "$backup/active")
    case "$enabled" in 0|1) :;; *) die '旧 enabled 不是 0/1';; esac
    awk -v enabled="$enabled" -f "$BASE/migrate.awk" "$DIR/rules.nft" > "$backup/candidate.uci" ||
        die "迁移未通过，原系统未改动。备份：$backup；请参阅 README 的手工迁移。"
else
    cp "$BASE/root/etc/config/zbox-device-limit" "$backup/candidate.uci"
fi
cp "$BASE/restore.sh" "$backup/restore.sh"
chmod 700 "$backup/restore.sh"
changed=0
success=0
cleanup() {
    code=$?
    trap - EXIT HUP INT TERM
    if [ "$changed" = 1 ] && [ "$success" != 1 ]; then
        echo '安装失败，开始恢复安装前状态。' >&2
        sh "$backup/restore.sh" "$backup" || echo "恢复失败，请运行：sh $backup/restore.sh $backup" >&2
    fi
    rmdir /var/lock/zbox-device-limit-install.lock 2>/dev/null || :
    exit "$code"
}
trap cleanup EXIT
changed=1
while IFS= read -r path; do
    mkdir -p "/$(dirname "$path")"
    cp "$BASE/root/$path" "/$path"
    case "$path" in etc/init.d/*|etc/hotplug.d/*|usr/libexec/*|*.sh) chmod 755 "/$path";; *) chmod 644 "/$path";; esac
done < "$BASE/manifest.txt"
cp "$backup/candidate.uci" /etc/config/zbox-device-limit
chmod 600 /etc/config/zbox-device-limit
# Last-good is established only after the first apply. Keep pre-install restoration separate.
rm -f "$DIR/config.good"
"$DIR/load.sh" check
uci -q delete firewall.zbox_device_limit || :
uci set firewall.zbox_device_limit=include
uci set firewall.zbox_device_limit.type='script'
uci set firewall.zbox_device_limit.path='/etc/zbox-device-limit/load.sh'
uci set firewall.zbox_device_limit.fw4_compatible='1'
uci set firewall.zbox_device_limit.enabled='1'
uci commit firewall
"$DIR/load.sh"
/etc/init.d/zbox-device-limit enable
/etc/init.d/rpcd restart
# Allow rpcd a bounded startup interval; do not reload the entire firewall/network.
ready=0
for attempt in 1 2 3 4 5; do
    if ubus -S list luci.zbox-device-limit | grep -qx luci.zbox-device-limit; then ready=1; break; fi
    sleep 1
done
[ "$ready" = 1 ] || die 'rpcd 未注册后端。'
echo "$backup" > "$DIR/.installed"
success=1
echo "安装完成：网络 → 设备限速。请退出 LuCI 后重新登录。"
echo "原始备份：$backup"
echo "恢复旧方案：sh $BASE/uninstall.sh --restore"
