import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { activeRange, addDays, rangeFor, rangeHref } from './range.ts';

describe('quick ranges', () => {
  it('counts days back from today, today included', () => {
    assert.deepEqual(rangeFor(1, '2026-11-07'), { from: '2026-11-07', to: '2026-11-07' });
    assert.deepEqual(rangeFor(7, '2026-11-07'), { from: '2026-11-01', to: '2026-11-07' });
    assert.deepEqual(rangeFor(30, '2026-03-02'), { from: '2026-02-01', to: '2026-03-02' });
    assert.equal(addDays('2026-12-31', 1), '2027-01-01');
  });
  it('knows which range the dates are', () => {
    assert.equal(activeRange('2026-11-01', '2026-11-07', '2026-11-07'), '7');
    assert.equal(activeRange('2026-11-01', undefined, '2026-11-07'), '7');
    assert.equal(activeRange('2026-11-07', '2026-11-07', '2026-11-07'), 'today');
    assert.equal(activeRange('2026-10-09', '2026-11-07', '2026-11-07'), '30');
    assert.equal(activeRange('2026-08-10', '2026-11-07', '2026-11-07'), '90');
    assert.equal(activeRange('2026-09-01', '2026-09-30', '2026-11-07'), 'custom');
    assert.equal(activeRange(undefined, undefined, '2026-11-07'), null);
    assert.equal(activeRange('junk', '', '2026-11-07'), null);
  });
  it('builds the address, keeping the other filters and dropping the cursor', () => {
    const h = rangeHref('/admin/visitors', { view: 'history', city: 'Toronto', cursor: 'x', from: '2026-01-01', source: undefined }, { from: '2026-11-01', to: '2026-11-07' });
    const q = new URL(h, 'https://example.test').searchParams;
    assert.equal(q.get('view'), 'history'); assert.equal(q.get('city'), 'Toronto'); assert.equal(q.get('from'), '2026-11-01'); assert.equal(q.get('to'), '2026-11-07');
    assert.equal(q.has('cursor'), false); assert.equal(q.has('source'), false);
    assert.ok(h.startsWith('/admin/visitors?'));
  });
});
