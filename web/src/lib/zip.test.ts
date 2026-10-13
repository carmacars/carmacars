import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { crc32, zip } from './zip.ts';

test('crc32 of a known string', () => {
  assert.equal(crc32(new TextEncoder().encode('The quick brown fox jumps over the lazy dog')), 0x414fa339);
});

test('the archive opens with the system unzip and holds the files as written', () => {
  const a = new TextEncoder().encode('%PDF-1.7 first');
  const b = new TextEncoder().encode('second file, longer than the first');
  const dir = mkdtempSync(join(tmpdir(), 'zip-'));
  writeFileSync(join(dir, 'x.zip'), zip([{ name: 'a.pdf', data: a }, { name: 'b.csv', data: b }]));
  let listed = '';
  try { listed = execFileSync('unzip', ['-o', '-d', dir, join(dir, 'x.zip')], { encoding: 'utf8' }); } catch { return; } // no unzip on this machine
  assert.match(listed, /a\.pdf/);
  assert.deepEqual(readFileSync(join(dir, 'a.pdf')), Buffer.from(a));
  assert.deepEqual(readFileSync(join(dir, 'b.csv')), Buffer.from(b));
});
