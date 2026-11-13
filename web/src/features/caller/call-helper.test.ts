import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  HELP_PAGES, callTimer, callTimerWords, callerFirstName, faqSearch, greetingFor, greetingKey, helpParts, helperHref, splitCalls,
  type CallHelp, type CallerRenter, type LiveCall
} from './model.ts';

// r43 (migration 2720): the caller pop-up minimized to a chip, and the Call helper inside it: the greeting with the
// names, the links of a step in each portal, the search over the quick answers, and the scripts the migration seeds.
const renter: CallerRenter = {
  id: 'r1', name: 'Maya Patel', identity_status: 'verified', is_blocked: false,
  booking: { number: 'CC-10482', status: 'on_rent', car: '2024 Mercedes-Benz C 300', pickup_at: '2026-11-07T15:00:00Z', return_at: '2026-11-10T15:00:00Z', active: true },
  balance: { owed_cents: 0, rental_cents: 0, charges_cents: 0, overdue: false }, deposit: null, requests: [], notes: [], notes_count: 0
};
const call = (over: Partial<LiveCall> = {}): LiveCall => ({ id: 'a1', thread_id: 't1', number: '+14165550142', display: '(416) 555-0142', at: '2026-11-08T15:00:00Z',
  answered_at: null, ended_at: null, missed: false, live: true, kind: 'renter', who: 'Maya Patel', lead_id: null, owner_id: null, renter, ...over });
const help: CallHelp = {
  staff: 'Robin', can_edit: false,
  greetings: {
    unknown: 'Thank you for calling CarmaCars, this is {staff}, how can I help?',
    renter_booking: 'Thank you for calling CarmaCars, this is {staff}. Hi {caller}, are you calling about your booking {booking}?',
    renter: 'Thank you for calling CarmaCars, this is {staff}. Hi {caller}, how can I help?',
    lead: 'This is {staff}. Am I speaking with {caller}?', owner: 'This is {staff}. Hi {caller}, how can I help with your car today?'
  },
  situations: [], faq: [
    { code: 'faq_deposit', q: 'How much is the deposit?', a: 'A hold on the card, not a charge.', keywords: 'security hold' },
    { code: 'faq_deposit_back', q: 'When do I get my deposit back?', a: 'Within 7 business days after the return.', keywords: 'release refund' },
    { code: 'faq_late', q: 'What happens if I return the car late?', a: 'Nothing up to 30 minutes late. Open [Bookings](/bookings).', keywords: 'late return fee grace overdue' }]
};

test('the timer counts from the answer (the first ring before it) and stops when the call ends', () => {
  const t = (s: string) => Date.parse(s);
  assert.equal(callTimer(call(), t('2026-11-08T15:00:09Z')), '0:09');
  assert.equal(callTimer(call({ answered_at: '2026-11-08T15:00:10Z' }), t('2026-11-08T15:02:15Z')), '2:05');
  assert.equal(callTimer(call({ answered_at: '2026-11-08T15:00:00Z' }), t('2026-11-08T16:02:05Z')), '1:02:05');
  assert.equal(callTimer(call({ answered_at: '2026-11-08T15:00:00Z', ended_at: '2026-11-08T15:01:00Z' }), t('2026-11-08T18:00:00Z')), '1:00', 'frozen at the end');
  assert.equal(callTimer(call(), t('2026-11-08T14:59:00Z')), '0:00', 'never negative (a clock a little off)');
  assert.equal(callTimerWords('2:05'), '2 minutes 5 seconds');
  assert.equal(callTimerWords('0:01'), '1 second');
  assert.equal(callTimerWords('1:02:05'), '1 hour 2 minutes 5 seconds');
});

test('a minimized call is a chip, the others stay open; a new call opens by itself', () => {
  const calls = [call({ id: 'new' }), call({ id: 'min' })];
  const s = splitCalls(calls, { min: 1 });
  assert.deepEqual([s.open.map((c) => c.id), s.chips.map((c) => c.id)], [['new'], ['min']]);
});

test('the greeting fits the caller and carries both first names', () => {
  assert.equal(greetingKey(call()), 'renter_booking');
  assert.equal(greetingFor(call(), help), 'Thank you for calling CarmaCars, this is Robin. Hi Maya, are you calling about your booking CC-10482?');
  assert.equal(greetingFor(call({ renter: { ...renter, booking: null } }), help), 'Thank you for calling CarmaCars, this is Robin. Hi Maya, how can I help?');
  assert.equal(greetingFor(call({ kind: 'lead', renter: null, who: 'Una Known' }), help), 'This is Robin. Am I speaking with Una?');
  assert.equal(greetingFor(call({ kind: 'owner', renter: null, who: 'Omar Owner' }), help), 'This is Robin. Hi Omar, how can I help with your car today?');
  assert.equal(greetingFor(call({ kind: 'unknown', renter: null, who: '(416) 555-0199' }), help), 'Thank you for calling CarmaCars, this is Robin, how can I help?');
});

test('a caller with no name, or a greeting that is off, gets the greeting for a caller we do not know', () => {
  // a lead known only by its number is never greeted with digits
  const lead = call({ kind: 'lead', renter: null, who: '(416) 555-0142' });
  assert.equal(callerFirstName(lead), null);
  assert.equal(greetingFor(lead, help), 'Thank you for calling CarmaCars, this is Robin, how can I help?');
  // the staff greeting is off (not in the read)
  assert.equal(greetingFor(call({ kind: 'staff', renter: null, who: 'Sam Staff' }), help), 'Thank you for calling CarmaCars, this is Robin, how can I help?');
  // nothing read at all: the owner's sentence, and never a brace on the screen
  assert.equal(greetingFor(call(), { staff: 'Robin', greetings: {} }), 'Thank you for calling CarmaCars, this is Robin, how can I help?');
  assert.doesNotMatch(greetingFor(call({ renter: { ...renter, booking: null } }), { staff: 'Robin', greetings: { renter: 'Hi {caller}, about the {car}?', unknown: 'Hello from {staff} {car}' } }), /[{}]/);
});

test('a link in a step goes to the reader\'s own portal, or is plain words where that portal has no such page', () => {
  assert.equal(helperHref('admin', '/offers/new'), '/admin/offers/new');
  assert.equal(helperHref('va', '/offers/new'), '/staff/offers/new');
  assert.equal(helperHref('va', '/card-coverage'), '/staff/card-coverage');
  assert.equal(helperHref('admin', '/card-coverage'), '/admin/settings/card-coverage');
  assert.equal(helperHref('admin', '/hiring'), '/admin/hiring');
  assert.equal(helperHref('va', '/hiring'), null);
  assert.equal(helperHref('va', '/settings/program'), null);
  assert.equal(helperHref('va', 'https://example.test/policy'), 'https://example.test/policy');
  for (const bad of ['javascript:alert(1)', '//example.test', 'http://example.test', '/../admin', '/Bookings', '']) assert.equal(helperHref('admin', bad), null, bad);
  assert.deepEqual(helpParts('va', 'Open [Bookings](/bookings) and tell [Hiring](/hiring).'),
    [{ text: 'Open ' }, { text: 'Bookings', href: '/staff/bookings' }, { text: ' and tell ' }, { text: 'Hiring' }, { text: '.' }]);
  assert.deepEqual(helpParts('admin', 'See [the policy](https://example.test/p)'), [{ text: 'See ' }, { text: 'the policy', href: 'https://example.test/p', outside: true }]);
});

test('every page a step may link to is a real folder of that portal', () => {
  const app = fileURLToPath(new URL('../../app/', import.meta.url));
  for (const p of HELP_PAGES.admin) assert.ok(existsSync(`${app}admin/${p}`), `admin/${p}`);
  for (const p of HELP_PAGES.va) assert.ok(existsSync(`${app}staff/${p}`), `staff/${p}`);
});

test('the search finds a quick answer by any of its words, the question first, and nothing for nothing typed', () => {
  assert.deepEqual(faqSearch(help.faq, ''), []);
  assert.deepEqual(faqSearch(help.faq, ' a '), []);
  assert.deepEqual(faqSearch(help.faq, 'deposit').map((f) => f.code), ['faq_deposit', 'faq_deposit_back']);
  assert.deepEqual(faqSearch(help.faq, 'DEPOSIT back').map((f) => f.code), ['faq_deposit_back']);
  assert.deepEqual(faqSearch(help.faq, 'overdue').map((f) => f.code), ['faq_late'], 'by a search word');
  assert.deepEqual(faqSearch(help.faq, 'refund').map((f) => f.code), ['faq_deposit_back']);
  assert.deepEqual(faqSearch(help.faq, 'bookings').map((f) => f.code), ['faq_late'], 'the words of a link, not its address');
  assert.deepEqual(faqSearch(help.faq, 'helicopter'), []);
  assert.equal(faqSearch(help.faq, 'the', 1).length, 1);
});

test('the scripts the migration seeds: the owner\'s greeting, ten situations of 3 to 6 steps, links that open in both portals, no typed policy number', () => {
  const sql = readFileSync(new URL('../../../../supabase/migrations/2720_r43_call_helper.sql', import.meta.url), 'utf8');
  assert.ok(sql.includes("'Thank you for calling CarmaCars, this is {staff}, how can I help?'"));
  const seed = sql.slice(sql.indexOf('7. the first scripts'), sql.indexOf('8. privileges'));
  const situations = [...seed.matchAll(/\('situation', '([a-z_]+)', '([^']+)',\n '((?:[^']|'')+)', \d+\)/g)];
  assert.equal(situations.length, 10);
  for (const [, code, , body] of situations) {
    const steps = body!.split('\n').filter((l) => l.trim());
    assert.ok(steps.length >= 3 && steps.length <= 6, `${code}: ${steps.length} steps`);
  }
  const links = [...seed.matchAll(/\]\(([^)]+)\)/g)].map((m) => m[1]!);
  assert.ok(links.length >= 8);
  for (const l of links) assert.ok(helperHref('admin', l), `admin: ${l}`);
  // customer service has every page but Hiring (an Admin's), which is then plain words
  assert.deepEqual([...new Set(links.filter((l) => !helperHref('va', l)))], ['/hiring']);
  // amounts, days and percentages come from the settings ({tokens}), never typed: no dollar sign and no percent sign
  assert.doesNotMatch(seed, /\$\d|\d\s?%/);
  // plain words: no long dash in what staff read
  assert.doesNotMatch(seed, /[–—]/);
});

test('the helper is wired: its read goes through the phone route, the Admin page is in Settings, both layouts keep the pop-up', () => {
  const src = (p: string) => readFileSync(new URL(p, import.meta.url), 'utf8');
  assert.ok(src('../../app/api/staff/phone/route.ts').includes("'call_helper'"));
  assert.match(src('./CallerPopup.tsx'), /phoneRead<CallHelp>\('call_helper'\)/);
  assert.match(src('../../app/admin/settings/sections.ts'), /\['call-helper', 'Call helper'/);
  assert.match(src('../../app/admin/settings/call-helper/page.tsx'), /call_helper_admin/);
  // minimize, never close, on Esc and on a click outside; the cross still closes
  const pop = src('./CallerPopup.tsx');
  for (const id of ['caller-minimize', 'caller-close', 'caller-chip', 'caller-chip-timer']) assert.ok(pop.includes(`data-testid="${id}"`), id);
  assert.match(pop, /e\.key !== 'Escape'/);
  assert.match(pop, /addEventListener\('pointerdown'/);
});
