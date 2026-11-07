import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { currentLink, menuFor, movedTo, tabOf, tabsFor, type MenuLink, type PageTab } from './tabs.ts';
import { RENTER_ACCOUNT_TABS, RENTER_MENU, RENTER_MOVED } from '../portal/menu.ts';
import { OWNER_ACCOUNT_TABS, OWNER_CARS_TABS, OWNER_MENU, OWNER_MONEY_TABS, OWNER_MOVED } from '../owner/menu.ts';
import { INVESTOR_DOCUMENT_TABS, INVESTOR_MENU, INVESTOR_MOVED } from '../investor/menu.ts';
import { renterNow, whenWords } from '../portal/now.ts';
import { carsOutLine, earnedThisMonth } from '../owner/now.ts';
import type { BookingSummary } from '../portal/types.ts';

// The customer portals' menus, tabs and old addresses (r27 portals): at most five or six links per portal, one menu link
// current on every page, every old address landing on a tab of its merged page with its query, every page keeping its
// own sign-in and role check, and the homes' first line.

const TABS: Record<string, PageTab[]> = {
  '/account/profile': RENTER_ACCOUNT_TABS, '/owner/vehicles': OWNER_CARS_TABS, '/owner/money': OWNER_MONEY_TABS, '/owner/account': OWNER_ACCOUNT_TABS,
  '/investor/documents': INVESTOR_DOCUMENT_TABS
};

describe('menus', () => {
  it('has at most six links in each portal, five for the owner, six for the investor, four for the renter', () => {
    assert.equal(RENTER_MENU.length, 4);
    assert.equal(OWNER_MENU.length, 5);
    assert.equal(INVESTOR_MENU.length, 6);
    for (const m of [RENTER_MENU, OWNER_MENU, INVESTOR_MENU]) assert.ok(m.length <= 6);
  });
  it('marks one link current on the home, a merged page, its old address and a detail page', () => {
    const at = (m: MenuLink[], p: string) => currentLink(m, p)?.label;
    assert.equal(at(RENTER_MENU, '/account'), 'Trips');
    assert.equal(at(RENTER_MENU, '/account/bookings/CC-10001/pay'), 'Trips');
    assert.equal(at(RENTER_MENU, '/account/profile'), 'Account');
    assert.equal(at(RENTER_MENU, '/account/documents'), 'Documents');
    assert.equal(at(OWNER_MENU, '/owner'), 'Home');
    assert.equal(at(OWNER_MENU, '/owner/vehicles/abc'), 'Cars');
    assert.equal(at(OWNER_MENU, '/owner/statements/abc'), 'Money');
    assert.equal(at(OWNER_MENU, '/owner/invoices/INV-1'), 'Money');
    assert.equal(at(OWNER_MENU, '/owner/sign'), 'Documents');
    assert.equal(at(OWNER_MENU, '/owner/account'), 'Account');
    assert.equal(at(INVESTOR_MENU, '/investor'), 'Home');
    assert.equal(at(INVESTOR_MENU, '/investor/statements/abc'), 'Documents');
    assert.equal(at(INVESTOR_MENU, '/investor/sign/abc'), 'Documents');
    assert.equal(at(INVESTOR_MENU, '/investor/model'), 'Live sheets');
    assert.equal(at(OWNER_MENU, '/account'), undefined);
  });
  it('shows the deck and the live sheets only when the frame says so', () => {
    assert.deepEqual(menuFor(INVESTOR_MENU, {}).map((l) => l.label), ['Home', 'Documents', 'Updates', 'Account']);
    assert.deepEqual(menuFor(INVESTOR_MENU, { investor: true, deck: true }).map((l) => l.label), ['Home', 'Live sheets', 'Documents', 'Updates', 'Investor deck', 'Account']);
  });
  it('gives a partner rental company no Invoices tab', () => {
    assert.deepEqual(tabsFor(OWNER_MONEY_TABS, { nofees: true }).map((t) => t.key), ['statements', 'payouts']);
    assert.deepEqual(tabsFor(OWNER_MONEY_TABS, { nofees: false }).map((t) => t.key), ['statements', 'payouts', 'invoices']);
  });
  it('names nothing about the fleet in the investor menu', () => {
    for (const l of [...INVESTOR_MENU, ...INVESTOR_DOCUMENT_TABS]) assert.doesNotMatch(l.label, /fleet|utili|insurance|premium|cost/i);
  });
});

describe('tabs and old addresses', () => {
  it('opens the first tab without a value or with an unknown one', () => {
    assert.equal(tabOf(OWNER_MONEY_TABS, undefined).key, 'statements');
    assert.equal(tabOf(OWNER_MONEY_TABS, 'nope').key, 'statements');
    assert.equal(tabOf(OWNER_MONEY_TABS, ['payouts']).key, 'payouts');
  });
  it('sends every old address to a tab of its merged page, the tab addresses matching', () => {
    for (const moved of [RENTER_MOVED, OWNER_MOVED, INVESTOR_MOVED]) {
      for (const [from, [to, tab]] of Object.entries(moved)) {
        if (tab === null) continue;
        const tabs = TABS[to];
        assert.ok(tabs, `${from}: ${to} is a merged page`);
        const t = tabs.find((x) => x.key === tab);
        assert.ok(t, `${from}: tab ${tab} on ${to}`);
        assert.equal(t.href.split('?')[0], to);
      }
    }
  });
  it('keeps the query of an old address, and drops the tab value for the first tab', () => {
    assert.equal(movedTo('/owner/money', 'invoices', { paid: '1' }), '/owner/money?tab=invoices&paid=1');
    assert.equal(movedTo('/owner/vehicles', 'bookings', { vehicle: 'v1' }), '/owner/vehicles?tab=bookings&vehicle=v1');
    assert.equal(movedTo('/account', null, {}), '/account');
    assert.equal(movedTo('/account', null, { welcome: '1' }), '/account?welcome=1');
    assert.equal(movedTo('/investor/documents', 'sign', { signed: '1', tab: 'x' }), '/investor/documents?tab=sign&signed=1');
    assert.equal(movedTo('/owner/account', 'notifications', { a: ['1', '2'] }), '/owner/account?tab=notifications&a=1&a=2');
  });
  it('links every tab to its own page address', () => {
    for (const [page, tabs] of Object.entries(TABS)) {
      assert.equal(tabs[0]!.href, page, `${page}: the first tab is the page itself`);
      for (const t of tabs.slice(1)) assert.equal(t.href, `${page}?tab=${t.key}`);
    }
  });
});

describe('every portal page checks who is signed in', () => {
  const APP = join(import.meta.dirname, '../../app');
  const walk = (d: string): string[] => readdirSync(d).flatMap((n) => { const p = join(d, n); return statSync(p).isDirectory() ? walk(p) : [p]; });
  for (const portal of ['account', 'owner', 'investor']) {
    it(`${portal}: each page checks the session and role itself, or redirects`, () => {
      for (const f of walk(join(APP, portal)).filter((p) => p.endsWith('/page.tsx'))) {
        const code = readFileSync(f, 'utf8');
        const ok = /require(User|Owner|OwnerUser|Investor)\(|myBooking\(|currentUser\(|redirect\(|NoAccess|requireUser/.test(code);
        assert.ok(ok, `${f.slice(APP.length)} checks nothing`);
      }
    });
  }
  it('the merged pages check once at the top and hand the tabs what they read', () => {
    for (const [f, check] of [['account/profile/page.tsx', 'requireUser('], ['owner/money/page.tsx', 'requireOwner('], ['owner/account/page.tsx', 'requireOwner('], ['owner/vehicles/page.tsx', 'requireOwner('], ['investor/documents/page.tsx', 'requireInvestor(']] as const) {
      assert.ok(readFileSync(join(APP, f), 'utf8').includes(check), `${f} calls ${check}`);
    }
  });
});

describe('the homes say what is next first', () => {
  const NOW = Date.parse('2026-11-06T15:00:00Z'); // Friday 10:00 a.m. in Toronto
  const b = (over: Partial<BookingSummary>): BookingSummary => ({
    id: 'b1', booking_number: 'CC-10421', status: 'on_rent', booking_type: 'rental', vehicle_id: 'v1', vehicle_year: 2024, vehicle_make: 'Volkswagen', vehicle_model: 'Jetta',
    vehicle_colour: null, slug: null, pickup_at: '2026-11-03T14:00:00Z', return_at: '2026-11-07T00:00:00Z', pickup_place: null, return_place: null, pickup_method: 'office', return_method: 'office',
    billable_days: 4, offer_expires_at: null, current_offer_version: 1, offer_approved_version: 1, total_due_at_booking_cents: 0, renter_due_at_booking_cents: 0, deposit_cents: 0,
    hst_at_booking_cents: 0, subtotal_at_booking_cents: 0, insurer_pays_cents: 0, coverage_option: null, coverage_confirmed_at: null, confirmed_at: null, handed_over_at: null, checked_in_at: null,
    request_note: null, km_allowance_total: null, overage_cents_per_km: null, deductible_cents: null, agreement_number: null, requested_at: null, booked_at: null, ...over
  });
  it('says the day in words when it is near', () => {
    assert.equal(whenWords('2026-11-07T00:00:00Z', NOW), 'today at 7:00 p.m.');
    assert.equal(whenWords('2026-11-07T15:00:00Z', NOW), 'tomorrow at 10:00 a.m.');
    assert.match(whenWords('2026-11-10T14:00:00Z', NOW), /^Tue, Nov 10 at 9:00 a\.m\.$/);
  });
  it('on a trip: return the car today at 7 p.m. at the place, then Pay the balance, Extend', () => {
    const n = renterNow(b({}), { title: 'Return by Fri', note: '', href: '/account/bookings/CC-10421', cta: 'Return details' }, { pickupPlace: '1 Example St', returnPlace: '1 Example St, Toronto', balanceCents: 4250, now: NOW });
    assert.equal(n.headline, 'Return the 2024 Volkswagen Jetta today at 7:00 p.m.');
    assert.equal(n.detail, '1 Example St, Toronto');
    assert.deepEqual(n.actions.map((a) => a.label), ['Pay $42.50', 'Extend', 'Trip details', 'Message us']);
    assert.equal(n.actions.find((a) => a.primary)?.key, 'pay');
    assert.equal(n.urgent, true);
  });
  it('booked: pick it up, with what to bring; an urgent step (sign) comes first with the time', () => {
    const c = renterNow(b({ status: 'confirmed', pickup_at: '2026-11-07T15:00:00Z' }), { title: 'You are all set', note: '', href: '/account/bookings/CC-10421', cta: 'Pickup details' }, { pickupPlace: '1 Example St', returnPlace: null, now: NOW });
    assert.equal(c.headline, 'Pick up the 2024 Volkswagen Jetta tomorrow at 10:00 a.m.');
    assert.match(c.detail ?? '', /^1 Example St\. Bring your original licence/);
    const s = renterNow(b({ status: 'confirmed', pickup_at: '2026-11-07T15:00:00Z' }), { title: 'Sign your rental agreement', note: 'Read and sign the agreement before pickup.', href: '/account/bookings/CC-10421/sign', cta: 'Sign agreement', urgent: true }, { pickupPlace: null, returnPlace: null, now: NOW });
    assert.equal(s.headline, 'Sign your rental agreement');
    assert.match(s.detail ?? '', /Pickup tomorrow at 10:00 a\.m\./);
    assert.equal(s.actions[0]!.label, 'Sign agreement');
    assert.equal(s.actions[0]!.primary, true);
  });
  it('an offer: the step itself, its button first', () => {
    const o = renterNow(b({ status: 'offered' }), { title: 'Approve your offer', note: 'Offer open until Fri.', href: '/account/bookings/CC-10421/offer', cta: 'Review offer', urgent: true }, { pickupPlace: null, returnPlace: null, now: NOW });
    assert.equal(o.headline, 'Approve your offer');
    assert.equal(o.actions[0]!.label, 'Review offer');
    assert.ok(!o.actions.some((a) => a.key === 'extend'));
  });
  it('owner: the line under Hello says how many cars are out; the figures carry the money', () => {
    assert.equal(carsOutLine(2, 3), '2 of 3 cars out right now.');
    assert.equal(carsOutLine(0, 1), 'Your car is not out right now.');
    assert.equal(carsOutLine(0, 4), 'None of your 4 cars are out right now.');
    assert.equal(carsOutLine(0, 0), 'Your cars appear here as they join.');
  });
  it('owner: earned this month is the approved payout, else the month so far', () => {
    assert.deepEqual(earnedThisMonth(null), { cents: null, final: false });
    assert.deepEqual(earnedThisMonth({ month: '2026-11-01', final: true, payout_cents: 5000, in_progress: [] } as never), { cents: 5000, final: true });
    assert.deepEqual(earnedThisMonth({ month: '2026-11-01', final: false, totals: { net_earnings_cents: 7000 }, in_progress: [] } as never), { cents: 7000, final: false });
  });
});
