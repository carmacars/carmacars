// The investor Updates page (release 29): the notes' format, the order, the search and filter, and the deny list run over
// the generated data (investor material: no fleet size, utilization, insurance, costs, pay, other businesses, names,
// personal data, security weak points or incident details).   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { AREAS, DENY, denyHits, filterUpdates, forPage, parseNote, type Update } from './updates.ts';

const data = JSON.parse(readFileSync(new URL('./updates-data.json', import.meta.url), 'utf8')) as Update[];

test('nothing in the generated data is on the deny list', () => {
  const found: string[] = [];
  for (const u of data) for (const t of [u.title, u.summary, ...u.areas.flatMap((a) => a.items)]) for (const [w, why] of denyHits(t)) found.push(`${u.release}: "${w}" (${why}) in "${t}"`);
  assert.deepEqual(found, []);
});

test('the deny list catches what investor material must never say', () => {
  for (const t of ['Almash Auto cars', 'the Blind Spot agreement', 'cars from 01 Motors', 'Turo bookings', 'Abbas and Mahad', 'A fleet of 12 cars', '42 cars on the road',
    'utilization rose', 'occupancy', 'the insurance premium', 'insurance policy details', 'our margin', 'internal costs', 'VA pay', 'salary bands', '$1,200 a month',
    'staff commission rates', 'reach us at someone@example.test', 'call 647 555 0100', 'an XSS vulnerability', 'how the exploit worked', 'the outage of Nov 6',
    'scraper load', 'the email backlog', 'migration 0533', 'Stripe holds', 'Cloudflare Email']) assert.ok(denyHits(t).length > 0, t);
  for (const t of ['The renter portal, redesigned', 'Security hardening', 'Reliability improvements to email delivery', 'The CarmaCars app on the app stores',
    'Credit card by default, with debit and prepaid allowed per booking', 'Live November 6, 2026']) assert.deepEqual(denyHits(t), [], t);
  assert.ok(DENY.length >= 15);
});

test('a note is read with its frontmatter, its records and its items by area; a bad one is refused', () => {
  const n = parseNote('---\nrelease: r99\ntitle: Release 99\ndate: 2026-12-01\nseq: 2\nsummary: One line.\nchanges:\n  - a.md\n  - b.md\n---\n\n## Owners\n\n- An item\n- Another\n\n## Renters\n- A third\n');
  assert.deepEqual([n.release, n.date, n.seq, n.changes, n.areas.map((a) => [a.area, a.items.length])], ['r99', '2026-12-01', 2, ['a.md', 'b.md'], [['Owners', 2], ['Renters', 1]]]);
  assert.throws(() => parseNote('---\nrelease: r1\ntitle: T\ndate: soon\nsummary: S\n---\n## Owners\n- x\n'), /date/);
  assert.throws(() => parseNote('---\nrelease: r1\ntitle: T\ndate: 2026-01-01\nsummary: S\n---\n## Fleet\n- x\n'), /not an area/);
  assert.throws(() => parseNote('---\nrelease: r1\ntitle: T\ndate: 2026-01-01\n---\n## Owners\n- x\n'), /summary/);
});

test('the page shows live releases only, newest first, same-day releases by their order, areas in the fixed order', () => {
  const mk = (release: string, date: string, seq = 0) => ({ release, title: release, date, seq, summary: 's', changes: [], areas: [{ area: 'Owners' as const, items: ['o'] }, { area: 'Renters' as const, items: ['r'] }] });
  const p = forPage([mk('a', '2026-10-30'), mk('b', '2026-11-01', 1), mk('c', '2026-11-01', 2), mk('d', 'pending')]);
  assert.deepEqual(p.map((u) => u.release), ['c', 'b', 'a']);
  assert.deepEqual(p[0]!.areas.map((a) => a.area), ['Renters', 'Owners']);
  assert.ok(!('changes' in p[0]!));
  assert.deepEqual(data.map((u) => u.date), [...data.map((u) => u.date)].sort().reverse(), 'the generated data is newest first');
  for (const u of data) for (const a of u.areas) assert.ok(AREAS.includes(a.area));
});

test('search and area filter', () => {
  const r = filterUpdates(data, '', 'Owners');
  assert.ok(r.length > 0 && r.every((u) => u.areas.every((a) => a.area === 'Owners')));
  const s = filterUpdates(data, 'deposit', '');
  assert.ok(s.length > 0 && s.every((u) => u.areas.every((a) => a.items.every((i) => /deposit/i.test(`${u.title} ${u.summary} ${u.date} ${i}`)))));
  assert.deepEqual(filterUpdates(data, 'zzqx nothing', ''), []);
  const total = data.reduce((n, u) => n + u.areas.reduce((m, a) => m + a.items.length, 0), 0);
  assert.equal(filterUpdates(data, '', '').reduce((n, u) => n + u.areas.reduce((m, a) => m + a.items.length, 0), 0), total);
});
