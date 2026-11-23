import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { stripeCash } from './stripe-cash.ts';

describe('stripe cash', () => {
  it('adds the CAD balance and the payouts on their way, ignoring other currencies and paid payouts', async () => {
    const calls: string[] = [];
    const get = async (path: string) => {
      calls.push(path);
      if (path === '/v1/balance') return { available: [{ currency: 'cad', amount: 12000 }, { currency: 'usd', amount: 999 }], pending: [{ currency: 'cad', amount: 3400 }] };
      return { data: [{ status: 'in_transit', currency: 'cad', amount: 50000, arrival_date: 1795000000 }, { status: 'pending', currency: 'cad', amount: 2500, arrival_date: 1794900000 },
        { status: 'paid', currency: 'cad', amount: 7000, arrival_date: 1790000000 }] };
    };
    const c = await stripeCash(get);
    assert.deepEqual(c, { available_cents: 12000, pending_cents: 3400, in_transit_cents: 52500, in_transit_count: 2,
      next_arrival: new Date(1794900000 * 1000).toISOString().slice(0, 10), currency: 'cad' });
    assert.ok(calls.every((p) => p.startsWith('/v1/')));
  });
  it('a payouts list that fails still gives the balance', async () => {
    const get = async (path: string) => { if (path === '/v1/balance') return { available: [], pending: [] }; throw new Error('down'); };
    const c = await stripeCash(get);
    assert.equal(c.available_cents, 0);
    assert.equal(c.in_transit_cents, 0);
    assert.equal(c.next_arrival, null);
  });
});
