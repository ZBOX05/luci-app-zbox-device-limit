#!/bin/sh
echo '设备名单已迁移到 LuCI：网络 → 设备限速。'
echo 'rules.nft 由 UCI 生成；请勿再使用旧菜单直接修改。'
echo '命令行查看：uci show zbox-device-limit'
echo '修改 UCI 后：uci commit zbox-device-limit && /etc/zbox-device-limit/load.sh'
