const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, '../root/www/luci-static/resources/view/zbox-device-limit/settings.js'), 'utf8');
const start = source.indexOf('function rateToKB(');
const end = source.indexOf('\nfunction useKB(', start);
assert(start >= 0 && end > start);
const toKB = new Function(source.slice(start, end) + '\nreturn rateToKB;')();

assert.equal(toKB('4000'), '500');
assert.equal(toKB('4096'), '512');
assert.equal(toKB('1'), '0.125');
assert.equal(toKB('0'), '0');
assert.equal(toKB(''), '');
assert.match(source, /Math\.round\(Number\(value\) \* 8\)/);
assert.match(source, /Number\.isInteger\(n \* 8\)/);
console.log('PASS: KB/s display and lossless Kbit/s storage conversion');
