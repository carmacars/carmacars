import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { addPage, addSeen, bookingIneligible, bookingPath, carSlug, claimProblems, closed, cupSwaps, deck, excludedPath, GAMES, handValue, ineligible, isSearchReferrer, nextCheck, plinkoPath, plinkoSlots,
  SEARCH_LANDING_DELAY, settle, shown, trigger, unseen, wheelSlices, wheelStop, type GameCfg, type GameKind, type PrizeWord, type Visit } from './rules.ts';

// Discount games (migrations 0069 and 0076): when a game may show (first, again after a close, in the request-to-book
// form), the round of five games, and that every game lands on the prize the database drew.
const CFG: GameCfg = { on: true, car_pages: 1, seconds: 15, exit: true, reshow_pages: 2, reshow_seconds: 180, per_visit: 3, booking: true };
const NOW = Date.parse('2026-10-21T15:00:00Z');
const PRIZES: PrizeWord[] = [{ key: 'pct5', short: '5%', label: '5% off' }, { key: 'pct10', short: '10%', label: '10% off' }, { key: 'pct15', short: '15%', label: '15% off' }, { key: 'amt50', short: '$50', label: '$50 off' }];
let seed = 7;
const rand = () => { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; };
const visit = (o: Partial<Visit> = {}): Visit => ({ start: NOW - 5000, pages: 1, cars: [], fromSearch: false, shows: 0, ...o });
const t = (v: Visit, o: { now?: number; exit?: boolean; phone?: boolean; cfg?: GameCfg } = {}) => trigger({ cfg: o.cfg ?? CFG, visit: v, now: o.now ?? NOW, exit: o.exit, phone: o.phone ?? false });

describe('who may see a game on the site', () => {
  const base = { cfg: CFG, mem: {}, signedIn: false, path: '/cars/tesla-model-3' };
  it('a new visitor on a car page may', () => assert.equal(ineligible(base), null));
  it('never a signed-in visitor on the site', () => assert.equal(ineligible({ ...base, signedIn: true }), 'signed_in'));
  it('never again after a claim', () => assert.equal(ineligible({ ...base, mem: { claimed: true } }), 'claimed'));
  it('never a visitor the database knows (by email) or refused', () => assert.equal(ineligible({ ...base, mem: { never: 'known' } }), 'known'));
  it('not when the games are off', () => assert.equal(ineligible({ ...base, cfg: { ...CFG, on: false } }), 'off'));
  it('no more 14-day wait after closing (0076): a close long ago or just now does not stop it', () => {
    assert.equal(ineligible({ ...base, mem: { dismissedAt: NOW - 1000 } }), null);
  });
  it('at most 3 shows a visit', () => {
    assert.equal(ineligible({ ...base, visit: visit({ shows: 2 }) }), null);
    assert.equal(ineligible({ ...base, visit: visit({ shows: 3 }) }), 'visit_cap');
    assert.equal(ineligible({ ...base, cfg: { ...CFG, per_visit: 5 }, visit: visit({ shows: 3 }) }), null);
  });
  it('never on booking, pay, sign, sign-in or portal pages', () => {
    for (const p of ['/book/tesla-model-3', '/book/sent/CC-1', '/account', '/account/bookings/CC-1/pay', '/owner', '/sign-in', '/sign/driver/x', '/admin', '/va/live', '/field', '/investor', '/list-your-car/apply', '/sign-document/x', '/create-account', '/reset-password'])
      assert.equal(excludedPath(p), true, p);
    for (const p of ['/', '/cars', '/cars/tesla-model-3', '/car-rental/toronto', '/guides/x', '/faq', '/list-your-car']) assert.equal(excludedPath(p), false, p);
  });
});

describe('the first game of a visit', () => {
  it('after 1 car page', () => {
    let v = visit({ pages: 0 });
    v = addPage(v, '/');
    assert.equal(t(v), null);
    v = addPage(v, '/cars/a');
    assert.deepEqual(t(v), { why: 'pages', slim: false });
  });
  it('or after 15 seconds on the site, whichever first', () => {
    assert.equal(t(visit({ start: NOW - 14_999 })), null);
    assert.deepEqual(t(visit({ start: NOW - 15_000 })), { why: 'time', slim: false });
  });
  it('or on exit intent, on a computer only', () => {
    assert.deepEqual(t(visit(), { exit: true }), { why: 'exit', slim: false });
    assert.equal(t(visit(), { exit: true, phone: true }), null);
    assert.equal(t(visit(), { exit: true, cfg: { ...CFG, exit: false } }), null);
  });
  it('a setting at 0 turns its rule off', () => assert.equal(t(visit({ start: 0, cars: ['a', 'b', 'c'] }), { cfg: { ...CFG, car_pages: 0, seconds: 0 } }), null));
  it('the timer looks again when the 15 seconds are up', () => {
    assert.equal(nextCheck({ cfg: CFG, visit: visit({ start: NOW - 5000 }), now: NOW, phone: false }), 10_000);
    assert.equal(nextCheck({ cfg: { ...CFG, seconds: 0 }, visit: visit(), now: NOW, phone: false }), null);
  });
});

describe('a phone visit from a search engine (no interstitial on the landing page)', () => {
  const land = (o: Partial<Visit> = {}) => visit({ fromSearch: true, pages: 1, ...o });
  it('not at once on the first page, even a car page', () => {
    assert.equal(t(land({ start: NOW, cars: ['a'] }), { phone: true }), null);
    assert.equal(t(land({ start: NOW - 20_000 }), { phone: true }), null);
  });
  it('15 seconds after its rule, as the small slide-in', () => {
    assert.equal(t(land({ start: NOW - SEARCH_LANDING_DELAY + 1, cars: ['a'] }), { phone: true }), null);
    assert.deepEqual(t(land({ start: NOW - SEARCH_LANDING_DELAY, cars: ['a'] }), { phone: true }), { why: 'pages', slim: true });
    assert.deepEqual(t(land({ start: NOW - 15_000 - SEARCH_LANDING_DELAY }), { phone: true }), { why: 'time', slim: true });
    assert.equal(nextCheck({ cfg: CFG, visit: land({ start: NOW }), now: NOW, phone: true }), 15_000 + SEARCH_LANDING_DELAY);
  });
  it('or on the second page, as the usual card', () => assert.deepEqual(t(land({ pages: 2, cars: ['a'] }), { phone: true }), { why: 'pages', slim: false }));
  it('a computer from a search engine is not held back', () => assert.deepEqual(t(land({ cars: ['a'] })), { why: 'pages', slim: false }));
});

describe('again after a close', () => {
  const after = (o: Partial<Visit> = {}) => closed(shown(visit({ cars: ['a'], ...o })), NOW);
  it('not while one is open', () => assert.equal(t(shown(visit({ cars: ['a', 'b', 'c'], start: 0 }))), null));
  it('after 2 more car pages', () => {
    let v = after();
    assert.equal(t(v), null);
    v = addPage(v, '/cars/a'); // the same car again does not count
    v = addPage(v, '/cars/b');
    assert.equal(t(v), null);
    v = addPage(v, '/cars/c');
    assert.deepEqual(t(v), { why: 'pages', slim: false });
  });
  it('or 3 minutes after the close, whichever first', () => {
    const v = after();
    assert.equal(t(v, { now: NOW + 179_999 }), null);
    assert.deepEqual(t(v, { now: NOW + 180_000 }), { why: 'time', slim: false });
    assert.equal(nextCheck({ cfg: CFG, visit: v, now: NOW + 60_000, phone: false }), 120_000);
  });
  it('exit intent is for the first game only', () => assert.equal(t(after(), { exit: true }), null));
  it('at most 3 a visit, then not even by time', () => {
    let v = visit({ cars: ['a'] });
    for (let i = 0; i < 3; i++) v = closed(shown(v), NOW);
    assert.equal(v.shows, 3);
    assert.equal(t(v, { now: NOW + 3_600_000 }), null);
    assert.equal(nextCheck({ cfg: CFG, visit: v, now: NOW, phone: false }), null);
  });
  it('a later visit starts again (a new visit has no shows)', () => assert.deepEqual(t(visit({ cars: ['a'] })), { why: 'pages', slim: false }));
});

describe('the round of five games', () => {
  it('each game once before one repeats, and never the same twice in a row', () => {
    let seen: GameKind[] = [];
    const order: GameKind[] = [];
    for (let i = 0; i < 12; i++) {
      const left = unseen(seen, GAMES, order[order.length - 1]);
      const g = left[Math.floor(rand() * left.length)]!;
      if (order.length) assert.notEqual(g, order[order.length - 1]);
      order.push(g);
      seen = addSeen(seen, g);
    }
    assert.equal(new Set(order.slice(0, 5)).size, 5);
  });
  it('a full round starts again with the last one shown', () => {
    assert.deepEqual(addSeen(['wheel', 'scratch', 'blackjack', 'cups'], 'plinko'), ['plinko']);
    assert.deepEqual(unseen(['plinko'], GAMES), ['wheel', 'scratch', 'blackjack', 'cups']);
  });
  it('games turned off are not waited for', () => {
    const on: GameKind[] = ['wheel', 'cups'];
    assert.deepEqual(addSeen(['wheel'], 'cups', on), ['cups']);
    assert.deepEqual(unseen(['wheel', 'cups'], on, 'cups'), ['wheel']);
    assert.deepEqual(unseen(['scratch'], on), ['wheel', 'cups']);
  });
});

describe('the request-to-book form', () => {
  const base = { cfg: CFG, mem: {}, path: '/book/tesla-model-3' };
  it('offered to anyone who has not claimed', () => assert.equal(bookingIneligible(base), null));
  it('the one place a signed-in renter or a known visitor sees it', () => {
    assert.equal(bookingIneligible({ ...base, mem: { never: 'signed_in' } }), null);
    assert.equal(bookingIneligible({ ...base, mem: { never: 'known' } }), null);
  });
  it('never after a claim', () => {
    assert.equal(bookingIneligible({ ...base, mem: { claimed: true } }), 'claimed');
    assert.equal(bookingIneligible({ ...base, mem: { never: 'claimed' } }), 'claimed');
  });
  it('never for staff', () => assert.equal(bookingIneligible({ ...base, staff: true }), 'staff'));
  it('not when the offer is off, or a code is already on the booking', () => {
    assert.equal(bookingIneligible({ ...base, cfg: { ...CFG, booking: false } }), 'off');
    assert.equal(bookingIneligible({ ...base, promoApplied: true }), 'has_code');
  });
  it('only in the form: never on the sent page, pay or sign pages', () => {
    for (const p of ['/book', '/book/tesla-model-3']) assert.equal(bookingPath(p), true, p);
    for (const p of ['/book/sent/CC-1', '/account/bookings/CC-1/pay', '/account/bookings/CC-1/sign', '/book/x/pay', '/cars/x', '/admin/bookings/new', '/va/bookings/new']) assert.equal(bookingPath(p), false, p);
  });
});

describe('search engines and car pages', () => {
  it('search engines are told apart', () => {
    assert.equal(isSearchReferrer('https://www.google.com/'), true);
    assert.equal(isSearchReferrer('https://www.google.ca/search?q=x'), true);
    assert.equal(isSearchReferrer('https://duckduckgo.com/'), true);
    assert.equal(isSearchReferrer('https://instagram.com/'), false);
    assert.equal(isSearchReferrer(''), false);
  });
  it('car pages are /cars/<slug>', () => { assert.equal(carSlug('/cars/tesla-model-3'), 'tesla-model-3'); assert.equal(carSlug('/cars'), null); });
});

describe('every game lands on the drawn prize', () => {
  it('the wheel: 12 slices, every prize on it, the common one on every other slice', () => {
    const s = wheelSlices(PRIZES);
    assert.equal(s.length, 12);
    for (const p of PRIZES) assert.ok(s.some((x) => x.key === p.key), p.key);
    assert.equal(s.filter((x) => x.key === 'pct5').length, 6);
    assert.ok(s.filter((x) => x.key === 'amt50').length <= s.filter((x) => x.key === 'pct10').length);
  });
  it('the wheel stops inside a slice of the prize, 1,000 times for each prize', () => {
    const s = wheelSlices(PRIZES);
    for (const p of PRIZES) for (let i = 0; i < 1000; i++) {
      const { degrees } = wheelStop(s, p.key, rand);
      const atTop = ((360 - (degrees % 360)) % 360);
      const slice = Math.floor(atTop / 30);
      assert.equal(s[slice]!.key, p.key);
      assert.ok(degrees >= 5 * 360);
    }
  });
  it('Plinko: 9 slots, the rarest in the middle, every path ends in a slot of the prize', () => {
    const slots = plinkoSlots(PRIZES);
    assert.equal(slots.length, 9);
    assert.equal(slots[4]!.key, 'amt50');
    for (const p of PRIZES) for (let i = 0; i < 1000; i++) {
      const { slot, moves } = plinkoPath(slots, p.key, rand);
      assert.equal(moves.length, 8);
      assert.equal(moves.filter(Boolean).length, slot);
      assert.equal(slots[slot]!.key, p.key);
    }
  });
  it('blackjack: hand values, the dealer to 17, every outcome named', () => {
    assert.equal(handValue([1, 13]), 21);
    assert.equal(handValue([1, 1, 9]), 21);
    assert.equal(handValue([10, 9, 5]), 24);
    assert.equal(settle([10, 9, 5], [10, 7], () => 2).result, 'bust');
    assert.equal(settle([1, 12], [10, 7], () => 2).result, 'blackjack');
    assert.equal(settle([10, 9], [10, 6], () => 10).result, 'win');
    assert.equal(settle([10, 8], [10, 8], () => 2).result, 'push');
    assert.equal(settle([10, 6], [10, 9], () => 2).result, 'lose');
    const d = deck(rand); assert.equal(d.length, 52); assert.equal(d.filter((c) => c === 1).length, 4);
  });
  it('the cups shuffle about seven times, never the same swap twice in a row', () => {
    const s = cupSwaps(rand);
    assert.equal(s.length, 7);
    for (let i = 1; i < s.length; i++) assert.notDeepEqual(s[i], s[i - 1]);
  });
});

describe('the claim form', () => {
  it('needs a first name and an email; the phone is optional but checked', () => {
    assert.deepEqual(claimProblems({ first: 'Maya', email: 'maya@example.com', phone: '' }), {});
    assert.deepEqual(Object.keys(claimProblems({ first: '', email: 'x', phone: '12' })).sort(), ['email', 'first', 'phone']);
    assert.deepEqual(claimProblems({ first: 'Maya', email: 'maya@example.com', phone: '(647) 555-0101' }), {});
    assert.deepEqual(claimProblems({ first: 'Maya', email: 'maya@example.com', phone: '+44 20 7946 0958' }), {});
  });
});
