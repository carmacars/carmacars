import { test } from 'node:test';
import assert from 'node:assert/strict';
import { keyFacts, llmsFullTxt, llmsTxt, summary, type EntityFacts } from './llms.ts';
import { ANSWER_CRAWLERS, PRIVATE_PATHS } from './crawlers.ts';

const base: EntityFacts = {
  name: 'CarmaCars', url: 'https://carmacars.ca', tagline: 'What goes around, drives around.',
  phone: '289-312-5991', phoneE164: '+12893125991', whatsapp: null, email: 'hello@carmacars.ca', roadside: null,
  address: '1570 Midland Ave, Toronto, ON M1P 3C2', city: 'Toronto', region: 'Ontario', serviceArea: 'Toronto and the GTA', hours: 'Open 24 hours, every day', reply: 'We reply within 2 hours',
  updated: '2026-10-22',
  fleet: { realCars: 3, classes: [{ label: 'Economy', count: 2, fromDailyCents: 4900 }, { label: 'Luxury', count: 1, fromDailyCents: 19900 }], fromDailyCents: 4900, fromWeeklyCents: 29900, fromMonthlyCents: 99900, deliveryFromCents: 2500 },
  drivers: { minAge: 21, licence: 'a full G licence', youngBands: '21 to 22 and 23 to 24' },
  policy: { maxDays: 30, weekFrom: 7, deposits: '$250 to $1,000', hst: '13%', cancellation: '100% back within 24 hours of booking', noticeHours: '2 hours', depositLead: '1 hour' },
  airports: ['Toronto Pearson International Airport'], chauffeurFromCents: 12000, chauffeurMinHours: 2,
  services: [{ name: 'Car rental in Toronto', path: '/car-rental' }], locations: [{ name: 'Mississauga', path: '/car-rental/mississauga' }], uses: [], guides: [],
  pages: [{ name: 'About and facts', path: '/about' }], faq: [{ question: 'Do I pay to request?', answer: 'No. <a href="/faq">More</a>' }], profiles: []
};

test('the summary names who, what, where, the price from and how to book, from the facts only', () => {
  const s = summary(base);
  for (const x of ['CarmaCars', 'car rental company in Toronto at 1570 Midland Ave', 'across Toronto and the GTA', 'from $49 a day', 'Toronto Pearson', 'carmacars.ca', 'no payment to request', '289-312-5991']) assert.ok(s.includes(x), x);
  assert.doesNotMatch(s, /[–—]/, 'no dashes');
});

test('no real car: no price anywhere, never a made-up one', () => {
  const f = { ...base, fleet: { realCars: 0, classes: [], fromDailyCents: null, fromWeeklyCents: null, fromMonthlyCents: null, deliveryFromCents: null }, chauffeurFromCents: null };
  assert.doesNotMatch(summary(f), /\$/);
  assert.doesNotMatch(keyFacts(f).map((r) => r[1]).join(' '), /\$/);
  assert.match(llmsFullTxt(f), /first cars are being listed/);
  assert.doesNotMatch(keyFacts(f).find((r) => r[0] === 'What')![1], /chauffeur/);
});

test('llms.txt follows llmstxt.org: an H1, a blockquote summary, H2 lists of absolute links', () => {
  const t = llmsTxt(base);
  assert.match(t, /^# CarmaCars\n\n> CarmaCars is a car rental company/);
  assert.match(t, /\n## Services\n\n- \[Car rental in Toronto\]\(https:\/\/carmacars\.ca\/car-rental\)/);
  assert.match(t, /- Facts updated: 2026-10-22/);
  assert.match(t, /https:\/\/carmacars\.ca\/llms-full\.txt/);
  assert.doesNotMatch(t, /\n\n\n/);
});

test('llms-full.txt: contact, prices by class, policies and the questions in plain text', () => {
  const t = llmsFullTxt(base);
  for (const x of ['- Phone: 289-312-5991', '- Economy: 2 cars, from $49 a day', 'Chauffeur service from $120 an hour, 2 hours minimum', '### Do I pay to request?', 'No. More', 'before HST (13%)', 'taken about 1 hour before pickup']) assert.ok(t.includes(x), x);
  assert.doesNotMatch(t, /<a /, 'no HTML');
});

test('no date: no "updated" line', () => {
  assert.doesNotMatch(llmsTxt({ ...base, updated: null }), /updated/i);
});

test('robots: the AI answer engines are named and the private paths kept out', () => {
  for (const b of ['OAI-SearchBot', 'ChatGPT-User', 'GPTBot', 'ClaudeBot', 'Claude-SearchBot', 'Claude-User', 'PerplexityBot', 'Perplexity-User', 'Google-Extended', 'Applebot', 'Applebot-Extended',
    'Bingbot', 'DuckDuckBot', 'DuckAssistBot', 'Amazonbot', 'Meta-ExternalAgent', 'CCBot', 'YandexBot']) assert.ok((ANSWER_CRAWLERS as readonly string[]).includes(b), b);
  for (const p of ['/admin', '/account', '/owner', '/investor', '/api/', '/sign-in', '/auth/']) assert.ok((PRIVATE_PATHS as readonly string[]).includes(p), p);
  assert.equal(new Set(ANSWER_CRAWLERS).size, ANSWER_CRAWLERS.length);
});
