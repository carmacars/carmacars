import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { findUnhinted, inFlightOnly } from './disabled-hints.ts';

const SRC = fileURLToPath(new URL('../..', import.meta.url));
const walk = (d: string): string[] => readdirSync(d).flatMap((f) => { const p = join(d, f); return statSync(p).isDirectory() ? walk(p) : p.endsWith('.tsx') ? [p] : []; });

test('the rule: greyed out while running needs no hint; anything else does', () => {
  assert.equal(inFlightOnly('pending'), true);
  assert.equal(inFlightOnly('pending || busy'), true);
  assert.equal(inFlightOnly('pending || !ok'), false);
  assert.equal(findUnhinted('<button disabled={pending} onClick={go}>Save</button>').length, 0);
  assert.equal(findUnhinted('<button disabled={pending || !name} onClick={go}>Save</button>').length, 1);
  assert.equal(findUnhinted('<button disabled={pending || !name} aria-describedby="x-why" onClick={go}>Save</button>').length, 0);
  assert.equal(findUnhinted('<button type="button" disabled>Soon</button>').length, 1);
  assert.equal(findUnhinted('<button onClick={() => { if (a > b) go(); }} disabled={!a}>Go</button>').length, 1);
});

test('every disabled button on every portal says what to do first (aria-describedby to its hint, or a title)', () => {
  const misses = walk(SRC).flatMap((f) => findUnhinted(readFileSync(f, 'utf8')).map((x) => `${relative(SRC, f)}:${x.line} disabled={${x.expr}}`));
  assert.deepEqual(misses, [], `${misses.length} disabled button(s) without a hint: add aria-describedby to a hint that says what to do first (see Propose a change's Send)`);
});
