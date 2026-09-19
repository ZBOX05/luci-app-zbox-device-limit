#!/bin/sh
set -eu
uci set zbox-device-limit.global.enabled='0'
uci commit zbox-device-limit
exec /etc/zbox-device-limit/load.sh
