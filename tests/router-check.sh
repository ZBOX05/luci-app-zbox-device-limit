#!/bin/sh
# Read-only preflight and installed backend smoke test.
set -eu
echo '--- OpenWrt ---'
cat /etc/openwrt_release
nft --version
echo '--- Configuration and rule syntax (does not apply) ---'
/etc/zbox-device-limit/load.sh check
echo '--- RPC signature and calls ---'
ubus -v list luci.zbox-device-limit
ubus call luci.zbox-device-limit status '{}'
ubus call luci.zbox-device-limit devices '{}'
echo '--- Persistence ---'
/etc/init.d/zbox-device-limit enabled
uci show firewall.zbox_device_limit
echo '--- Live table (may be absent if disabled) ---'
nft list table bridge zbox_device_limit || [ "$(uci get zbox-device-limit.global.enabled)" = 0 ]
echo 'PASS: preflight. Throughput/IPv6/Mihomo/reboot tests still required; see README.'
