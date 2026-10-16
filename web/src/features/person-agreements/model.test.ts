import { test } from 'node:test';
import assert from 'node:assert/strict';
import { blanksIn, investmentMarkdown, investmentSummary, investorFields, staffFields, staffMarkdown, staffSummary, type InvestorFacts, type StaffFacts } from './model.ts';

// Agreements generated from the records (migration 0049): every blank of the source document is filled, the values
// land in Schedule A, and the signature lines say the signature is given electronically.
const company = { legal_name: 'Example Holdings Inc.', brand: 'CarmaCars', address: '1 Main Street, Toronto', email: 'contact@example.test', phone: '647-555-0100', signing_officer_name: 'Sam Officer', signing_officer_title: 'President' };
const investor: InvestorFacts = {
  investor: { id: 'i1', legal_name: 'Dana Wright', investor_type: 'individual', address: '9 King Street West, Toronto', email: 'dana@example.test', phone: '416-555-0177', tax_resident_canada: true, tax_country: null, has_portal: true },
  agreement_number: 'IA-101', investments: [], company
};
const values = { invested: '$25,000.00', yearly: '30%', investment_date: 'November 1, 2026', lockup_end: 'May 1, 2027' };

test('the investment agreement: no blank left, Schedule A filled, the chosen exemption initialled', () => {
  const md = investmentMarkdown(investor, values, { category: 'accredited_investor', paragraph: '(j)' });
  assert.equal(blanksIn(md), 0);
  assert.match(md, /\| Invested Amount \(minimum \$20,000\) \| \$25,000\.00 \|/);
  assert.match(md, /\| Yearly Percentage \| 30% per year \|/);
  assert.match(md, /\| Investor's full legal name and type[^|]*\| Dana Wright \(individual\) \|/);
  assert.match(md, /Paragraph of the definition: \(j\)/);
  assert.match(md, /\*\*Offering memorandum exemption[^\n]*\| not chosen \|/);
  assert.match(md, /Signature: given electronically \(see the signature record\) {2}Name: Dana Wright/);
  assert.doesNotMatch(md, /Canada Inc|[—–]/);
});

test('the investment agreement: the fields the Admin confirms are required, and the summary repeats them', () => {
  const f = investorFields(investor, { category: 'offering_memorandum_eligible', paragraph: '' });
  assert.deepEqual(f.filter((x) => x.required).map((x) => x.key), ['invested', 'yearly', 'investment_date', 'lockup_end']);
  assert.deepEqual(investmentSummary(investor, values).map((r) => r.value).slice(2), ['$25,000.00', '30%', 'November 1, 2026', 'May 1, 2027']);
  const md = investmentMarkdown(investor, values, { category: 'offering_memorandum_eligible', paragraph: '' });
  assert.match(md, /\*\*Accredited investor\*\*[^\n]*\| not chosen \|/);
  assert.match(md, /Exemption relied on: offering memorandum, eligible investor\./);
});

const staff = (type: 'va' | 'field'): StaffFacts => ({
  staff: { user_id: 'u1', full_name: 'Maya Chen', email: 'maya@example.test', phone: '+63 900 555 0100', staff_type: type, va_function: type === 'va' ? 'finance' : null, field_function: type === 'field' ? 'driver' : null,
    started_on: '2026-11-02', referral_code: type === 'field' ? 'MAYA25' : null, single_limit_cents: 25000, dual_approval_threshold_cents: 100000, has_signed: false },
  defaults: { country: 'Philippines', currency: 'USD', rate: '6.00', coverage: 'Monday to Friday, 9:00 to 17:00', hours_per_week: '40', platform: 'OnlineJobs.ph', pay_timing: 'every two weeks', trial_days: '30',
    wage: '20', vehicle_types: 'Cars and SUVs', pay_dates: 'every two weeks', licence_years: '3' },
  company
});
const fill = (f: StaffFacts, extra: Record<string, string> = {}) => ({ ...Object.fromEntries(staffFields(f).map((x) => [x.key, x.value])), ...extra });

test('the VA agreement: filled from the profile and the settings, the finance limits from the profile', () => {
  const f = staff('va');
  const md = staffMarkdown(f, fill(f));
  assert.equal(blanksIn(md), 0);
  assert.match(md, /\| Contractor \| Maya Chen \(legal name\), Philippines \(country\), maya@example\.test \(email\) \|/);
  assert.match(md, /\| Role \| Finance and Billing Coordinator \|/);
  assert.match(md, /\| Rate \| 6\.00 an hour, in USD \|/);
  assert.match(md, /\| Single Limit \(finance role\) \| \$250 per payment \|/);
  assert.match(md, /\| Start Date \| November 2, 2026 \|/);
  assert.equal(staffSummary(f, fill(f))[0]!.fix, null);
});

test('the field agreement: the address and licence the Admin adds, the referral code from the profile', () => {
  const f = staff('field');
  assert.deepEqual(staffFields(f).filter((x) => !x.value).map((x) => x.key), ['address', 'licence']);
  const md = staffMarkdown(f, fill(f, { address: '12 Queen Street, Toronto', licence: 'C1234-56789-01234' }));
  assert.equal(blanksIn(md), 0);
  assert.match(md, /\| Driver's licence \| Ontario Class G, number C1234-56789-01234 \|/);
  assert.match(md, /\| Referral code \| MAYA25 \|/);
  assert.match(md, /\| Hourly Wage \| \$20 an hour \|/);
  assert.match(md, /Name: Maya Chen\. Signature: given electronically/);
});
