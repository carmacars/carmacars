import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chartModel, duration, historyFilters, historyHref, historyParams, pct, place, sourceWords, topSourceWords } from './history.ts';

// Visitor history (migration 0118): the filters as they travel in the address, the words and the chart.
test('filters: checked, trimmed, choices from their lists, anything else dropped', () => {
  assert.deepEqual(historyFilters({ from: '2026-10-01', to: 'yesterday', device: 'phone', visitor: 'old', converted: 'booking', bots: '1', q: 'x', source: '  google  ' }),
    { from: '2026-10-01', device: 'phone', converted: 'booking', bots: '1', source: 'google' });
  assert.deepEqual(historyFilters({ country: 'Canada' }), {});
  assert.deepEqual(historyFilters({ country: 'ca', city: ['Ottawa', 'Kingston'] }), { country: 'ca', city: 'Ottawa' });
  assert.equal(historyFilters({ landing: 'x'.repeat(500) }).landing!.length, 300);
  assert.deepEqual(historyFilters({ contact: 'yes', known: '1' }), { known: '1' });
});

test('params: the cursor only when it has the shape the database gives', () => {
  assert.deepEqual(historyParams({ cursor: '2026-10-23T14:01:02.123456+00:00|0b6f0e0a-5a8f-4c55-9f0e-2a4c2b9d1e11' }),
    { cursor: '2026-10-23T14:01:02.123456+00:00|0b6f0e0a-5a8f-4c55-9f0e-2a4c2b9d1e11' });
  assert.deepEqual(historyParams({ cursor: "x'; drop table" }), {});
});

test('href: the filters in a fixed order, the cursor last', () => {
  assert.equal(historyHref({}), '/admin/live/history');
  assert.equal(historyHref({ device: 'phone', from: '2026-10-01' }, 'c|1'), '/admin/live/history?from=2026-10-01&device=phone&cursor=c%7C1');
});

test('duration in words', () => {
  assert.equal(duration(0), '0 s');
  assert.equal(duration(45), '45 s');
  assert.equal(duration(180), '3 min');
  assert.equal(duration(200), '3 min 20 s');
  assert.equal(duration(3900), '1 h 5 min');
  assert.equal(duration(7200), '2 h');
  assert.equal(duration(null), '0 s');
});

test('source in words', () => {
  const r = { source: 'google.com', utm_source: null, utm_medium: null, utm_campaign: null, from_ad: false, consent: 'analytics' };
  assert.equal(sourceWords(r), 'google.com');
  assert.equal(sourceWords({ ...r, source: 'direct' }), 'Direct');
  assert.equal(sourceWords({ ...r, source: 'not recorded', consent: 'essential' }), 'Not recorded (necessary cookies only)');
  assert.equal(sourceWords({ ...r, utm_source: 'newsletter', utm_medium: 'email', utm_campaign: 'fall' }), 'newsletter / email, fall');
  assert.equal(sourceWords({ ...r, from_ad: true }), 'google.com (ad)');
  assert.equal(topSourceWords('direct'), 'Direct');
});

test('place and shares', () => {
  assert.equal(place({ city: 'Ottawa', region: 'ON', country: 'CA' }), 'Ottawa, ON, CA');
  assert.equal(place({ city: null, region: null, country: null }), '');
  assert.equal(pct(1, 8), '12.5%');
  assert.equal(pct(1, 0), '');
});

test('chart: a bar per day scaled to the busiest, conversions inside, the visitors line, the peak', () => {
  const m = chartModel([{ day: '2026-10-01', visits: 10, visitors: 8, converted: 2, page_views: 30 }, { day: '2026-10-02', visits: 5, visitors: 5, converted: 0, page_views: 9 }], 200, 100);
  assert.equal(m.bars.length, 2);
  assert.equal(m.max, 10);
  assert.ok(Math.abs(m.bars[0]!.h - 96) < 0.01, 'the busiest day is full height (less the margin)');
  assert.ok(Math.abs(m.bars[1]!.h - 48) < 0.01, 'half the visits, half the height');
  assert.ok(m.bars[0]!.ch < m.bars[0]!.h && m.bars[1]!.ch === 0);
  assert.equal(m.line.split(' ').length, 2);
  assert.equal(m.peak?.day, '2026-10-01');
  assert.equal(chartModel([]).peak, null);
});
