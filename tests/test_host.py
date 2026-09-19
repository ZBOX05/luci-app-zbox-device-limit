#!/usr/bin/env python3
"""Host regression tests. Python 3 + bash + awk + node; no router is modified.

Run: python tests/test_host.py --bash /path/to/bash
The shell and nft stubs test control flow, not Linux nft kernel compatibility.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

BASE = Path(__file__).resolve().parents[1]
args, remaining = argparse.ArgumentParser().parse_known_args()
if '--bash' in remaining:
    i = remaining.index('--bash')
    BASH = remaining[i + 1]
    del remaining[i:i + 2]
else:
    BASH = shutil.which('bash')


def shellpath(p):
    s = str(p).replace('\\', '/')
    return '/' + s[0].lower() + s[2:] if len(s) > 1 and s[1] == ':' else s


def run(script, *argv):
    return subprocess.run([BASH, shellpath(script), *argv], capture_output=True, text=True, encoding='utf-8')


class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.p = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def generate(self, changes=None, devices=None):
        global_ = dict(enabled='1', mode='whitelist', upload_rate='4000', download_rate='8000', burst_bytes='128000')
        global_.update(changes or {})
        devs = devices or []
        values = {f'global.{k}': v for k, v in global_.items()}
        for i, d in enumerate(devs):
            values.update({f'd{i}.{k}': v for k, v in d.items()})
        lib = self.p / 'functions.sh'
        lib.write_text('config_load() { :; }\nconfig_list_foreach() { "$3" lan1; "$3" wl0-ap0; }\n'
                       'config_foreach() { if [ "$2" = global ]; then "$1" global; else\n' +
                       ''.join(f'"$1" d{i}\n' for i in range(len(devs))) + ':; fi; }\n'
                       'config_get() { local v; case "$2.$3" in\n' +
                       ''.join(f'{shlex.quote(k)}) v={shlex.quote(str(v))};;\n' for k, v in values.items()) +
                       '*) v=${4:-};;\nesac\nexport "$1=$v"\n}\n', encoding='utf-8')
        source = (BASE / 'root/etc/zbox-device-limit/generate.sh').read_text(encoding='utf-8')
        source = source.replace('. /lib/functions.sh', '. ' + shlex.quote(shellpath(lib)))
        path = self.p / 'generate.sh'
        path.write_text(source, encoding='utf-8', newline='\n')
        return run(path)

    def test_syntax_all_shell_and_js_json(self):
        for p in BASE.rglob('*'):
            if p.is_file() and (p.suffix == '.sh' or (p.read_bytes().startswith(b'#!/bin/sh'))):
                r = subprocess.run([BASH, '-n', shellpath(p)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, str(p) + r.stderr)
            if p.suffix == '.json':
                json.loads(p.read_text(encoding='utf-8'))
        r = subprocess.run(['node', '--check', str(BASE / 'root/www/luci-static/resources/view/zbox-device-limit/settings.js')], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_whitelist_independent_meters_and_hooks(self):
        r = self.generate(devices=[dict(mac='02:11:22:33:44:55', policy='member')])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('hook input priority -10', r.stdout)
        self.assertIn('hook output priority -10', r.stdout)
        self.assertIn('ether saddr 02:11:22:33:44:55 counter return', r.stdout)
        self.assertIn('update @upload_per_mac { ether saddr timeout 10m limit rate over 500000 bytes/second', r.stdout)
        self.assertIn('update @download_per_mac { ether daddr timeout 10m limit rate over 1000000 bytes/second', r.stdout)

    def test_blacklist_custom_zero_and_disabled(self):
        r = self.generate({'mode': 'blacklist'}, [
            dict(mac='02:11:22:33:44:55', policy='custom', upload_rate='1000', download_rate='0'),
            dict(mac='02:11:22:33:44:66', policy='member', enabled='0'),
            dict(mac='02:11:22:33:44:77', policy='member')])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn('update @', r.stdout)
        self.assertNotIn('02:11:22:33:44:66', r.stdout)
        self.assertIn('ether saddr 02:11:22:33:44:55 limit rate over 125000 bytes/second', r.stdout)
        self.assertNotIn('ether daddr 02:11:22:33:44:55 limit', r.stdout)
        self.assertIn('ether saddr 02:11:22:33:44:77 limit rate over 500000', r.stdout)

    def test_reject_bad_mac_duplicate_rate_and_injection(self):
        for d in [dict(mac='ff:ff:ff:ff:ff:ff'), dict(mac='00:00:00:00:00:00'), dict(mac='02:11:22:33:44:55; flush ruleset'),
                  dict(mac='02:11:22:33:44:55', upload_rate='-1'), dict(mac='02:11:22:33:44:55', upload_rate='999999999999999'),
                  dict(mac='02:11:22:33:44:55', policy='x')]:
            self.assertNotEqual(self.generate(devices=[d]).returncode, 0, d)
        self.assertNotEqual(self.generate(devices=[dict(mac='02:11:22:33:44:aa'), dict(mac='02:11:22:33:44:AA')]).returncode, 0)
        self.assertNotEqual(self.generate({'mode': 'bad'}).returncode, 0)
        self.assertNotEqual(self.generate({'upload_rate': '01'}).returncode, 0)

    def test_custom_does_not_fall_through_default(self):
        r = self.generate(devices=[dict(mac='02:11:22:33:44:55', policy='custom', upload_rate='0', download_rate='1000')])
        self.assertEqual(r.returncode, 0, r.stderr)
        for direction, addr in [('upload', 'saddr'), ('download', 'daddr')]:
            self.assertLess(r.stdout.index(f'ether {addr} 02:11:22:33:44:55 counter return'), r.stdout.index(f'update @{direction}_per_mac'))

    def migrate(self, legacy):
        fixture = self.p / 'legacy.nft'
        wrapper = self.p / 'migrate.sh'
        wrapper.write_text('awk -v enabled=1 -f ' + shlex.quote(shellpath(BASE / 'migrate.awk')) + ' ' + shlex.quote(shellpath(fixture)) + '\n')
        fixture.write_text(legacy)
        return run(wrapper)

    def test_migration_and_unknown_rule(self):
        legacy = (BASE / 'tests/legacy.nft').read_text()
        r = self.migrate(legacy)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("upload_rate '4096'", r.stdout)
        self.assertIn("burst_bytes '128000'", r.stdout)
        self.assertIn("mac '02:11:22:33:44:55'", r.stdout)
        self.assertNotEqual(self.migrate(legacy.replace('counter\n', 'ip saddr 192.0.2.1 accept\n', 1)).returncode, 0)

    def test_inline_meter_migrates_identically(self):
        legacy = (BASE / 'tests/legacy.nft').read_text()
        meter = re.sub(r'    set (upload|download)_per_mac \{[^}]*\}\n', '', legacy)
        meter = re.sub(r'update @(upload|download)_per_mac \{', r'meter \1_per_mac size 4096 {', meter)
        # Exact numeric form from an inline-meter fixture.
        meter = meter.replace('500 kbytes/second burst 125 kbytes', '512000 bytes/second burst 128000 bytes')
        before, after = self.migrate(legacy), self.migrate(meter)
        self.assertEqual(after.returncode, 0, after.stderr)
        self.assertEqual(before.stdout, after.stdout)

    def test_inline_meter_rejects_mismatch_and_unknown_semantics(self):
        legacy = (BASE / 'tests/legacy.nft').read_text()
        meter = re.sub(r'    set (upload|download)_per_mac \{[^}]*\}\n', '', legacy)
        meter = re.sub(r'update @(upload|download)_per_mac \{', r'meter \1_per_mac size 4096 {', meter)
        cases = [meter.replace('meter upload_per_mac', 'meter download_per_mac'),
                 meter.replace('size 4096', 'size 8192'),
                 meter.replace('ether saddr timeout', 'ether daddr timeout'),
                 meter.replace('counter drop', 'counter accept'),
                 re.sub(r'update @(upload|download)_per_mac \{', r'meter \1_per_mac size 4096 {', legacy),
                 re.sub(r'    set upload_per_mac \{[^}]*\}\n', '', legacy)]
        for candidate in cases:
            self.assertNotEqual(self.migrate(candidate).returncode, 0)

    def test_loader_atomic_apply_and_failure_retains_old(self):
        # Remap fixed router paths into an isolated directory; stub nft deliberately.
        etc = self.p / 'etc'; private = etc / 'zbox-device-limit'; conf = etc / 'config'
        private.mkdir(parents=True); conf.mkdir()
        bin_ = self.p / 'bin'; bin_.mkdir()
        state = self.p / 'kernel'; state.write_text('OLD\n')
        config = conf / 'zbox-device-limit'; config.write_text('NEW-CONFIG\n')
        (private / 'config.good').write_text('OLD-CONFIG\n')
        (private / 'rules.nft').write_text('OLD\n')
        (private / 'generate.sh').write_text('#!/bin/sh\necho NEW\n')
        (bin_ / 'id').write_text('#!/bin/sh\necho 0\n')
        (bin_ / 'uci').write_text('#!/bin/sh\necho 1\n')
        (bin_ / 'logger').write_text('#!/bin/sh\nexit 0\n')
        failure = self.p / 'fail'
        check_failure = self.p / 'check-fail'
        (bin_ / 'nft').write_text('#!/bin/sh\nstate=' + shlex.quote(shellpath(state)) + '\n'
            'if [ "$1" = list ]; then cat "$state"; exit 0; fi\n'
            'if [ "$1" = -c ]; then [ ! -f ' + shlex.quote(shellpath(check_failure)) + ' ]; exit $?; fi\n'
            'if [ -f ' + shlex.quote(shellpath(failure)) + ' ]; then echo INJECTED-FAIL >&2; exit 1; fi\n'
            'cat "$2" > "$state"\n')
        for p in [*(bin_.iterdir()), private / 'generate.sh']:
            p.chmod(0o755)
        src = (BASE / 'root/etc/zbox-device-limit/load.sh').read_text()
        src = src.replace('/etc/', shellpath(etc) + '/').replace('/tmp/zbox-device-limit', shellpath(self.p / 'status')).replace('/var/lock', shellpath(self.p / 'locks'))
        src = src.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'PATH=' + shlex.quote(shellpath(bin_)) + ':/usr/bin:/bin')
        loader = self.p / 'load.sh'; loader.write_text(src)
        check_failure.touch()
        r = run(loader, 'check')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(config.read_text(), 'NEW-CONFIG\n', 'check must never revert UCI')
        self.assertEqual(state.read_text(), 'OLD\n')
        check_failure.unlink()
        failure.touch()
        r = run(loader)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(state.read_text(), 'OLD\n')
        self.assertEqual(config.read_text(), 'OLD-CONFIG\n')
        self.assertEqual((private / 'rules.nft').read_text(), 'OLD\n')
        failure.unlink(); config.write_text('NEW-CONFIG\n')
        r = run(loader)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(state.read_text(), 'delete table bridge zbox_device_limit\nNEW\n')
        self.assertEqual((private / 'config.good').read_text(), 'NEW-CONFIG\n')
        lock = self.p / 'locks/zbox-device-limit.lock'; lock.mkdir()
        before = state.read_text()
        self.assertNotEqual(run(loader).returncode, 0)
        self.assertEqual(state.read_text(), before)
        lock.rmdir()
        (bin_ / 'uci').write_text('#!/bin/sh\necho 0\n')
        r = run(loader)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(state.read_text(), 'delete table bridge zbox_device_limit\n')


if __name__ == '__main__':
    unittest.main(argv=['test_host.py'] + remaining, verbosity=2)
