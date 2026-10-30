// Every signature through the signing session (migration 0193): the key terms the database asks each document's signer to
// initial (app.esign_doc_initials) all have their wording on the page, the consents of a document signer name no card,
// and the certificate names each term initialled in words.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DOC_CONSENTS, DOC_TERMS, DOC_TERM_LABELS, formCTerms } from './terms.ts';
import { certificateLines, type Certificate } from './certificate.ts';

const migration = readFileSync(new URL('../../../../supabase/migrations/0193_esign_everywhere.sql', import.meta.url), 'utf8');
const fn = /create or replace function app\.esign_doc_initials[\s\S]*?\$\$;/.exec(migration)![0];
const codes = [...new Set([...fn.matchAll(/array\[([^\]]+)\]/g)].flatMap((m) => [...m[1]!.matchAll(/'([a-z_]+)'/g)].map((x) => x[1]!)))];

test('every key term the database asks to initial has its words on the page and in the certificate', () => {
  assert.ok(codes.length >= 14, `codes read from the migration: ${codes.join(', ')}`);
  const formC = formCTerms(['I read the warning.', 'I may get legal advice.', 'I bear the consequences.']).map((t) => t.code);
  for (const c of codes) {
    assert.ok(DOC_TERMS.some((t) => t.code === c) || formC.includes(c), `no wording for ${c}`);
    assert.ok(DOC_TERM_LABELS[c], `no certificate label for ${c}`);
  }
});

test('the consents of a document signer: to sign and to get records electronically, no card', () => {
  assert.deepEqual(Object.keys(DOC_CONSENTS).sort(), ['erecords', 'esign']);
  assert.match(migration, /array\['esign', 'erecords'\]/);
  for (const t of [...Object.values(DOC_CONSENTS), ...DOC_TERMS.map((x) => `${x.title} ${x.text}`)]) {
    assert.doesNotMatch(t, /[–—]/, 'no long dashes');
    assert.doesNotMatch(t, /Carma Cars|Carmacars\b/, 'the brand is CarmaCars');
  }
});

test('the certificate of an owner document names the confirmations initialled', () => {
  const c: Certificate = {
    document: 'Enrollment Agreement EA-1001', hashes: [{ label: 'Enrollment Agreement EA-1001', sha256: 'a'.repeat(64) }], verifyUrl: 'https://carmacars.ca/verify', at: '2026-10-27T15:00:00Z',
    signers: [{ signer_name: 'Sample Owner', signer_role: 'owner', method: 'remote', otp_channel: 'email', otp_to: 's***@example.test', otp_verified_at: '2026-10-27T14:58:00Z',
      viewed_at: '2026-10-27T14:58:30Z', initials: { own_insurance: { at: '2026-10-27T14:59:00Z' }, fees_no_income: { at: '2026-10-27T14:59:10Z' }, tracker_downtime: { at: '2026-10-27T14:59:20Z' } },
      consents: { esign: { at: '2026-10-27T14:59:30Z' }, erecords: { at: '2026-10-27T14:59:31Z' } }, signature_method: 'drawn', signed_at: '2026-10-27T15:00:00Z',
      events: [{ at: '2026-10-27T14:59:00Z', kind: 'initial', detail: { code: 'own_insurance' } }] }]
  };
  const text = certificateLines(c).map((l) => l.text).join('\n');
  assert.match(text, /Initialled: your own insurance \(.+\); fees every month \(.+\); the tracker \(.+\)/);
  assert.match(text, /Initialled your own insurance/);
  assert.match(text, /Consented: to sign electronically .*; to receive records electronically/);
  assert.match(text, /Identity: one-time code by email to s\*\*\*@example\.test/);
});
