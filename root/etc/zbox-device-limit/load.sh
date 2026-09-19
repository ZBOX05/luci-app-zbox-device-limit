#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
DIR=/etc/zbox-device-limit
STATE=/tmp/zbox-device-limit
LOCK=/var/lock/zbox-device-limit.lock
[ "$(id -u)" = 0 ] || exit 1
mkdir -p "$STATE" /var/lock
# BusyBox lock is not required. Never steal a possibly live writer's lock.
mkdir "$LOCK" 2>/dev/null || { echo '设备限速正在应用配置，请稍后重试。' >&2; exit 1; }
echo "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
trap 'exit 130' HUP INT TERM
rollback_config() {
    if [ -f "$DIR/config.good" ]; then
        cp "$DIR/config.good" /etc/config/zbox-device-limit.rollback &&
            mv /etc/config/zbox-device-limit.rollback /etc/config/zbox-device-limit
    fi
}
fail() {
    cp "$LOCK/error" "$STATE/last-error" 2>/dev/null || :
    cat "$LOCK/error" >&2
    rollback_config || echo '恢复 UCI 失败，请检查存储空间。' >&2
    logger -t zbox-device-limit 'Apply failed; previous rules retained; inspect /tmp/zbox-device-limit/last-error'
    exit 1
}
mode=${1:-apply}
case "$mode" in apply|check|stop) :;; *) echo 'Usage: load.sh [apply|check|stop]' >&2; exit 2;; esac
active=0
if nft list table bridge zbox_device_limit > "$LOCK/old.nft" 2>/dev/null; then active=1; fi
: > "$LOCK/transaction"
[ "$active" = 0 ] || echo 'delete table bridge zbox_device_limit' > "$LOCK/transaction"
if [ "$mode" != stop ]; then
    if ! "$DIR/generate.sh" > "$LOCK/candidate" 2> "$LOCK/error"; then
        [ "$mode" != check ] || { cat "$LOCK/error" >&2; exit 1; }
        fail
    fi
    enabled=$(uci -q get zbox-device-limit.global.enabled || echo 0)
    # Check generated rules even when currently disabled.
    cat "$LOCK/transaction" "$LOCK/candidate" > "$LOCK/check"
    if ! nft -c -f "$LOCK/check" 2> "$LOCK/error"; then
        [ "$mode" != check ] || { cat "$LOCK/error" >&2; exit 1; }
        fail
    fi
    [ "$mode" != check ] || { echo 'PASS: UCI and nft syntax'; exit 0; }
    [ "$enabled" != 1 ] || cat "$LOCK/candidate" >> "$LOCK/transaction"
    # Stage all persistent writes before changing the kernel table.
    if ! { cp /etc/config/zbox-device-limit "$LOCK/config" &&
        cp "$LOCK/candidate" "$DIR/rules.nft.new" &&
        cp "$LOCK/config" "$DIR/config.good.new"; } 2> "$LOCK/error"; then fail; fi
    if [ -f "$DIR/rules.nft" ]; then
        cp -p "$DIR/rules.nft" "$DIR/rules.nft.previous" 2> "$LOCK/error" || fail
    fi
fi
# Delete + replacement are a SINGLE atomic nft batch; no flush ruleset.
if [ -s "$LOCK/transaction" ]; then
    nft -c -f "$LOCK/transaction" 2> "$LOCK/error" || fail
    nft -f "$LOCK/transaction" 2> "$LOCK/error" || fail
fi
if [ "$mode" != stop ]; then
    if ! { mv "$DIR/rules.nft.new" "$DIR/rules.nft" &&
        mv "$DIR/config.good.new" "$DIR/config.good"; } 2> "$LOCK/error"; then
        : > "$LOCK/restore"
        if nft list table bridge zbox_device_limit >/dev/null 2>&1; then
            echo 'delete table bridge zbox_device_limit' > "$LOCK/restore"
        fi
        [ "$active" = 0 ] || cat "$LOCK/old.nft" >> "$LOCK/restore"
        if [ -s "$LOCK/restore" ]; then
            nft -c -f "$LOCK/restore" && nft -f "$LOCK/restore" || echo '运行规则回滚失败！' >> "$LOCK/error"
        fi
        [ ! -f "$DIR/rules.nft.previous" ] || cp "$DIR/rules.nft.previous" "$DIR/rules.nft"
        fail
    fi
fi
rm -f "$STATE/last-error"
date +%s > "$STATE/last-apply"
