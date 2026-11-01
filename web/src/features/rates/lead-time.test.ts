import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_TIERS, lineText, pctText, tierFor, tierRange, toRows, toTiers } from './lead-time.ts';

test('the default tiers in words', () => {
  const t = DEFAULT_TIERS;
  assert.deepEqual(t.map((x, i) => `${tierRange(x.from_hours, t[i + 1]?.from_hours ?? null)} ${pctText(x.bps)}`),
    ['Under 24 hours +15%', '24 to 72 hours +10%', '3 to 13 days 0%', '14 days or more −5%']);
});

test('the line says what the database says', () => {
  assert.equal(lineText(1000), 'Short-notice pricing +10%');
  assert.equal(lineText(-500), 'Booked ahead −5%');
  assert.equal(lineText(0), 'No lead-time adjustment');
  assert.equal(pctText(1250), '+12.5%');
});

test('the tier for so many hours, boundaries included', () => {
  const at = (h: number) => tierFor(DEFAULT_TIERS, h).bps;
  assert.deepEqual([-3, 0, 23.99, 24, 71.99, 72, 335.99, 336, 1000].map(at), [1500, 1500, 1500, 1000, 1000, 0, 0, -500, -500]);
});

test('rows typed become tiers, or the first problem', () => {
  assert.deepEqual(toTiers(toRows(DEFAULT_TIERS)), { tiers: DEFAULT_TIERS });
  assert.deepEqual(toTiers([{ from: '0', pct: '+12.5' }, { from: '48', pct: '−2' }]), { tiers: [{ from_hours: 0, bps: 1250 }, { from_hours: 48, bps: -200 }] });
  assert.match((toTiers([{ from: '5', pct: '10' }]) as { error: string }).error, /starts at 0 hours/);
  assert.match((toTiers([{ from: '0', pct: '10' }, { from: '0', pct: '5' }]) as { error: string }).error, /start later/);
  assert.match((toTiers([{ from: '0', pct: '60' }]) as { error: string }).error, /between -50% and \+50%/);
  assert.match((toTiers([{ from: '0', pct: 'ten' }]) as { error: string }).error, /percentage/);
  assert.match((toTiers([]) as { error: string }).error, /at least one/);
});
