// The renter portal's trip model (redesign of October 24, 2026): the clock, the short times, the map link and the money
// by part, all from what the loaders read.
//   node --test --experimental-strip-types src/features/portal/trip-model.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mapLink, moneyParts, shortWhen, tripClock, type MoneyInput } from './trip-model.ts';
import { span } from '../../components/portal-ui/time.ts';

const NOW = Date.parse('2026-10-24T16:00:00Z'); // Saturday, noon in Toronto

test('span: days and hours, hours and minutes, minutes', () => {
  assert.equal(span((2 * 24 + 4) * 3600e3), '2 days 4 h');
  assert.equal(span(26 * 3600e3), '1 day 2 h');
  assert.equal(span(5 * 3600e3 + 20 * 60e3), '5 h 20 min');
  assert.equal(span(12 * 60e3), '12 min');
  assert.equal(span(-90 * 60e3), '1 h 30 min');
});

test('shortWhen: the weekday and time in Toronto; the date when far or past', () => {
  assert.equal(shortWhen('2026-10-25T23:00:00Z', NOW), 'Sun 7 PM');
  assert.equal(shortWhen('2026-10-25T23:30:00Z', NOW), 'Sun 7:30 PM');
  assert.match(shortWhen('2026-11-20T15:00:00Z', NOW), /^Fri, Nov 20, 10 AM$/);
});

test('tripClock: pickup ahead, return on rent, late return', () => {
  const pick = tripClock({ status: 'confirmed', pickup_at: '2026-10-26T20:00:00Z', return_at: '2026-10-30T20:00:00Z' }, NOW);
  assert.equal(pick?.initial, 'Pickup in 2 days 4 h');
  const ret = tripClock({ status: 'on_rent', pickup_at: '2026-10-20T20:00:00Z', return_at: '2026-10-25T23:00:00Z', handed_over_at: '2026-10-20T20:00:00Z' }, NOW);
  assert.equal(ret?.label, 'Return by Sun 7 PM');
  assert.equal(ret?.initial, 'Return in 1 day 7 h');
  const late = tripClock({ status: 'on_rent', pickup_at: '2026-10-20T20:00:00Z', return_at: '2026-10-24T14:00:00Z' }, NOW);
  assert.equal(late?.late, true);
  assert.equal(late?.initial, 'Return was due 2 h ago');
  assert.equal(tripClock({ status: 'closed', pickup_at: '2026-10-01T20:00:00Z', return_at: '2026-10-03T20:00:00Z' }, NOW), null);
});

test('mapLink: a search link for a place in words, none for nothing', () => {
  assert.equal(mapLink('Pearson Airport, Terminal 1'), 'https://www.google.com/maps/search/?api=1&query=Pearson%20Airport%2C%20Terminal%201');
  assert.equal(mapLink(null), null);
  assert.equal(mapLink('  '), null);
});

const base: MoneyInput = { status: 'confirmed', renter_due_at_booking_cents: 79100, deposit_cents: 50000, signed: true, payments: [], refunds: [], extensions: [], addons: [], changes: [] };
const pay = (purpose: string, cents: number, status = 'succeeded', kind = 'charge') => ({ purpose, kind, status, amount_cents: cents, card_last4: '4242', processed_at: null, created_at: '2026-10-01T00:00:00Z' });

test('money: paid by part, the deposit held apart, refunds', () => {
  const m = moneyParts({ ...base, payments: [pay('booking_total', 79100), pay('addon', 565), pay('deposit', 50000, 'authorized', 'hold'), pay('extension', 1000, 'failed')],
    refunds: [{ id: 'r', amount_cents: 300, status: 'paid', created_at: '2026-10-02T00:00:00Z' }] });
  assert.equal(m.paidCents, 79665);
  assert.equal(m.owingCents, 0);
  assert.deepEqual(m.parts.map((p) => `${p.label}:${p.state}:${p.cents}`), ['Rental:paid:79100', 'Add-ons:paid:565', 'Deposit:held:50000', 'Refunded to you:refunded:300']);
});

test('money: what is open, each with where to pay it', () => {
  const m = moneyParts({ ...base, status: 'on_rent', link_due: true, signed: true,
    extensions: [{ id: 'e1', status: 'approved', total_cents: 12000, paid_at: null, new_return_at: '2026-10-30T20:00:00Z' }],
    addons: [{ after_booking: true, paid: false, status: 'confirmed', amount_cents: 500, hst_cents: 65 }, { after_booking: true, paid: false, status: 'pending', amount_cents: 9000, hst_cents: 0 }],
    changes: [{ status: 'approved', total_difference_cents: 4000 }] });
  assert.deepEqual(m.parts.filter((p) => p.state === 'owing').map((p) => `${p.label}:${p.cents}:${p.sub}`), ['Rental:79100:pay', 'Extension:12000:extend', 'Add-ons:565:addons/pay', 'Date change:4000:change']);
  assert.equal(m.owingCents, 79100 + 12000 + 565 + 4000);
  const unsigned = moneyParts({ ...base, status: 'pending_payment', signed: false });
  assert.equal(unsigned.parts[0]?.sub, 'sign');
  const offer = moneyParts({ ...base, status: 'offered' });
  assert.deepEqual(offer.parts.map((p) => p.state), ['info']);
  assert.equal(offer.owingCents, 0);
});
