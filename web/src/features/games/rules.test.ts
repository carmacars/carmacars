import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { coinFlip, dieFace, isReplay, nextGame, requestInProgress, reshowDue, savedPrize, savedWords, shortScale, slotStops, slotStrip, SAVED_DAYS, waitingWords, wonWords } from './rules.ts';
import { addPage, addSeen, countShown, gameDay, shownToday, expectedCost, packCards, prizeCost, tearProgress, TORN, type PrizeRow, bookingIneligible, bookingPath, carSlug, claimProblems, closed, cupSwaps, deck, excludedPath, GAMES, handValue, ineligible, isSearchReferrer, nextCheck, plinkoPath, plinkoSlots,
  SEARCH_LANDING_DELAY, settle, shown, trigger, unseen, wheelSlices, wheelStop, type GameCfg, type GameKind, type PrizeWord, type Visit } from './rules.ts';

// Discount games (migrations 0069, 0081, 0094 and 0100): when a game may show (first, again after a close, in the
// request-to-book form), the rotation, and that every game lands on the prize the database drew. CFG: the owner's
// defaults of 0100 (2nd page view or 30 seconds; after a close the 3rd page view or 2 minutes; 4 a visit; no daily cap).
const CFG: GameCfg = { on: true, car_pages: 2, seconds: 30, exit: false, reshow_pages: 3, reshow_seconds: 120, per_visit: 4, per_day: 0, booking: true };
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
  it('no more 14-day wait after closing (0081): a close long ago or just now does not stop it', () => {
    assert.equal(ineligible({ ...base, mem: { dismissedAt: NOW - 1000 } }), null);
  });
  it('at most 4 shows a visit (0100)', () => {
    assert.equal(ineligible({ ...base, visit: visit({ shows: 3 }) }), null);
    assert.equal(ineligible({ ...base, visit: visit({ shows: 4 }) }), 'visit_cap');
    assert.equal(ineligible({ ...base, cfg: { ...CFG, per_visit: 5 }, visit: visit({ shows: 4 }) }), null);
  });
  it('never on booking, pay, sign, sign-in or portal pages', () => {
    for (const p of ['/book/tesla-model-3', '/book/sent/CC-1', '/account', '/account/bookings/CC-1/pay', '/owner', '/sign-in', '/sign/driver/x', '/admin', '/va/live', '/field', '/investor', '/list-your-car/apply', '/sign-document/x', '/create-account', '/reset-password'])
      assert.equal(excludedPath(p), true, p);
    for (const p of ['/', '/cars', '/cars/tesla-model-3', '/car-rental/toronto', '/guides/x', '/faq', '/list-your-car']) assert.equal(excludedPath(p), false, p);
  });
});

describe('the first game of a visit (0100: the 2nd page view or 30 seconds, whichever first)', () => {
  it('on the 2nd page view, any page', () => {
    let v = visit({ pages: 0 });
    v = addPage(v, '/');
    assert.equal(t(v), null);
    v = addPage(v, '/faq');
    assert.deepEqual(t(v), { why: 'pages', slim: false });
  });
  it('car pages count as pages, no more', () => {
    let v = visit({ pages: 0 });
    v = addPage(v, '/cars/a');
    assert.equal(t(v), null);
  });
  it('or after 30 seconds on the site, whichever first', () => {
    assert.equal(t(visit({ start: NOW - 29_999 })), null);
    assert.deepEqual(t(visit({ start: NOW - 30_000 })), { why: 'time', slim: false });
  });
  it('exit intent is off by default; on, it is for computers only', () => {
    assert.equal(t(visit(), { exit: true }), null);
    const on = { ...CFG, exit: true };
    assert.deepEqual(t(visit(), { exit: true, cfg: on }), { why: 'exit', slim: false });
    assert.equal(t(visit(), { exit: true, phone: true, cfg: on }), null);
  });
  it('a setting at 0 turns its rule off', () => assert.equal(t(visit({ start: 0, pages: 9 }), { cfg: { ...CFG, car_pages: 0, seconds: 0 } }), null));
  it('the timer looks again when the 30 seconds are up', () => {
    assert.equal(nextCheck({ cfg: CFG, visit: visit({ start: NOW - 5000 }), now: NOW, phone: false }), 25_000);
    assert.equal(nextCheck({ cfg: { ...CFG, seconds: 0 }, visit: visit(), now: NOW, phone: false }), null);
  });
});

describe('a phone visit from a search engine (no interstitial on the landing page)', () => {
  const land = (o: Partial<Visit> = {}) => visit({ fromSearch: true, pages: 1, ...o });
  it('not at once on the first page', () => {
    assert.equal(t(land({ start: NOW }), { phone: true }), null);
    assert.equal(t(land({ start: NOW - 30_000 }), { phone: true }), null);
  });
  it('15 seconds after its rule, as the small slide-in', () => {
    assert.equal(t(land({ start: NOW - 30_000 - SEARCH_LANDING_DELAY + 1 }), { phone: true }), null);
    assert.deepEqual(t(land({ start: NOW - 30_000 - SEARCH_LANDING_DELAY }), { phone: true }), { why: 'time', slim: true });
    assert.equal(nextCheck({ cfg: CFG, visit: land({ start: NOW }), now: NOW, phone: true }), 30_000 + SEARCH_LANDING_DELAY);
  });
  it('or on the second page, as the usual card', () => assert.deepEqual(t(land({ pages: 2 }), { phone: true }), { why: 'pages', slim: false }));
});

describe('again after a close (0100: the 3rd page view after the close or 2 minutes, whichever first)', () => {
  const after = (o: Partial<Visit> = {}) => closed(shown(visit({ pages: 2, ...o })), NOW);
  it('not while one is open', () => assert.equal(t(shown(visit({ pages: 9, start: 0 }))), null));
  it('on the 3rd page view after the close, any page', () => {
    let v = after();
    assert.equal(t(v), null);
    v = addPage(v, '/how-it-works');
    v = addPage(v, '/faq');
    assert.equal(t(v), null);
    v = addPage(v, '/cars');
    assert.deepEqual(t(v), { why: 'pages', slim: false });
    assert.equal(reshowDue(CFG, v, NOW), 'pages');
  });
  it('or 2 minutes after the close, whichever first', () => {
    const v = after();
    assert.equal(t(v, { now: NOW + 119_999 }), null);
    assert.deepEqual(t(v, { now: NOW + 120_000 }), { why: 'time', slim: false });
    assert.equal(nextCheck({ cfg: CFG, visit: v, now: NOW + 20_000, phone: false }), 100_000);
  });
  it('both rules at 0: no game again in this visit', () => {
    const off = { ...CFG, reshow_pages: 0, reshow_seconds: 0 };
    let v = after();
    for (let i = 0; i < 9; i++) v = addPage(v, '/faq');
    assert.equal(t(v, { now: NOW + 3_600_000, cfg: off }), null);
    assert.equal(nextCheck({ cfg: off, visit: v, now: NOW, phone: false }), null);
  });
  it('no daily cap by default (0 or empty); a cap when set, the first game too', () => {
    assert.deepEqual(trigger({ cfg: CFG, visit: visit({ pages: 2 }), now: NOW, phone: false, today: 40 }), { why: 'pages', slim: false });
    assert.deepEqual(trigger({ cfg: { ...CFG, per_day: null }, visit: visit({ pages: 2 }), now: NOW, phone: false, today: 40 }), { why: 'pages', slim: false });
    const capped = { ...CFG, per_day: 6 };
    assert.equal(trigger({ cfg: capped, visit: visit({ pages: 2 }), now: NOW, phone: false, today: 6 }), null);
    assert.deepEqual(trigger({ cfg: capped, visit: visit({ pages: 2 }), now: NOW, phone: false, today: 5 }), { why: 'pages', slim: false });
    assert.equal(nextCheck({ cfg: capped, visit: after(), now: NOW, phone: false, today: 6 }), null);
    const m = { day: gameDay(NOW), dayShows: 5 };
    assert.equal(shownToday(m, NOW), 5);
    assert.equal(shownToday(m, NOW + 2 * 86_400_000), 0);
    assert.deepEqual(countShown(m, NOW), { day: gameDay(NOW), dayShows: 6 });
  });
  it('exit intent is for the first game only', () => assert.equal(t(after(), { exit: true, cfg: { ...CFG, exit: true } }), null));
  it('at most 4 a visit, then not even by time or pages', () => {
    let v = visit({ pages: 2 });
    for (let i = 0; i < 4; i++) v = closed(shown(v), NOW);
    assert.equal(v.shows, 4);
    for (let i = 0; i < 5; i++) v = addPage(v, '/faq');
    assert.equal(t(v, { now: NOW + 3_600_000 }), null);
    assert.equal(nextCheck({ cfg: CFG, visit: v, now: NOW, phone: false }), null);
    assert.equal(ineligible({ cfg: CFG, mem: {}, signedIn: false, path: '/', visit: v }), 'visit_cap');
  });
  it('a later visit starts again (a new visit has no shows)', () => assert.deepEqual(t(visit({ pages: 2 })), { why: 'pages', slim: false }));
});

describe('a booking request in progress, and a prize already won (0100)', () => {
  const base = { cfg: CFG, mem: {}, signedIn: false, path: '/cars' };
  it('no game while a booking request is in progress in this browser', () => {
    assert.equal(ineligible({ ...base, busy: true }), 'in_progress');
    assert.equal(requestInProgress({ mem: {}, draft: null, now: NOW }), false);
    // the form only opened (step 1, nothing saved): not yet
    assert.equal(requestInProgress({ mem: {}, draft: { step: 1, token: null, draftId: null, at: NOW }, now: NOW }), false);
    assert.equal(requestInProgress({ mem: {}, draft: { step: 2, at: NOW - 1000 }, now: NOW }), true);
    assert.equal(requestInProgress({ mem: {}, draft: { step: 1, draftId: 'd1', at: NOW }, now: NOW }), true);
    assert.equal(requestInProgress({ mem: { requested: NOW - 86_400_000 }, draft: null, now: NOW }), true);
    // an old draft no longer counts
    assert.equal(requestInProgress({ mem: {}, draft: { step: 3, at: NOW - 31 * 86_400_000 }, now: NOW }), false);
  });
  it('never on checkout or payment pages; the request-to-book form keeps its own game', () => {
    for (const p of ['/checkout', '/checkout/x', '/pay/abc', '/payment', '/account/bookings/CC-1/pay', '/my-request/x', '/continue/x', '/book/sent/CC-1']) assert.equal(excludedPath(p), true, p);
    assert.equal(bookingPath('/book/tesla-model-3'), true);
    assert.equal(bookingPath('/book/tesla-model-3/pay'), false);
  });
  it('a prize won here is saved, never a new win; 0171: it pops up again on the usual rules', () => {
    const won = { label: '5% off', short: '5%', at: NOW - 1000 };
    // 0171: the saved prize no longer keeps the card away (the server returns the saved play, the card says "still waiting")
    assert.equal(ineligible({ ...base, mem: { won } }), null);
    assert.equal(ineligible({ ...base, mem: { won }, busy: true }), 'in_progress');
    assert.equal(ineligible({ ...base, mem: { won, claimed: true } }), 'claimed');
    assert.equal(ineligible({ ...base, mem: { won }, signedIn: true }), 'signed_in');
    assert.equal(ineligible({ ...base, mem: { won }, path: '/checkout' }), 'page');
    assert.deepEqual(savedPrize({ won }, NOW), won);
    assert.equal(savedWords(won), 'Your 5% off is saved');
    // claimed, or older than the days a prize is kept: no badge
    assert.equal(savedPrize({ won, claimed: true }, NOW), null);
    assert.equal(savedPrize({ won }, NOW + SAVED_DAYS * 86_400_000), null);
    assert.equal(ineligible({ ...base, mem: { won: { ...won, at: NOW - SAVED_DAYS * 86_400_000 - 1 } }, now: NOW }), null);
  });
});

describe('0171: the card comes back, and the replay prize', () => {
  const won = { label: '5% off', short: '5%', at: NOW - 1000 };
  it('a won prize pops up again after a close on the re-show rules, and on a later visit on the first-show rules', () => {
    const v = closed(shown(visit({ pages: 2 })), NOW);
    assert.equal(ineligible({ cfg: CFG, mem: { won }, signedIn: false, path: '/faq', visit: v, now: NOW }), null);
    assert.equal(t(v), null);
    assert.deepEqual(t({ ...v, pages: v.pages + 3 }), { why: 'pages', slim: false });
    assert.deepEqual(t(v, { now: NOW + 120_000 }), { why: 'time', slim: false });
    // at most per_visit cards a visit, the saved prize's included
    assert.equal(ineligible({ cfg: CFG, mem: { won }, signedIn: false, path: '/faq', visit: visit({ shows: 4 }), now: NOW }), 'visit_cap');
    // a later visit (a new session): the first-show rules
    assert.deepEqual(t(visit({ pages: 2 })), { why: 'pages', slim: false });
  });
  it('a game closed before its prize: the next visit may show one again (no wait of days)', () => {
    assert.equal(ineligible({ cfg: CFG, mem: { seen: ['wheel'], last: 'wheel', dismissedAt: NOW - 60_000 }, signedIn: false, path: '/faq', visit: visit(), now: NOW }), null);
  });
  it('the words: never "You won" twice for one prize', () => {
    assert.equal(waitingWords(won), 'Your 5% off is still waiting');
    assert.equal(wonWords({ label: '5% off' }, 'new'), 'You won 5% off');
    assert.equal(wonWords({ label: '5% off' }, 'saved'), 'Your 5% off is saved');
    assert.equal(wonWords({ label: '5% off' }, 'waiting'), 'Your 5% off is still waiting');
    assert.equal(wonWords({ label: 'another go', replay: true }, 'new'), 'You won another go!');
    assert.equal(wonWords({ label: 'another go', replay: true }, 'waiting'), 'You still have another go');
    assert.equal(wonWords({ label: 'another go', replay: true }, 'saved'), 'You still have another go');
    assert.equal(isReplay({ replay: true }), true);
    assert.equal(isReplay({}), false);
    assert.equal(isReplay(null), false);
  });
  it('the replay prize costs nothing and a claimed code is drawn from the other prizes', () => {
    const basis = { charge_cents: 40000, days: 4 };
    const replay: PrizeRow = { key: 'replay', replay: true, weight: 15 };
    assert.equal(prizeCost(replay, basis, 7500), 0);
    const real: PrizeRow[] = [{ key: 'pct5', percent_bps: 500, weight: 54 }, { key: 'pct10', percent_bps: 1000, weight: 25 }];
    assert.ok(Math.abs(expectedCost([real[0]!, replay, real[1]!], basis, 7500) - expectedCost(real, basis, 7500)) < 0.001);
    assert.equal(expectedCost([replay], basis, 7500), 0);
  });
  it('every game can show the replay prize: on the wheel, the reels and the Plinko board, a smaller word', () => {
    const withReplay: PrizeWord[] = [PRIZES[0]!, PRIZES[1]!, { key: 'replay', short: 'REPLAY', label: 'another go', replay: true }, PRIZES[2]!, PRIZES[3]!];
    const slices = wheelSlices(withReplay);
    assert.ok(slices.some((s) => s.key === 'replay'));
    assert.equal(slices[wheelStop(slices, 'replay', rand).index]!.key, 'replay');
    const slots = plinkoSlots(withReplay);
    assert.equal(slots[plinkoPath(slots, 'replay', rand).slot]!.key, 'replay');
    const strip = slotStrip(withReplay);
    assert.ok(slotStops(strip, 'replay', rand).every((i) => strip[i]!.key === 'replay'));
    assert.equal(shortScale('$100'), 1);
    assert.ok(shortScale('REPLAY') < 0.7);
  });
});

describe('the rotation (0100: eleven games, never the same twice in a row)', () => {
  it('every game once before one repeats, and never the same twice in a row', () => {
    let seen: GameKind[] = [];
    const order: GameKind[] = [];
    for (let i = 0; i < 40; i++) {
      const g = nextGame({ seen, last: order[order.length - 1], r: rand })!;
      if (order.length) assert.notEqual(g, order[order.length - 1]);
      order.push(g);
      seen = addSeen(seen, g);
    }
    assert.equal(new Set(order.slice(0, GAMES.length)).size, GAMES.length);
  });
  it('a full round starts again, never with the last one shown', () => {
    const all = GAMES.slice(0, -1);
    assert.deepEqual(addSeen(all, 'mystery'), ['mystery']);
    assert.deepEqual(unseen(['mystery'], GAMES), GAMES.filter((g) => g !== 'mystery'));
    // the browser lost its round: still not the last game
    assert.ok(!unseen([], GAMES, 'coin').includes('coin'));
    assert.ok(!unseen(GAMES, GAMES, 'dice').includes('dice'));
  });
  it('games turned off are not waited for; one game on repeats (nothing else to show)', () => {
    const on: GameKind[] = ['wheel', 'cups'];
    assert.deepEqual(addSeen(['wheel'], 'cups', on), ['cups']);
    assert.deepEqual(unseen(['wheel', 'cups'], on, 'cups'), ['wheel']);
    assert.deepEqual(unseen(['scratch'], on), ['wheel', 'cups']);
    assert.deepEqual(unseen(['wheel'], ['wheel'], 'wheel'), ['wheel']);
    assert.equal(nextGame({ last: 'slots', weights: { slots: 1, dice: 0 }, r: rand }), 'slots');
  });
  it('weights: a game at 0 never comes, the others by their weight', () => {
    const n: Record<string, number> = {};
    for (let i = 0; i < 2000; i++) { const g = nextGame({ weights: { coin: 3, dice: 1, slots: 0 }, r: rand })!; n[g] = (n[g] ?? 0) + 1; }
    assert.equal(n.slots, undefined);
    assert.ok(n.coin! > n.dice! * 2 && n.coin! < n.dice! * 4, JSON.stringify(n));
    assert.equal(nextGame({ weights: {}, r: rand }), null);
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

const PRIZES7: PrizeWord[] = [...PRIZES, { key: 'pct25', short: '25%', label: '25% off' }, { key: 'amt100', short: '$100', label: '$100 off' }, { key: 'day1', short: 'FREE', label: '1 free day' }];
describe('bigger prizes with low odds (0081)', () => {
  it('the wheel shows all seven prizes, the common one on most slices', () => {
    const s = wheelSlices(PRIZES7);
    assert.equal(s.length, 12);
    for (const p of PRIZES7) assert.ok(s.some((x) => x.key === p.key), p.key);
    assert.ok(s.filter((x) => x.key === 'pct5').length >= 5);
    for (const p of PRIZES7) for (let i = 0; i < 200; i++) {
      const { degrees } = wheelStop(s, p.key, rand);
      assert.equal(s[Math.floor(((360 - (degrees % 360)) % 360) / 30)]!.key, p.key);
    }
  });
  it('Plinko: the rarest in the middle, every prize has a slot, every path lands on its prize', () => {
    const slots = plinkoSlots(PRIZES7);
    assert.equal(slots.length, 9);
    assert.equal(slots[4]!.key, 'day1');
    assert.deepEqual([slots[3]!.key, slots[5]!.key], ['amt100', 'pct25']);
    for (const p of PRIZES7) assert.ok(slots.some((x) => x.key === p.key), p.key);
    assert.equal(slots[0]!.key, 'pct5');
    for (const p of PRIZES7) for (let i = 0; i < 300; i++) { const { slot } = plinkoPath(slots, p.key, rand); assert.equal(slots[slot]!.key, p.key); }
  });
  const TABLE: PrizeRow[] = [
    { key: 'pct5', percent_bps: 500, weight: 69 }, { key: 'pct10', percent_bps: 1000, weight: 25 }, { key: 'pct15', percent_bps: 1500, weight: 4 },
    { key: 'amt50', amount_cents: 5000, min_days: 3, weight: 1 }, { key: 'pct25', percent_bps: 2500, max_cents: 15000, weight: 0.6 },
    { key: 'amt100', amount_cents: 10000, min_days: 4, weight: 0.3 }, { key: 'day1', free_days: 1, min_days: 3, max_cents: 15000, weight: 0.1 }];
  const at = (k: string, charge: number, days: number) => prizeCost(TABLE.find((p) => p.key === k)!, { charge_cents: charge, days }, 7500);
  it('caps: $75 for a percentage without its own, $150 for 25% off and the free day', () => {
    assert.equal(at('pct15', 100_000, 5), 7500);
    assert.equal(at('pct10', 40_000, 4), 4000);
    assert.equal(at('pct25', 100_000, 5), 15_000);
    assert.equal(at('pct25', 40_000, 4), 10_000);
    assert.equal(at('day1', 100_000, 4), 15_000);
    assert.equal(at('day1', 40_000, 4), 10_000);
  });
  it('minimum days: $50 from 3 days, $100 from 4, the free day from 3; an amount is never more than the charge', () => {
    assert.equal(at('amt50', 30_000, 2), 0);
    assert.equal(at('amt50', 30_000, 3), 5000);
    assert.equal(at('amt100', 30_000, 3), 0);
    assert.equal(at('amt100', 30_000, 4), 10_000);
    assert.equal(at('day1', 20_000, 2), 0);
    assert.equal(at('amt100', 8000, 4), 8000);
  });
  it('the expected cost of a claimed code is each prize on the average booking by its chance', () => {
    const basis = { charge_cents: 40_000, days: 4 };
    const want = 0.69 * 2000 + 0.25 * 4000 + 0.04 * 6000 + 0.01 * 5000 + 0.006 * 10_000 + 0.003 * 10_000 + 0.001 * 10_000;
    assert.ok(Math.abs(expectedCost(TABLE, basis, 7500) - want) < 0.01);
    assert.equal(expectedCost([], basis, 7500), 0);
    assert.equal(expectedCost(TABLE, { charge_cents: 0, days: 0 }, 7500), 0);
  });
});

describe('the card pack (0081)', () => {
  it('five cards, CarmaCars pictures first, the prize last, no picture twice', () => {
    for (let i = 0; i < 50; i++) {
      const c = packCards(rand);
      assert.equal(c.length, 5);
      assert.deepEqual(c[4], { kind: 'prize' });
      const titles = c.slice(0, 4).map((x) => (x.kind === 'art' ? x.title : ''));
      assert.ok(titles.every(Boolean));
      assert.equal(new Set(titles).size, 4);
    }
  });
  it('the strip tears by the share of the pack dragged across, either way, and opens past the line', () => {
    assert.equal(tearProgress(10, 10, 200), 0);
    assert.equal(tearProgress(10, 110, 200), 0.5);
    assert.equal(tearProgress(200, 50, 200), 0.75);
    assert.equal(tearProgress(0, 500, 200), 1);
    assert.equal(tearProgress(0, 50, 0), 0);
    assert.ok(tearProgress(0, 130, 200) >= TORN);
  });
  it('the pack is in the round of games', () => assert.ok(GAMES.includes('pack') && GAMES.length === 11));
});

describe('the claim form', () => {
  it('needs a first name and an email; the phone is optional but checked', () => {
    assert.deepEqual(claimProblems({ first: 'Maya', email: 'maya@example.com', phone: '' }), {});
    assert.deepEqual(Object.keys(claimProblems({ first: '', email: 'x', phone: '12' })).sort(), ['email', 'first', 'phone']);
    assert.deepEqual(claimProblems({ first: 'Maya', email: 'maya@example.com', phone: '(647) 555-0101' }), {});
    assert.deepEqual(claimProblems({ first: 'Maya', email: 'maya@example.com', phone: '+44 20 7946 0958' }), {});
  });
});

describe('the five games of 0100 land on the drawn prize', () => {
  const P: PrizeWord[] = [...PRIZES, { key: 'day1', short: 'FREE', label: '1 free day' }];
  it('the slot machine: every prize on the reels, three of the drawn prize on the line', () => {
    const strip = slotStrip(P);
    for (const p of P) assert.ok(strip.some((s) => s.key === p.key), p.key);
    for (const p of P) for (let i = 0; i < 20; i++) {
      const stops = slotStops(strip, p.key, rand);
      assert.equal(stops.length, 3);
      for (const x of stops) assert.equal(strip[x]!.key, p.key);
    }
  });
  it('the dice and the coin are fair and only for show', () => {
    const faces = new Set<number>(); const sides = new Set<string>();
    for (let i = 0; i < 500; i++) { const f = dieFace(rand); assert.ok(f >= 1 && f <= 6); faces.add(f); sides.add(coinFlip(rand)); }
    assert.equal(faces.size, 6);
    assert.deepEqual([...sides].sort(), ['heads', 'tails']);
    assert.equal(dieFace(() => 0.9999999), 6);
  });
});
