import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

// Release 21b, item 8: every address field on the site has the address lookup (AddressInput, AddressFields or AddressLookup).
// A form with a street-address input, or a field list with an address column that is not of type 'address', fails here.
const ROOT = join(import.meta.dirname, '..', '..');
const files: string[] = [];
const walk = (d: string) => { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) walk(p); else if (/\.tsx?$/.test(n) && !/\.test\.ts$/.test(n)) files.push(p); } };
walk(join(ROOT, 'app')); walk(join(ROOT, 'features'));
const LOOKUP = /AddressInput|AddressFields|AddressLookup/;

test('a form with a street address input has the lookup', () => {
  const bad = files.filter((f) => { const s = readFileSync(f, 'utf8'); return /(street-address|address-line1)/.test(s) && !LOOKUP.test(s); });
  assert.deepEqual(bad.map((f) => f.slice(ROOT.length)), []);
});
test('an address column in a field list is an address field', () => {
  const bad: string[] = [];
  for (const f of files) {
    const s = readFileSync(f, 'utf8');
    for (const m of s.matchAll(/\{ name: '([a-z_]*(?:address|street)[a-z_0-9]*)'[^}]*\}/g)) {
      if (/email|url|ip_/.test(m[1]!)) continue;
      if (!/type: '(address|email)'|input: 'address'/.test(m[0])) bad.push(`${f.slice(ROOT.length)}: ${m[1]}`);
    }
  }
  assert.deepEqual(bad, []);
});
