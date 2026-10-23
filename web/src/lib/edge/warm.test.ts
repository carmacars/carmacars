import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WARM_SITE, warmBatch, warmDone, warmPaths, warmValue } from './warm.ts';

test('warm-up: home, the fleet page, the site pages and hubs, then each car page once, in the fleet order, bounded', () => {
  const rows = [{ slug: 'kia-forte' }, { slug: 'honda-civic' }, { slug: 'kia-forte' }, { slug: '../admin' }, { slug: null }];
  assert.deepEqual(warmPaths(rows), ['/', '/cars', ...WARM_SITE, '/cars/kia-forte', '/cars/honda-civic']);
  assert.ok(WARM_SITE.includes('/faq'));
  assert.equal(warmPaths(Array.from({ length: 50 }, (_, i) => ({ slug: `car-${i}` })), 10).length, 10);
});

test('warm-up progress belongs to one deploy', () => {
  assert.equal(warmDone(null, 7), 0);
  assert.equal(warmDone(warmValue(7, 42), 7), 42);
  assert.equal(warmDone(warmValue(6, 42), 7), 0, 'another deploy starts over');
  assert.equal(warmDone(warmValue(123456789, 95), 123456789), 95);
});

test('warm-up batch: a few at a time, stops at the budget, resumes where it stopped, survives a failing page', async () => {
  const paths = Array.from({ length: 10 }, (_, i) => `/p${i}`);
  let t = 0; let open = 0; let most = 0; const seen: string[] = [];
  const get = async (p: string) => { open++; most = Math.max(most, open); seen.push(p); t += 100; await Promise.resolve(); open--; if (p === '/p3') throw new Error('500'); };
  const next = await warmBatch(paths, 0, get, { concurrency: 2, budgetMs: 450, gapMs: 0, now: () => t });
  assert.ok(next > 0 && next < 10, `stopped at the budget (${next})`);
  assert.ok(most <= 2, 'never more than the concurrency');
  const rest = await warmBatch(paths, next, get, { concurrency: 2, budgetMs: 10_000, gapMs: 0, now: () => t });
  assert.equal(rest, 10);
  assert.deepEqual([...new Set(seen)].sort(), [...paths].sort(), 'every page once, the failing one included');
  assert.equal(seen.length, new Set(seen).size, 'none twice');
});
