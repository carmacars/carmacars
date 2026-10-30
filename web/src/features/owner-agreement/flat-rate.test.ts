// The flat-rate owner agreement set (migration 0205): an owner paid a flat monthly amount per car reads and signs the
// Flat-Rate Vehicle Enrollment Agreement; the Title-Holding and Lease Agreement is the standard one. Facts from
// tests/fixtures/agreements/facts.json, made flat.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import type { Block } from '../agreement/model.ts';
import { confirmationsOf, documentBlocks, FLAT_TEMPLATE_VERSION, OWNER_TEMPLATE_VERSION, packetKeys, templateVersionOf, titleOf, type OwnerAgreementFacts } from './model.ts';

const F = JSON.parse(readFileSync(new URL('../../../tests/fixtures/agreements/facts.json', import.meta.url), 'utf8')) as { owner: OwnerAgreementFacts };
const flat = (replaces = false): OwnerAgreementFacts => {
  const f = structuredClone(F.owner);
  return { ...f, pay_model: 'flat_rate', company: { ...f.company, legal_name: '18122211 Canada Inc.' },
    agreements: f.agreements.map((a) => (a.kind === 'enrollment' ? { ...a, status: 'draft', variant: 'flat_rate' as const, replaces } : a)),
    schedules: f.schedules.map((s) => ({ ...s, monthly_cents: 90000, signed_at: replaces ? '2026-09-01T12:00:00Z' : s.signed_at })) };
};
const text = (blocks: Block[]) => blocks.map((b) => ('text' in b ? b.text : 'rows' in b && b.t === 'table' ? b.rows.flat().join(' | ') : 'items' in b ? b.items.join(' ') : '')).join('\n');

test('the flat-rate Enrollment Agreement: its own title, the Monthly Amount, no revenue share or fees, the company by its legal name only', () => {
  const f = flat();
  const t = text(documentBlocks(f, 'enrollment'));
  assert.equal(titleOf(f, 'enrollment'), 'Flat-Rate Vehicle Enrollment Agreement');
  assert.match(t, /\*\*Company\*\*: 18122211 Canada Inc\.|Company.*18122211 Canada Inc\./);
  assert.match(t, /Monthly Amount \| \$900(\.00)? a month/);
  assert.doesNotMatch(t, /Revenue Share \||Insurance Fee and Tracker Fee per month/);
  assert.doesNotMatch(t, /operating as|\bnull\b|undefined|NaN|[–—]/);
  assert.equal(templateVersionOf(f, 'enrollment'), FLAT_TEMPLATE_VERSION);
  assert.equal(templateVersionOf(f, 'title_holding'), OWNER_TEMPLATE_VERSION);
  assert.equal(titleOf(f, 'title_holding'), 'Title-Holding and Lease Agreement');
  assert.match(confirmationsOf(f).map((c) => c.text).join(' '), /Monthly Amount is all I am paid/);
});

test('a change of pay model is signed again, even when every car is signed', () => {
  assert.deepEqual(packetKeys(flat(true)), ['enrollment']);
});
