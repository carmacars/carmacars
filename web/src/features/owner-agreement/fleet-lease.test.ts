// The Fleet Supplier Lease Agreement (migration 0640) and the Referral Override Agreement: every number from the
// records (nothing preset), the company by its legal name only, no open lawyer note in the text, and the standard
// Vehicle Schedule's new rows (the onboarding costs, a Shareholder Vehicle). Facts from tests/fixtures/agreements/facts.json.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import type { Block } from '../agreement/model.ts';
import { confirmationsOf, documentBlocks, FLEET_TEMPLATE_VERSION, OWNER_TEMPLATE_VERSION, templateVersionOf, titleOf, type OwnerAgreementFacts } from './model.ts';
import { FLEET_ARTICLES, FLEET_LAWYER_NOTES } from './fleet-lease.generated.ts';
import { ENROLLMENT_ARTICLES, ENROLLMENT_LAWYER_NOTES } from './source.generated.ts';
import { referralAgreementBlocks, type ReferralFacts } from '../referral-agreement/agreement.ts';
import { REFERRAL_ARTICLES, REFERRAL_LAWYER_NOTES } from '../referral-agreement/source.generated.ts';

const F = JSON.parse(readFileSync(new URL('../../../tests/fixtures/agreements/facts.json', import.meta.url), 'utf8')) as { owner: OwnerAgreementFacts };
const text = (blocks: Block[]) => blocks.map((b) => ('text' in b ? b.text : 'rows' in b && b.t === 'table' ? b.rows.flat().join(' | ') : 'items' in b ? b.items.join(' ') : '')).join('\n');
const fleet = (): OwnerAgreementFacts => {
  const f = structuredClone(F.owner);
  return { ...f, pay_model: 'fleet_lease', company: { ...f.company, legal_name: '18122211 Canada Inc.' },
    agreements: f.agreements.map((a) => (a.kind === 'enrollment' ? { ...a, status: 'draft', variant: 'fleet_lease' as const } : a)),
    fleet_lease: { regular_cents: 61100, troubled_cents: 21300, claim_profit_bps: 2200, early_writeoff_bps: 9000, writeoff_months: 15, later_writeoff_bps: 4500, notice_days: 75,
      effective_from: '2026-11-01', awaiting_signature: false, upkeep: [{ cost_type: 'engine', label: 'Engine', party: 'supplier' }, { cost_type: 'tires', label: 'Tires', party: 'company' }] },
    schedules: f.schedules.map((s, i) => ({ ...s, lease_tier: i ? 'troubled' : 'regular', monthly_cents: i ? 21300 : 61100, delivered_on: '2026-11-05' })) };
};

test('the fleet lease agreement: its own title and version, every number from the supplier\'s terms, the legal name only', () => {
  const f = fleet();
  const t = text(documentBlocks(f, 'enrollment'));
  assert.equal(titleOf(f, 'enrollment'), 'Fleet Supplier Lease Agreement');
  assert.equal(templateVersionOf(f, 'enrollment'), FLEET_TEMPLATE_VERSION);
  assert.equal(templateVersionOf(f, 'title_holding'), OWNER_TEMPLATE_VERSION);
  for (const want of ['$611 a month per Vehicle', '$213 a month per Vehicle', 'Claim Profit Share | 22%', '90% of the balance after any Lender', '15 In-Service Months', '45% of the balance', '75 days', 'Engine | The Supplier', 'Tires | The Company', 'Tier | Regular', 'Lease Rate | $611 a month'])
    assert.ok(t.includes(want), want);
  assert.match(t, /Company\*\*: 18122211 Canada Inc\./);
  assert.match(t, /first payment for a Vehicle is made on the first Payout Date that falls at least one full month after its Delivery Date/);
  assert.match(t, /does not change for as long as the Vehicle is leased/);
  assert.match(t, /Fees the Supplier pays \| None/);
  assert.match(t, /pays the Company no fee of any kind: no insurance fee, management fee, tracker fee, install fee or first and last month/);
  assert.doesNotMatch(t, /operating as|\bnull\b|undefined|NaN|\[LAWYER|[–—]/);
  assert.match(confirmationsOf(f).map((c) => c.text).join(' '), /in arrears on the 10th/);
});

test('no deal amount is written into a template', () => {
  for (const s of [FLEET_ARTICLES, REFERRAL_ARTICLES]) assert.doesNotMatch(s, /\$\d|\d+ ?%/);
});

test('the lawyer\'s open points are listed, not printed', () => {
  assert.ok(FLEET_LAWYER_NOTES.length === 0 && REFERRAL_LAWYER_NOTES.length >= 2 && ENROLLMENT_LAWYER_NOTES.length === 2);
  for (const s of [FLEET_ARTICLES, REFERRAL_ARTICLES, ENROLLMENT_ARTICLES]) assert.doesNotMatch(s, /LAWYER/);
});

test('the standard Vehicle Schedule: the onboarding costs and how they are paid; a Shareholder Vehicle pays no fees', () => {
  const f = structuredClone(F.owner);
  f.schedules = f.schedules.map((s, i) => ({ ...s, one_off_fees: [{ description: 'Registration', amount_cents: 5900 }], onboarding_by_payout: i === 0, shareholder: i === 1, shareholder_share_bps: i === 1 ? 1000 : null }));
  const t = text(documentBlocks(f, 'enrollment'));
  assert.match(t, /Onboarding costs CarmaCars paid \(4\.2\) \| Registration \$59/);
  assert.match(t, /Deducted from the Owner's payouts until paid; later Fees by pre-authorized debit/);
  if (f.schedules.length > 1) assert.match(t, /Shareholder Vehicle \(4\.9\) \| Yes: no Insurance Fee/);
  assert.match(t, /4\.9 \*\*Shareholder Vehicle\.\*\*/);
});

test('the Referral Override Agreement: the rate, the referred owner and the view from the link', () => {
  const r: ReferralFacts = { owner_id: 'o', link_id: 'l', referrer: { legal_name: 'Example Referrer', owner_type: 'individual', signer_name: 'Example Referrer', signer_title: null, email: 'ref@example.test', hst_number: null, address: '' },
    referred: { legal_name: 'Example Owner' }, share_bps: 1250, sees_cars: true, effective_from: '2026-11-01', agreement_status: 'not_sent', payout_day: 10,
    company: { brand: 'CarmaCars', legal_name: '18122211 Canada Inc.', address: '', phone: '', email: '' } };
  const t = text(referralAgreementBlocks(r));
  for (const want of ['Override Rate | 12.5 points', 'Referred Owner | Example Owner', 'Yes, read only', 'The 10th of each month', 'November 1, 2026']) assert.ok(t.includes(want), want);
  assert.match(t, /never reduces the Referred Owner's payout/);
  assert.doesNotMatch(t, /operating as|\bnull\b|undefined|NaN|LAWYER/);
});
