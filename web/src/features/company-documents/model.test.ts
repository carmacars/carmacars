// Admin > Company documents (r50, migration 5060): the placeholders, the fill-ins still missing, and the blocks the page and
// the PDFs render. Dummy text only: the real agreements are never in the repository.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { bodyBlocks, documentBlocks, fieldLabel, missingFields, placeholders, signedCopyPath } from './model.ts';

const BODY = '# Parties\n\nThis dummy text binds {{holdco_a}} and {{holdco_b}}.\n\n## Money\n\n- Each puts in {{amount}}\n- {{holdco_a}} pays first';

test('placeholders in order of first use, each once; the missing ones', () => {
  assert.deepEqual(placeholders(BODY), ['holdco_a', 'holdco_b', 'amount']);
  assert.deepEqual(missingFields(BODY, { holdco_a: 'A Inc.', amount: ' ' }), ['holdco_b', 'amount']);
  assert.equal(fieldLabel('holdco_a_name'), 'Holdco a name');
});

test('the database finds the same placeholders (the same pattern as the renderer)', () => {
  const sql = readFileSync(new URL('../../../../supabase/migrations/5060_r50_company_documents.sql', import.meta.url), 'utf8');
  assert.match(sql, /regexp_matches\(coalesce\(p_body, ''\), '\\\{\\\{\(\[A-Za-z0-9_\]\+\)\\\}\\\}', 'g'\)/);
});

test('the body as blocks: headings as sections, fill-ins substituted, an empty one a blank line', () => {
  const b = bodyBlocks(BODY, { holdco_a: 'A Inc.', amount: '$10' });
  assert.deepEqual(b[0], { t: 'h3', text: 'Parties' });
  assert.deepEqual(b[1], { t: 'p', text: 'This dummy text binds A Inc. and ________.' });
  assert.deepEqual(b[3], { t: 'ul', items: ['Each puts in $10', 'A Inc. pays first'] });
});

test('the whole document: title, version, body, the fill-ins table and the signatures', () => {
  const b = documentBlocks({ title: 'Dummy agreement', version: 2, body_md: BODY, fields: { holdco_a: 'A', holdco_b: 'B', amount: '1' } },
    [{ party: 'Side A', name: 'Sam Example', signature: 'Typed: Sam Example', when: 'Nov 25, 2026' }]);
  assert.deepEqual(b.slice(0, 2), [{ t: 'title', text: 'Dummy agreement' }, { t: 'p', text: 'Version 2' }]);
  assert.deepEqual(b.find((x) => x.t === 'table'), { t: 'table', head: ['Item', 'Value'], rows: [['Holdco a', 'A'], ['Holdco b', 'B'], ['Amount', '1']], kv: true });
  assert.equal(b.at(-1)!.t, 'signatures');
  assert.equal(signedCopyPath('d', 'v'), 'company-documents/d/v-signed.pdf');
});
