# luci-app-zbox-device-limit

实验性的 OpenWrt LuCI 按 MAC 设备限速应用。使用现代 LuCI JavaScript、rpcd/ubus、UCI 与 nftables bridge family。

**用于设备速率上限，不是 SQM/CAKE 的替代品。** 目标环境为 OpenWrt 25.12；不同硬件、网络拓扑和代理模式需要自行验证。提供源码和离线脚本安装，不是已签名 APK，也不是 OpenWrt 官方软件包。

## 功能

- 网络 → 设备限速：总开关、白名单/黑名单、默认上下行和每设备自定义速率。
- 每 MAC 独立计量，IPv4/IPv6 共用该设备同一方向额度。
- 按 MAC 显示 DHCP 静态租约名称，支持动态租约名称和手工添加。
- 拖动设备顺序后保存；名称和端口输入校验修复已包含。
- UCI 生成规则、nft 预检、单批次替换私有表、失败恢复和安装前备份。
- 可迁移指定旧结构的内联 meter 或显式 dynamic set 规则；未知规则拒绝迁移。

## 与其他限速方式的区别

| 方案 | 识别和执行方式 | 适合场景 | 主要限制 |
|---|---|---|---|
| 本项目 | 客户端 MAC；bridge input/output 上超额丢包 | 同桥接 LAN 下给设备设置速度上限 | 依赖能看到客户端 MAC 的路径；不负责排队公平性或延迟管理 |
| 按 IP 的限速器 | 按 IPv4/IPv6 地址识别；可采用丢包或排队整形 | 多网段、IP 转发、VPN 等 | 必须覆盖相关地址；NAT/代理可能改变观察到的地址 |
| tc HTB/HFSC 等整形 | 对分类后的流量排队调度 | 更平滑的速率控制、带宽分配 | 配置和流量分类更复杂；不限定只能按 IP 分类 |
| SQM/CAKE | 瓶颈处整形、公平排队和主动队列管理 | 降低满载时延迟、改善多连接共享 | 需要合适的瓶颈带宽设置和 CPU；不等同于设备黑白名单硬上限 |

按 MAC/IP 分类与丢包/整形是两个独立选择。本项目选择了 MAC + nft token-bucket policing。短时允许突发，长期 TCP 有效吞吐可能低于配置；不能把它称为保证带宽或无延迟限速。

## 适用条件

客户端流量必须经过所选 bridge 成员端口和本机 input/output 路径。保持 flow offloading 和可能绕过规则的硬件加速关闭并验证。支持的识别依据是 MAC，不依赖 IPv6 临时地址，但随机 MAC、更换网卡或下级路由/NAT 会影响识别。

普通 LAN↔LAN 纯桥转发不在当前覆盖范围；访问路由器本机的 IP 流量可能被限速。Mihomo 等代理能否被覆盖取决于实际路径，不保证任意代理模式/硬件兼容。不会修改代理标记、路由、DNS 或 tc 队列。

## 安装

路由器需已有现代 LuCI、rpcd、UCI、nft、OpenWrt shell 库和 jshn，以及 nft bridge/limit/dynamic-set 内核支持。安装器只做依赖检查，不修改软件源或自动下载模块。

将整个仓库目录复制到路由器，或在电脑运行 `python tools/build.py` 生成安装压缩包。以下 `ROUTER_ADDRESS` 替换为实际地址：

```sh
scp -O dist/luci-app-zbox-device-limit-1.0.3.tar.gz root@ROUTER_ADDRESS:/tmp/
ssh root@ROUTER_ADDRESS
cd /tmp
tar -xzf luci-app-zbox-device-limit-1.0.3.tar.gz
cd luci-app-zbox-device-limit
sh install.sh
```

重新登录 LuCI，打开网络 → 设备限速。**新安装默认关闭且不预设个人端口或设备。** 先填写本机实际 LAN/Wi-Fi 成员端口，再启用并保存。可在路由器使用 `bridge link` 或查看 `/sys/class/net/桥名称/brif/` 确认成员；不能把桥自身名称或 WAN 随意填入。

如已有 `/etc/zbox-device-limit/rules.nft`，安装器先备份再迁移其名单、速率、端口和开关。支持的格式见 `tests/legacy.nft` 与 `migrate.awk`。已有 UCI 配置优先保留。无法识别的旧规则会停止，原系统不变；可审查后提供完整 UCI 配置：`sh install.sh --config /tmp/config.uci`。

安装只接管本应用文件及 `firewall.zbox_device_limit` include，不重启网络或整个防火墙。重复安装会停止；目前升级应先导出配置、恢复旧版本，再用导出配置安装新包。不要直接用安装脚本覆盖一个已安装版本。

## 配置语义

| 设备策略 | 白名单模式 | 黑名单模式 |
|---|---|---|
| 未列入或该行禁用 | 每 MAC 使用默认额度 | 不限速 |
| 加入当前名单 | 不限速 | 使用默认额度 |
| 自定义限速 | 使用设备设置 | 使用设备设置 |
| 始终不限速 | 不限速 | 不限速 |

自定义方向留空继承默认，0 表示该方向不限速。LuCI 使用常见的十进制 `KB/s`（1 KB/s = 1000 bytes/second）；例如 500 KB/s 对应 500000 bytes/second。为兼容旧版本，UCI 内部仍保存 Kbit/s，页面会自动无损换算，升级后不需要重填。旧 nft 的 kbytes 使用 1024 bytes，迁移仍保留实际字节速率。名单模式改变会改变 member 行含义，不改变显式自定义策略。

静态 DHCP 名称优先，其次已保存名称和动态租约名称；静态名称更新后刷新页面。静态租约不表示在线，动态租约也只证明近期租用过地址。设备状态以租约及邻居可达信息呈现，不承诺实时在线检测。

## 备份、恢复与卸载

安装备份位于 `/etc/zbox-device-limit-backups/时间-PID/`，包含真实设备信息，仅留在路由器，不应上传仓库。日常应用保留一代 `rules.nft.previous` 与 `config.good`。

```sh
/etc/zbox-device-limit/load.sh check  # 只检查
/etc/zbox-device-limit/disable.sh    # 保存禁用并应用
/etc/zbox-device-limit/load.sh stop # 临时撤下表，不改持久开关
sh uninstall.sh --restore          # 恢复安装前方案
sh uninstall.sh --remove           # 移除应用，不重新开启旧方案
```

回滚只还原本应用对应的 firewall include，不整体覆盖其他防火墙更改。卸载时另存当前配置。备份不自动删除。意外断电/SIGKILL 不保证完整事务；锁残留需先确认进程已退出再清理。安装、应用时避免多个管理员同时编辑。

## 测试及已知限制

电脑执行：

```sh
python tests/test_host.py --bash /bin/bash
node tests/ports-validation.cjs
node tests/device-names.cjs
```

本地测试使用模拟 nft 验证控制流程，不等同于真实 Linux 内核、LuCI 浏览器或吞吐测试。安装后运行 `sh tests/router-check.sh`，再验证开关、黑白名单、自定义/零速率、两个客户端并发、IPv4/IPv6、代理直连/代理路径、防火墙 reload 和重启。

至少持续测速 30 秒，查看 `nft list chain bridge zbox_device_limit upload` 和 `download` 的计数器。重载会重置计数器与桶。尚未完成跨设备/多固件兼容性认证。

## 参考与许可

- [nftables bridge hooks](https://wiki.nftables.org/wiki-nftables/index.php/Bridge_filtering)
- [nftables limit / token bucket](https://netfilter.org/projects/nftables/manpage.html)
- [OpenWrt SQM](https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm)

MIT，见 LICENSE。项目名称保留为兼容现有文件路径；仓库不包含真实路由器配置、设备名单、账户凭据或运行日志。

## OpenWrt 配置备份

在“系统 → 备份与更新 → 配置”的自定义保留列表加入：

```text
/etc/config/zbox-device-limit
```

保存该列表后，到“操作”生成备份。应用代码建议从本仓库重新安装，避免把旧版本代码恢复到不兼容的新固件。`rules.nft`、`config.good`、历史规则和 `/etc/zbox-device-limit-backups/` 都不需要进入常规 sysupgrade 备份。
