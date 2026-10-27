// The owner's agreements before approval (migration 0181): the facts of a real owner (tests/fixtures/agreements/facts.json)
// made into what public.server_owner_agreement_preview_facts returns for a car still in intake (no schedule entry, no
// agreement yet: no fee, no Revenue Share, no number), rendered as the owner reads them on /owner/sign.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import type { Block } from '../agreement/model.ts';
import { documentBlocks, packetKeys, PENDING, PREVIEW_NOTICE, type OwnerAgreementFacts } from './model.ts';

const F = JSON.parse(readFileSync(new URL('../../../tests/fixtures/agreements/facts.json', import.meta.url), 'utf8')) as { owner: OwnerAgreementFacts };
const preview = (): OwnerAgreementFacts => {
  const f = structuredClone(F.owner);
  return { ...f, preview: true, pending_vehicles: f.schedules.length,
    agreements: (['enrollment', 'title_holding'] as const).map((kind) => ({ id: null, kind, agreement_number: null, status: 'preview', agreement_date: null, signature_request_id: null, document_sha256: null })),
    schedules: f.schedules.map((s) => ({ ...s, id: null, schedule_number: null, insurance_fee_cents: null, tracker_fee_cents: null, install_fee_cents: null, revenue_share_bps: null,
      enrollment_date: null, signed_at: null, signature_request_id: null, title_agreement_id: null, onboarding_status: 'intake', pending: true })) };
};
const text = (blocks: Block[]) => blocks.map((b) => ('text' in b ? b.text : 'rows' in b && b.t === 'table' ? b.rows.flat().join(' | ') : 'items' in b ? b.items.join(' ') : '')).join('\n');

test('before approval: both agreements, marked as a preview, the fees and the Revenue Share pending, no number made up', () => {
  const f = preview();
  assert.deepEqual(packetKeys(f), ['enrollment', 'title_holding']);
  for (const key of ['enrollment', 'title_holding'] as const) {
    const t = text(documentBlocks(f, key));
    assert.match(t, new RegExp(`PREVIEW, NOT FOR SIGNATURE\\. ${PREVIEW_NOTICE.replace(/[.:]/g, '\\$&')}`));
    assert.match(t, /Given when CarmaCars approves your terms/);
    assert.doesNotMatch(t, /\bnull\b|undefined|NaN/);
    assert.doesNotMatch(t, /[–—]/);
    assert.match(t, new RegExp(f.owner.legal_name));
  }
  const a = documentBlocks(f, 'enrollment');
  const schedA = a.filter((b): b is Extract<Block, { t: 'table' }> => b.t === 'table' && b.head[1]?.startsWith('Vehicle no.') === true);
  assert.equal(schedA.length, f.schedules.length);
  for (const s of schedA) {
    const row = (k: string) => s.rows.find((r) => r[0] === k)?.[1];
    assert.equal(row('Insurance Fee and Tracker Fee per month'), PENDING);
    assert.equal(row('Install Fee'), PENDING);
    assert.equal(row('Revenue Share'), PENDING);
    assert.doesNotMatch(s.rows.flat().join(' '), /\$\d/);
  }
});

test('approved terms are unchanged: no preview notice, the numbers as set', () => {
  const t = text(documentBlocks(F.owner, 'enrollment'));
  assert.doesNotMatch(t, /PREVIEW|Pending approval/);
  assert.match(t, /\$\d/);
});
