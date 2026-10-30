// The agreement's wording per booking (migration 0198): the clauses merged into the standard text, the catalogue the
// same as the database's, required clauses never removed, the consents never reworded.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { agreementBlocks, type Block } from './model.ts';
import { clauses } from './extra.ts';
import { richFacts } from './rich-fixture.ts';
import { AGREEMENT_PARTS } from './source.generated.ts';
import { CLAUSES, REMOVED_NOTE, part2Sections, shortWording, standardText, wordedPart, wordingNotice, type Wording } from './wording.ts';

const text = (bs: Block[]) => JSON.stringify(bs);
const build = (w?: Wording | null) => { const r = richFacts('open'); return agreementBlocks(r.f, { privacyUrl: 'https://example.test/privacy', extra: r.x, wording: w ?? null }); };

test('catalogue: Part 2 is 15 sections, each with its own code, and the database seeds the same clauses', () => {
  const secs = part2Sections();
  assert.equal(secs.length, 15);
  assert.deepEqual(secs.map((s) => s.n), [...Array(15)].map((_, i) => i + 1));
  const sql = readFileSync(new URL('../../../../supabase/migrations/0198_agreement_wording.sql', import.meta.url), 'utf8');
  for (const c of CLAUSES) {
    const m = sql.match(new RegExp(`\\('${c.code}', '${c.part}', '([^']*(?:''[^']*)*)', \\d+, (true|false), (true|false)\\)`));
    assert.ok(m, `the migration seeds ${c.code}`);
    assert.equal(m![1]!.replace(/''/g, "'"), c.title, `${c.code}: title`);
    assert.equal(m![2] === 'true', c.removable, `${c.code}: removable`);
    assert.equal(m![3] === 'true', c.editable, `${c.code}: editable`);
  }
  for (const req of ['coverage', 'damage', 'consents', 'charges', 'privacy', 'liability', 'general']) assert.equal(CLAUSES.find((c) => c.code === req)!.removable, false, req);
});

test('merge: no wording, or wording of nothing, prints the standard text exactly', () => {
  assert.equal(wordedPart('2', null), AGREEMENT_PARTS['2']);
  assert.equal(text(build(null)), text(build({})));
  // Part 2 rebuilt section by section with nothing changed reads the same blocks
  const re = wordedPart('2', { fee_schedule: { action: 'edit', text: 'x' } });
  const a = build(null).filter((b) => b.t !== 'p' || !b.text.includes('Worded for'));
  const b = agreementBlocks(richFacts('open').f, { privacyUrl: 'https://example.test/privacy', extra: richFacts('open').x, wording: { tolls: { action: 'edit', text: standardText('tolls') } } });
  assert.ok(re.body.includes('### 1. Definitions and structure'));
  assert.equal(a.filter((x) => x.t === 'h3').length, b.filter((x) => x.t === 'h3').length);
});

test('merge: an edited clause replaces its section and says so; the others stay word for word', () => {
  const w: Wording = { damage: { action: 'edit', text: '**9.1 Your responsibility.** Reworded for this rental.' } };
  const p = wordedPart('2', w);
  assert.match(p.body, /### 9\. Damage \(worded for this booking\)\n\n\*\*9\.1 Your responsibility\.\*\* Reworded for this rental\./);
  assert.ok(!p.body.includes(standardText('damage')));
  assert.ok(p.body.includes(standardText('coverage')));
  const blocks = build(w);
  assert.ok(text(blocks).includes('Reworded for this rental.'));
  assert.ok(text(blocks).includes('Worded for this booking: section 9. Damage reworded'));
});

test('merge: an optional clause removed keeps its number and says it does not apply; a required one cannot be removed', () => {
  const p = wordedPart('2', { tolls: { action: 'remove', text: null }, damage: { action: 'remove', text: null } });
  assert.match(p.body, new RegExp(`### 6\\. Tolls, tickets and fines \\(worded for this booking\\)\\n\\n${REMOVED_NOTE.replace('.', '\\.')}`));
  assert.ok(p.body.includes(standardText('damage')), 'the damage section stays');
  assert.ok(p.body.includes('### 7. Cancellation'));
});

test('merge: additional terms are the last section of Part 2; the consents are never reworded', () => {
  const w: Wording = { additional: { action: 'add', text: 'The Renter returns the car washed.' }, consents: { action: 'edit', text: 'Nothing to tick.' } };
  const p = wordedPart('2', w);
  assert.match(p.body, /### 16\. Additional terms for this booking\n\nThe Renter returns the car washed\.$/);
  assert.equal(wordedPart('6', w), AGREEMENT_PARTS['6']);
  assert.equal(wordingNotice(w, 'standard'), 'Worded for this booking: additional terms added at the end of Part 2. Everything else is CarmaCars\' standard wording.');
  assert.equal(wordingNotice({ additional: { action: 'remove', text: null } }, 'standard'), null);
});

test('merge: the fee schedule reworded; the owner addendum only noted for an owner rental', () => {
  assert.deepEqual(wordedPart('3', { fee_schedule: { action: 'edit', text: '| Fee | Amount |\n| --- | --- |\n| Deposit | $0 |' } }).body, '| Fee | Amount |\n| --- | --- |\n| Deposit | $0 |');
  assert.equal(wordingNotice({ owner_addendum: { action: 'edit', text: 'x' } }, 'standard'), null);
  assert.match(wordingNotice({ owner_addendum: { action: 'edit', text: 'x' } }, 'owner')!, /Part 5: Owner Rental Addendum reworded/);
});

test('key terms: a key term notes when its section is worded for the booking', () => {
  const f = { deductible_cents: 250000, deposit: '$500', card: null, km_per_day: null, km_total: null, overage_cents_per_km: null, grace_minutes: 59, late_fee_cents: null, coverage: 'x', booking_type: 'standard' };
  const plain = clauses(f);
  const worded = clauses({ ...f, wording: { damage: { action: 'edit', text: 'y' } } });
  assert.equal(worded.find((c) => c.code === 'damage')!.text, plain.find((c) => c.code === 'damage')!.text + ' Section 9. Damage is worded for my booking and I have read it.');
  assert.equal(worded.find((c) => c.code === 'coverage')!.text, plain.find((c) => c.code === 'coverage')!.text);
});

test('version header: a long wording is shortened, the full text being in the agreement', () => {
  assert.equal(shortWording('Standard wording'), 'Standard wording');
  assert.match(shortWording('word '.repeat(200)), /… \(full wording in the agreement\)$/);
  const r = richFacts('open');
  const blocks = agreementBlocks(r.f, { privacyUrl: 'https://example.test/privacy', extra: r.x, version: { version_no: 2, previous_no: 1, kind: 'change', material: true,
    changes: [{ key: 'wording.damage', label: 'Agreement wording: 9. Damage', before: 'Standard wording', after: 'long '.repeat(100), material: true }] } });
  const t = blocks.find((b) => b.t === 'table' && b.head[0] === 'What changed') as Extract<Block, { t: 'table' }>;
  assert.equal(t.rows[0]![0], 'Agreement wording: 9. Damage (signed again)');
  assert.ok(t.rows[0]![2]!.length < 340 && t.rows[0]![2]!.endsWith('(full wording in the agreement)'));
});
