import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { freeCash, monthName, monthStep, type Dashboard } from './model.ts';

describe('finance model', () => {
  it('steps months across a year', () => {
    assert.equal(monthStep('2026-01-01', -1), '2025-12-01');
    assert.equal(monthStep('2026-12-01', 1), '2027-01-01');
    assert.equal(monthName('2026-11-01'), 'Nov 2026');
  });
  it('free cash is bank and Stripe less what is held for others; an HST refund is not cash yet', () => {
    const d = { bank: { total_cad_cents: 1000000 }, deposits: { cash_cents: 100000 }, money_out: { owner_payouts: { due_cents: 200000 }, refunds: { owed_cents: 5000 } }, hst: { owed_cents: 30000 } } as unknown as Dashboard;
    assert.equal(freeCash(d, { available_cents: 50000, pending_cents: 20000, in_transit_cents: 10000 }), 1000000 + 80000 - 100000 - 200000 - 5000 - 30000);
    assert.equal(freeCash({ ...d, hst: { ...d.hst, owed_cents: -9000 } } as Dashboard, null), 1000000 - 100000 - 200000 - 5000);
  });
});
