'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require poll';

const config = 'zbox-device-limit';
const getStatus = rpc.declare({ object: 'luci.zbox-device-limit', method: 'status', expect: {} });
const getDevices = rpc.declare({ object: 'luci.zbox-device-limit', method: 'devices', expect: {} });
const applyRules = rpc.declare({ object: 'luci.zbox-device-limit', method: 'apply', expect: {} });
const commit = rpc.declare({ object: 'uci', method: 'commit', params: ['config'], reject: true });

function deviceName(mac, savedName, leases, hosts) {
    const key = (mac || '').toLowerCase();
    const host = hosts.find(function(h) { return (h.mac || '').toLowerCase() === key && h.name && h.name !== '*'; });
    if (host) return host.name;
    if (savedName) return savedName;
    const lease = leases.find(function(d) { return (d.mac || '').toLowerCase() === key; });
    return lease && lease.name && lease.name !== '*' ? lease.name : '';
}

function macValid(sid, value) {
    const v = (value || '').toLowerCase();
    if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(v) || v === '00:00:00:00:00:00' || (parseInt(v.slice(0, 2), 16) & 1))
        return '请输入有效的单播 MAC，例如 02:11:22:33:44:55';
    return true;
}

function rateToKB(raw) {
    if (raw == null || raw === '') return raw;
    const n = Number(raw);
    return Number.isFinite(n) ? String(n / 8) : raw;
}

function useKB(option) {
    option.cfgvalue = function(sid) {
        return rateToKB(uci.get(config, sid, option.option));
    };
    option.validate = function(sid, value) {
        if ((value == null || value === '') && option.rmempty) return true;
        if (!/^(0|[1-9][0-9]*)(\.[0-9]+)?$/.test(value || ''))
            return '请输入有效的 KB/s 数值';
        const n = Number(value);
        if (n < 0 || n > 1250000 || !Number.isInteger(n * 8))
            return '范围为 0–1250000 KB/s，最小步进为 0.125 KB/s';
        return true;
    };
    option.write = function(sid, value) {
        uci.set(config, sid, option.option, String(Math.round(Number(value) * 8)));
    };
}

return view.extend({
    load: function() {
        return Promise.all([uci.load(config), getStatus(), getDevices()]).then(function(data) {
            return [data[0], data[1], data[2].devices || [], data[2].hosts || []];
        });
    },
    render: function(data) {
        const m = this.map = new form.Map(config, '设备限速',
            '按 MAC 管理 IPv4 / IPv6。白名单：名单内不限速，其他设备各自使用默认限速。黑名单：仅名单内限速。自定义策略优先于名单模式。0 表示该方向不限速。');
        let s = m.section(form.NamedSection, 'global', 'global', '基本设置');
        let o = s.option(form.Flag, 'enabled', '启用设备限速');
        o.rmempty = false;
        o = s.option(form.ListValue, 'mode', '工作模式');
        o.value('whitelist', '白名单模式');
        o.value('blacklist', '黑名单模式');
        o.rmempty = false;
        ['download', 'upload'].forEach(function(dir) {
            const v = s.option(form.Value, dir + '_rate', dir === 'download' ? '默认下载 (KB/s)' : '默认上传 (KB/s)');
            v.rmempty = false; useKB(v);
        });
        o = s.option(form.Value, 'burst_bytes', '额外突发额度 (bytes)', '保留旧规则的突发额度；测速请持续至少 30 秒。');
        o.datatype = 'range(0,100000000)'; o.rmempty = false;
        o = s.option(form.DynamicList, 'ports', 'LAN / Wi-Fi 成员端口', '首次使用请填写本机实际 LAN/Wi-Fi 成员端口；迁移安装会保留旧端口。不要填写 WAN。');
        o.rmempty = true;
        o.validate = function(sid, v) {
            // DynamicList also validates its empty add-item editor. It is not
            // a configured port. Validate arrays item by item when supplied.
            if (v == null || v === '') return true;
            const ports = Array.isArray(v) ? v : [v];
            return ports.every(function(port) {
                return typeof port === 'string' && /^[a-zA-Z0-9_.:-]{1,15}$/.test(port);
            }) || '端口名称不合法';
        };

        s = m.section(form.GridSection, 'device', '设备策略');
        s.anonymous = true; s.addremove = true;
        s.sortable = true;
        s.description = '拖动每行右侧的排序手柄调整位置，然后点击“保存并应用”保留顺序。';
        s.nodescriptions = true;
        o = s.option(form.Flag, 'enabled', '启用'); o.default = '1'; o.rmempty = false;
        o = s.option(form.Value, 'name', '设备名称');
        o.description = '优先使用 DHCP 静态租约名称；修改静态租约并保存后，刷新本页即可更新。';
        o.cfgvalue = function(sid) {
            return deviceName(uci.get(config, sid, 'mac'), uci.get(config, sid, 'name'), data[2], data[3]);
        };
        o = s.option(form.Value, 'mac', 'MAC 地址'); o.rmempty = false; o.validate = macValid;
        o = s.option(form.ListValue, 'policy', '策略');
        o.value('member', '加入当前名单');
        o.value('custom', '自定义限速');
        o.value('unlimited', '始终不限速');
        o.default = 'member'; o.rmempty = false;
        ['download', 'upload'].forEach(function(dir) {
            const v = s.option(form.Value, dir + '_rate', dir === 'download' ? '下载 (KB/s)' : '上传 (KB/s)');
            v.depends('policy', 'custom');
            v.placeholder = '留空使用默认'; v.rmempty = true;
            useKB(v);
        });
        o = s.option(form.DummyValue, '_lease', 'IP / 设备状态');
        o.cfgvalue = function(sid) {
            const mac = (uci.get(config, sid, 'mac') || '').toLowerCase();
            const lease = data[2].find(function(d) { return d.mac === mac; });
            return lease ? lease.ip + ' / ' + (lease.state === 'reachable' ? '近期可达' : '有租约，在线未确认') : '无当前 DHCP 租约';
        };
        const status = this.statusNode = E('p');
        this.showStatus(data[1]);
        const leases = E('div', { 'class': 'cbi-section' }, [
            E('h3', {}, '从 DHCP 设备添加'),
            E('p', {}, '添加后仍需保存并应用。没有租约的设备可在设备策略中手动添加 MAC。')
        ]);
        data[2].forEach(L.bind(function(d) {
            const button = E('button', { 'class': 'cbi-button cbi-button-add', 'type': 'button',
                'disabled': !L.hasViewPermission(),
                'click': ui.createHandlerFn(this, async function() {
                    await m.save();
                    if (uci.sections(config, 'device').some(function(x) { return (x.mac || '').toLowerCase() === d.mac; })) {
                        ui.addNotification(null, E('p', {}, '此 MAC 已在设备策略中。')); return;
                    }
                    const sid = uci.add(config, 'device');
                    uci.set(config, sid, 'name', deviceName(d.mac, '', data[2], data[3]) || d.ip);
                    uci.set(config, sid, 'mac', d.mac);
                    uci.set(config, sid, 'enabled', '1');
                    uci.set(config, sid, 'policy', 'member');
                    await m.render().then(function(node) { mEl.replaceChildren(node); });
                    button.disabled = true;
                })
            }, '添加');
            leases.appendChild(E('p', {}, [
                E('span', {}, (deviceName(d.mac, '', data[2], data[3]) || '未命名') + ' · ' + d.ip + ' · ' + d.mac + ' '), button
            ]));
        }, this));
        if (!data[2].length) leases.appendChild(E('p', {}, '暂无有效 DHCP 租约。'));
        const mEl = E('div');
        poll.add(L.bind(function() { return getStatus().then(L.bind(this.showStatus, this)); }, this), 10);
        return m.render().then(function(node) {
            mEl.appendChild(node);
            return E('div', {}, [status, mEl, leases]);
        });
    },
    showStatus: function(s) {
        let text = s.active ? '运行状态：规则已加载' : '运行状态：规则未加载';
        text += s.enabled === '1' ? '；配置为启用。' : '；配置为禁用。';
        if (s.error) text += ' 最近应用失败：' + s.error;
        if (s.offloading === '1' || s.hardware_offloading === '1') text += ' 流量分载仍开启，可能影响限速；请在防火墙中关闭后验证。';
        this.statusNode.textContent = text;
    },
    handleSaveApply: async function() {
        await this.map.save();
        await commit(config);
        const result = await applyRules();
        uci.unload(config);
        await uci.load(config);
        this.showStatus(await getStatus());
        if (!result.ok) {
            ui.addNotification(null, E('p', {}, '应用失败，已尝试恢复上次有效配置和规则。请刷新页面后重试。' + (result.message || '')), 'error');
            return;
        }
        ui.addNotification(null, E('p', {}, '已保存并应用设备限速。'));
    },
    handleSave: null,
    handleReset: function() { window.location.reload(); }
});
