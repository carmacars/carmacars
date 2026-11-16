import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pctLabel, tipChoiceCents, tipShareWords } from './tips.ts';

const fmt = (c: number) => `$${(c / 100).toFixed(2)}`;
test('tips: the split in words and the renter\'s choice', () => {
  assert.equal(tipShareWords([{ staff_id: 'a', name: 'Ana', role: 'sales', amount_cents: 501 }, { staff_id: null, name: 'CarmaCars', role: 'company', amount_cents: 500 }], fmt),
    'Ana $5.01 (the salesperson), CarmaCars $5.00');
  assert.equal(tipShareWords([{ staff_id: 'b', name: 'Bo', role: 'both', amount_cents: 1500 }], fmt), 'Bo $15.00 (sold it and did the handover)');
  const o = { options: [{ percent_bps: 1000, cents: 1867 }, { percent_bps: 1500, cents: 2801 }, { percent_bps: 2000, cents: 3735 }] };
  assert.equal(tipChoiceCents(o, '1500', ''), 2801);
  assert.equal(tipChoiceCents(o, 'custom', '12.50'), 1250);
  assert.equal(tipChoiceCents(o, 'custom', '0.50'), null);
  assert.equal(tipChoiceCents(o, 'custom', 'abc'), null);
  assert.equal(pctLabel(1500), '15%');
});
