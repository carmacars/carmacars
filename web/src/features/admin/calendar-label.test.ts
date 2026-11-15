import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { availability, barLabel, busyKind, holdEnds, holding, holdWords, takes, VIEWS, type LabelEntry, type Span } from './calendar-label.ts';

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

describe('fleet calendar availability (r48 follow-up)', () => {
  const T = Date.parse('2026-11-14T05:00:00Z'); // midnight in Toronto
  const D = 86_400_000;
  const days = Array.from({ length: 14 }, (_, i) => [T + (i - 2) * D, T + (i - 1) * D] as [number, number]);
  const now = T + 13 * 3_600_000;
  const iso = (d: number, h = 15) => new Date(T + d * D + h * 3_600_000).toISOString();
  const bk = (o: Partial<Span>): Span => ({ type: 'booking', status: 'confirmed', blocks: true, reason: null, starts_at: iso(3), ends_at: iso(5), renter: 'Sam Lee', booking_number: 'R-1', booking_type: 'standard', ...o });

  it('no taking entry: available now, free every day from today on', () => {
    const a = availability({ status: 'available', entries: [bk({ status: 'requested' }), bk({ placeholder: true }), bk({ blocks: false })] }, now, days, T);
    assert.deepEqual([a.kind, a.now, a.window, a.freeToday, a.freeAll, a.days], ['free', 'Available now', 'Free every day shown', true, true, 12]);
  });
  it('on rent now: red, the renter and the return date; days taken are counted', () => {
    const a = availability({ status: 'available', entries: [bk({ status: 'on_rent', starts_at: iso(-3), ends_at: iso(2) })] }, now, days, T);
    assert.equal(a.kind, 'out');
    assert.equal(a.now, 'Out now: Sam Lee until Nov 16');
    assert.equal(a.window, 'Free 9 of 12 days');
    assert.equal(a.freeToday, false);
  });
  it('a service block now: in shop until its end; open-ended: until further notice', () => {
    assert.equal(availability({ status: 'available', entries: [bk({ type: 'block', reason: 'repair', starts_at: iso(-1), ends_at: iso(1) })] }, now, days, T).now, 'In shop until Nov 15');
    const a = availability({ status: 'available', entries: [bk({ type: 'block', reason: 'owner_unavailable', starts_at: iso(-1), ends_at: null })] }, now, days, T);
    assert.deepEqual([a.kind, a.now, a.window], ['busy', 'Owner unavailable until further notice', 'No free day shown']);
  });
  it('a car that cannot be booked: greyed out, never free', () => {
    assert.deepEqual(['onboarding', 'out_of_service'].map((s) => { const a = availability({ status: s, entries: [] }, now, days, T); return [a.kind, a.now, a.freeToday]; }),
      [['off', 'Not bookable', false], ['off', 'In shop', false]]);
  });
  it('what takes the car and its tint', () => {
    assert.equal(takes(bk({})), true);
    assert.equal(takes(bk({ status: 'offered' })), false);
    assert.equal(takes(bk({ type: 'turo_trip', status: null })), true);
    assert.deepEqual([bk({ status: 'on_rent' }), bk({}), bk({ type: 'block', reason: 'cleaning' }), bk({ type: 'block', reason: 'admin' }), bk({ type: 'turo_trip' })].map(busyKind), ['out', 'booked', 'maint', 'block', 'turo']);
  });
  it('the badges, the legend and the filter are on the calendar', () => {
    const tsx = read('./MasterCalendar.tsx');
    for (const t of ['white: free', 'Only cars free for these dates', 'free today', 'mcal__busy', "a.kind === 'off' ? ' is-off'"]) assert.ok(tsx.includes(t), t);
    assert.match(read('./master-calendar.css'), /\.mcal \.mcal__row\.is-off \.mcal__lane \{/);
  });
});

describe('fleet calendar soft holds (r48, 2961)', () => {
  const T = Date.parse('2026-11-14T05:00:00Z'); // midnight in Toronto
  const D = 86_400_000;
  const H = 3_600_000;
  const days = Array.from({ length: 14 }, (_, i) => [T + (i - 2) * D, T + (i - 1) * D] as [number, number]);
  const now = T + 13 * H;
  const iso = (ms: number) => new Date(ms).toISOString();
  const bk = (o: Partial<Span>): Span => ({ type: 'booking', status: 'pending_payment', blocks: true, reason: null, starts_at: iso(T - 2 * H), ends_at: iso(T + 2 * D), renter: 'Sam Lee', booking_number: 'R-1', booking_type: 'standard', ...o });

  it('an open offer and an accepted unpaid booking hold softly until their time; after it nothing', () => {
    assert.equal(holding(bk({ hold_until: iso(now + H) }), now), true);
    assert.equal(holding(bk({ status: 'offered', hold_until: iso(now + H) }), now), true);
    assert.equal(holding(bk({ hold_until: iso(now - 1) }), now), false);
    assert.equal(holdEnds(bk({ status: 'confirmed', hold_until: iso(now + H) })), null);
    assert.equal(holdEnds(bk({ placeholder: true, hold_until: iso(now + H) })), null);
    assert.equal(holdEnds(bk({})), null);
  });
  it('the words: until when, then ended', () => {
    assert.equal(holdWords(bk({ hold_until: '2026-11-14T20:40:00Z' }), now), 'Held until Nov 14, 3:40 pm');
    assert.equal(holdWords(bk({ status: 'offered', hold_until: '2026-11-14T20:40:00Z' }), now), 'Offer open until Nov 14, 3:40 pm');
    assert.equal(holdWords(bk({ hold_until: iso(now - 1) }), now), 'Hold ended, not paid');
    assert.equal(holdWords(bk({ status: 'offered', hold_until: iso(now - 1) }), now), 'Offer expired');
  });
  it('an accepted unpaid booking takes the car while its hold runs, not after; an offer never does', () => {
    const held = availability({ status: 'available', entries: [bk({ hold_until: iso(now + H) })] }, now, days, T);
    assert.equal(held.kind, 'busy');
    assert.match(held.now, /^Held until .*: Sam Lee, not paid yet$/);
    assert.equal(held.freeToday, false);
    assert.equal(availability({ status: 'available', entries: [bk({ hold_until: iso(now - 1) })] }, now, days, T).kind, 'free');
    assert.equal(availability({ status: 'available', entries: [bk({ status: 'offered', hold_until: iso(now + H) })] }, now, days, T).kind, 'free');
  });
  it('the calendar draws the hold hatched, says so in the legend and fades a lapsed one', () => {
    const tsx = read('./MasterCalendar.tsx');
    for (const t of ['mcal__busy is-hold', 'hatched: held until the offer or payment time ends', "c.push('is-lapsed')"]) assert.ok(tsx.includes(t), t);
    assert.match(read('./master-calendar.css'), /\.mcal \.mcal__busy\.is-hold \{ background: repeating-linear-gradient/);
  });
});
