const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../root/www/luci-static/resources/view/zbox-device-limit/settings.js'), 'utf8');
const start = source.indexOf('o.validate = function(sid, v) {');
const end = source.indexOf('\n        };', start);
assert(start >= 0 && end > start);
const validate = new Function('return (' + source.slice(start + 'o.validate = '.length, end) + '\n})')();
for (const value of ['', null, undefined, 'lan1', 'wl0-ap0', 'wl1-ap0', ['lan1', 'lan2', 'wl0-ap0']]) {
    assert.equal(validate('global', value), true, JSON.stringify(value));
}
for (const value of ['bad port', 'lan1,lan2', 'x'.repeat(16), ['lan1', 'bad port'], 123, ['lan1', '']]) {
    assert.notEqual(validate('global', value), true, JSON.stringify(value));
}
console.log('PASS: empty add editor, scalar/array ports, invalid names');
