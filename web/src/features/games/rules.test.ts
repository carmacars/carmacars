import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { addPage, carSlug, claimProblems, cupSwaps, deck, excludedPath, handValue, ineligible, isSearchReferrer, plinkoPath, plinkoSlots, settle, trigger, wheelSlices, wheelStop,
  type GameCfg, type PrizeWord, type Visit } from './rules.ts';

// Discount games (migration 0069): when a game may show, and that every game lands on the prize the database drew.
const CFG: GameCfg = { on: true, car_pages: 2, seconds: 60, exit: true, dismiss_days: 14 };
const NOW = Date.parse('2026-10-19T15:00:00Z');
const PRIZES: PrizeWord[] = [{ key: 'pct5', short: '5%', label: '5% off' }, { key: 'pct10', short: '10%', label: '10% off' }, { key: 'pct15', short: '15%', label: '15% off' }, { key: 'amt50', short: '$50', label: '$50 off' }];
let seed = 7;
const rand = () => { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; };
const visit = (o: Partial<Visit> = {}): Visit => ({ start: NOW - 5000, pages: 1, cars: [], fromSearch: false, ...o });

describe('who may see a game', () => {
  const base = { cfg: CFG, mem: {}, signedIn: false, path: '/cars/tesla-model-3', now: NOW };
  it('a new visitor on a car page may', () => assert.equal(ineligible(base), null));
  it('never a signed-in visitor', () => assert.equal(ineligible({ ...base, signedIn: true }), 'signed_in'));
  it('never again after a claim', () => assert.equal(ineligible({ ...base, mem: { claimed: true } }), 'claimed'));
  it('never a visitor the database knows (by email) or refused', () => assert.equal(ineligible({ ...base, mem: { never: 'known' } }), 'known'));
  it('not when the games are off', () => assert.equal(ineligible({ ...base, cfg: { ...CFG, on: false } }), 'off'));
  it('not for 14 days after closing, then again', () => {
    assert.equal(ineligible({ ...base, mem: { dismissedAt: NOW - 13 * 86_400_000 } }), 'dismissed');
    assert.equal(ineligible({ ...base, mem: { dismissedAt: NOW - 15 * 86_400_000 } }), null);
  });
  it('never on booking, pay, sign, sign-in or portal pages', () => {
    for (const p of ['/book/tesla-model-3', '/book/sent/CC-1', '/account', '/account/bookings/CC-1/pay', '/owner', '/sign-in', '/sign/driver/x', '/admin', '/va/live', '/field', '/investor', '/list-your-car/apply', '/sign-document/x', '/create-account', '/reset-password'])
      assert.equal(excludedPath(p), true, p);
    for (const p of ['/', '/cars', '/cars/tesla-model-3', '/car-rental/toronto', '/guides/x', '/faq', '/list-your-car']) assert.equal(excludedPath(p), false, p);
  });
});

describe('when it shows', () => {
  it('after 2 car pages', () => {
    let v = visit({ pages: 0 });
    for (const p of ['/', '/cars/a', '/cars/a', '/faq']) v = addPage(v, p);
    assert.equal(trigger({ cfg: CFG, visit: v, now: NOW, phone: false }), null);
    v = addPage(v, '/cars/b');
    assert.equal(trigger({ cfg: CFG, visit: v, now: NOW, phone: false }), 'pages');
  });
  it('or after 60 seconds on the site', () => {
    assert.equal(trigger({ cfg: CFG, visit: visit({ start: NOW - 59_000 }), now: NOW, phone: false }), null);
    assert.equal(trigger({ cfg: CFG, visit: visit({ start: NOW - 60_000 }), now: NOW, phone: false }), 'time');
  });
  it('or on exit intent, on a computer only', () => {
    assert.equal(trigger({ cfg: CFG, visit: visit(), now: NOW, exit: true, phone: false }), 'exit');
    assert.equal(trigger({ cfg: CFG, visit: visit(), now: NOW, exit: true, phone: true }), null);
    assert.equal(trigger({ cfg: { ...CFG, exit: false }, visit: visit(), now: NOW, exit: true, phone: false }), null);
  });
  it('never on the first page of a search visit on a phone (no interstitial on a search landing)', () => {
    const v = visit({ start: NOW - 120_000, fromSearch: true, pages: 1, cars: ['a', 'b'] });
    assert.equal(trigger({ cfg: CFG, visit: v, now: NOW, phone: true }), null);
    assert.equal(trigger({ cfg: CFG, visit: { ...v, pages: 2 }, now: NOW, phone: true }), 'pages');
    assert.equal(trigger({ cfg: CFG, visit: v, now: NOW, phone: false }), 'pages');
  });
  it('a setting at 0 turns its rule off', () => assert.equal(trigger({ cfg: { ...CFG, car_pages: 0, seconds: 0 }, visit: visit({ start: 0, cars: ['a', 'b', 'c'] }), now: NOW, phone: false }), null));
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
