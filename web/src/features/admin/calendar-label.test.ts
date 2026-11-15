import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { barLabel, VIEWS, type LabelEntry } from './calendar-label.ts';

// r48: the fleet calendar's redesign (docs/changes/2026-11-14-r48-fleet-calendar.md).
const e = (o: Partial<LabelEntry>): LabelEntry => ({ type: 'booking', booking_type: 'standard', booking_number: 'R-100001', renter: 'Sam Lee', status: 'confirmed', reason: null, note: null, blocks: true, insurer: null, ...o });
const read = (p: string) => readFileSync(new URL(p, import.meta.url), 'utf8');

describe('fleet calendar bar words', () => {
  it('a booking: the renter first, then the booking number', () => {
    assert.deepEqual(barLabel(e({})), { main: 'Sam Lee', sub: 'R-100001' });
  });
  it('requests, offers and payment due say so after the number; flags follow', () => {
    assert.deepEqual(barLabel(e({ status: 'requested' })), { main: 'Sam Lee', sub: 'R-100001 · Request' });
    assert.deepEqual(barLabel(e({ status: 'offered' })), { main: 'Sam Lee', sub: 'R-100001 · Offer' });
    assert.deepEqual(barLabel(e({ status: 'pending_payment', insurer: 'X' })), { main: 'Sam Lee', sub: 'R-100001 · Payment due, insurer' });
    assert.deepEqual(barLabel(e({ placeholder: true })), { main: 'Sam Lee', sub: 'R-100001 · placeholder' });
    assert.deepEqual(barLabel(e({ blocks: false })), { main: 'Sam Lee', sub: 'R-100001 · not blocking' });
  });
  it('no renter name (a hold, or a role that sees none): the booking number leads', () => {
    assert.deepEqual(barLabel(e({ renter: null })), { main: 'R-100001', sub: '' });
    assert.deepEqual(barLabel(e({ renter: ' ', status: 'requested' })), { main: 'R-100001', sub: 'Request' });
  });
  it("an owner's own trip and a block", () => {
    assert.equal(barLabel(e({ booking_type: 'owner' })).main, "Owner's own trip ($0)");
    assert.deepEqual(barLabel(e({ type: 'block', reason: 'owner_unavailable', note: 'Away' })), { main: 'Owner unavailable', sub: 'Away' });
    assert.deepEqual(barLabel(e({ type: 'turo_trip' })), { main: '', sub: '' });
  });
  it('no long dash in any bar', () => {
    for (const x of [e({}), e({ status: 'requested', insurer: 'X' }), e({ type: 'block', reason: 'service' })]) assert.doesNotMatch(Object.values(barLabel(x)).join(' '), /[–—]/);
  });
});

describe('fleet calendar layout', () => {
  it('day widths leave room for words: a two-day bar fits a name and a number, a month day its weekday and date', () => {
    assert.ok(VIEWS.two!.dw * 2 >= 150);
    assert.ok(VIEWS.month!.dw >= 44);
    assert.ok(VIEWS.week!.dw >= 120);
  });
  it('one stylesheet for the calendar, imported by the shared component (every portal gets it)', () => {
    const tsx = read('./MasterCalendar.tsx');
    assert.match(tsx, /import '\.\/master-calendar\.css';/);
    assert.doesNotMatch(read('../../styles/admin.css'), /\.mcal/);
    assert.doesNotMatch(read('../bookings-now/bookings-now.css'), /\.mcal/);
    // the car column's width is one variable used by the head, the rows and the bars' sticky words
    assert.doesNotMatch(tsx, /14rem/);
    assert.match(tsx, /var\(--namew\)/);
  });
  it('sticky car column and date header; only the calendar scrolls sideways; a narrower car column on a phone', () => {
    const css = read('./master-calendar.css');
    assert.match(css, /\.mcal \.mcal__grid \{[^}]*overflow: auto;/);
    assert.match(css, /\.mcal \.mcal__head \{[^}]*position: sticky; top: 0;/);
    assert.match(css, /\.mcal \.mcal__corner, \.mcal \.mcal__name \{ position: sticky; left: 0;/);
    assert.match(css, /@media \(max-width: 40rem\) \{ \.mcal \{ --namew: [\d.]+rem; \} \}/);
    assert.match(css, /\.mcal \.mcal__lbl \{ position: sticky; left: calc\(var\(--namew\)/);
    // the now line under the bars, never over their words
    const z = (sel: string) => Number(new RegExp(`${sel.replace(/\./g, '\\.')} \\{[^}]*z-index: (\\d+)`).exec(css)?.[1]);
    assert.ok(z('.mcal .mcal__now') < z('.mcal .mcal__item'));
  });
});
