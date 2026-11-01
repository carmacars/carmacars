// Invoices, receipts and statements name the company by its legal name alone (the insurance requirement: legal documents
// and card charges name only "18122211 Canada Inc.", never "operating as"; docs/changes/2026-11-06-audit-gaps.md).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { companyParty } from '../../lib/format.ts';

test('the documents\' "From" and "Company" rows: the legal name alone', () => {
  assert.equal(companyParty('18122211 Canada Inc.', 'CarmaCars'), '18122211 Canada Inc.');
  assert.equal(companyParty('', 'CarmaCars'), 'CarmaCars');
});

test('no document builder writes "operating as" (invoices, receipts, statements, pay statements)', () => {
  const dir = import.meta.dirname;
  for (const f of readdirSync(dir).filter((x) => x.endsWith('.ts') && !x.endsWith('.test.ts'))) {
    assert.doesNotMatch(readFileSync(join(dir, f), 'utf8'), /operating as/i, f);
  }
});
