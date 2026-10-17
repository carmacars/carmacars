import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ENROLLMENT_ARTICLES, ENROLLMENT_SCHEDULE_B } from './owner-agreement/source.generated.ts';
import { FORM_D } from './owner-agreement/forms.generated.ts';
import { oneTimeText, mandateText } from './owner/mandate.ts';
import type { DebitTerms } from './owner/types.ts';

// The owner's legal review ("CarmaCars: legal text changes before launch", October 16, 2026): every approved string,
// word for word, where the web app carries it; and the string search of the review's section 6.
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const read = (p: string) => readFileSync(path.join(ROOT, p), 'utf8');
// the partner agreement's text, read from its module (which imports the app's renderer through the @ alias)
const PARTNER_AGREEMENT_MD = /export const PARTNER_AGREEMENT_MD = `([\s\S]*?)`;/.exec(read('web/src/features/partner/agreement.ts'))![1]!;

test('partner agreement: no draft banner; sections 3 to 11 as approved (20% and the 10th from the settings)', () => {
  const md = PARTNER_AGREEMENT_MD.replace('{{commission}}', '20%').replace('{{payout_day}}', '10th').replace('{{insurance}}', '[insurer], policy [policy number], expiring [expiry date]');
  assert.doesNotMatch(md, /Draft for lawyer review|Not yet approved/);
  const approved: Array<[string, string]> = [
    ['3. Bookings and renters', "CarmaCars acts as the Partner's agent to list the cars, take bookings, contract with renters, collect payments and deposits, and handle extensions and cancellations under CarmaCars' rental terms. CarmaCars sets renter prices unless the parties agree otherwise in writing. The Partner keeps each car available for its confirmed bookings and tells CarmaCars at once if a car cannot be rented."],
    ['4. Money', "CarmaCars keeps a commission of 20% of each car's rental revenue (the rental charge and the kilometre overage) unless the table gives another rate for a car. Fees CarmaCars charges renters for its own services (delivery, administration fees and the Protection Plan) are CarmaCars' own. CarmaCars sends the Partner a statement for each month and pays the Partner's share by bank transfer or e-Transfer on or about the 10th of the next month. Refunds, chargebacks, uncollected damage and deposit shortfalls on a car come off that car's next statements. CarmaCars charges HST on its commission; the Partner remits HST on the rental revenue as the supplier to the renter."],
    ['5. Insurance and condition', "The Partner keeps each car insured at its own cost under a policy that permits rental to the public through CarmaCars as agent, and has told its insurer. Policy on file: [insurer], policy [policy number], expiring [expiry date]. The Partner sends proof of insurance when asked and at renewal, and tells CarmaCars at once if the insurance lapses or changes. The Partner warrants that no lender, lessor or other person's consent is needed to rent the cars, or that it has been obtained. The Partner keeps each car safe, legal, clean and maintained, with valid plates and permit."],
    ['6. Damage and claims', 'CarmaCars pursues the renter under its rental terms and passes recovered amounts to the Partner, less the commission on any recovered rental charges. Claims are handled under the Partner\'s policy. CarmaCars is not liable for damage, loss or injury it did not cause.'],
    ['7. Tolls and tickets', "Within 2 business days of a request, CarmaCars gives the Partner the renter's name, licence details and rental dates so the Partner can transfer a toll, ticket or offence notice. Tolls and tickets during a rental are the renter's; when the Partner had the car, the Partner's."],
    ['8. Information and non-circumvention', "CarmaCars shares with the Partner only the renter information needed for a car. Each party keeps the other's business information confidential. During this agreement and for 12 months after it ends, the Partner will not rent directly to a renter CarmaCars introduced."],
    ['9. Liability', "Neither party is liable to the other for lost profits or indirect loss. Each party's liability to the other is limited to the commissions paid or payable under this agreement in the 12 months before the claim, except for a breach of section 5 or 8 or an indemnity. The Partner indemnifies CarmaCars against claims arising from a car's condition, the Partner's insurance or a missing consent. CarmaCars indemnifies the Partner against claims arising from CarmaCars' handling of renters and payments."],
    ['10. Ending the agreement', "Either party may end this agreement with 30 days' written notice. CarmaCars may end it at once if a car's insurance lapses or the Partner breaches section 5. Bookings confirmed before the end are completed, and CarmaCars pays what is owed on the final statement."],
    ['11. General', 'This is the whole agreement about the cars below. A change must be in writing and agreed by both parties. The laws of Ontario apply. A dispute goes first to mediation in Toronto; failing that, to the Ontario courts. Signing electronically or on paper has the same effect.']
  ];
  for (const [h, body] of approved) assert.ok(md.includes(`## ${h}\n\n${body}`), `section ${h}`);
  assert.ok(md.includes('## 1. What this agreement is for') && md.includes('## 2.'), 'sections 1 and 2 kept');
});

test('Enrollment Agreement: 4.4, 4.5 Set-off, 4.6 Arrears and the Retry Date, as approved', () => {
  assert.ok(ENROLLMENT_ARTICLES.includes("4.4 If an automatic pre-authorized debit of an invoice is returned for insufficient funds, CarmaCars adds the Late Fee to that invoice once and may re-present the debit once, for the original amount, within 30 days. The Late Fee is collected with the Owner's next debit or deducted from the Owner's next payout."));
  assert.ok(ENROLLMENT_ARTICLES.includes('CarmaCars may deduct any amount the Owner owes under this Agreement from any payout due to the Owner for any Vehicle.'));
  assert.match(ENROLLMENT_ARTICLES, /4\.5 \*\*Set-off\.\*\* CarmaCars may deduct/);
  assert.ok(ENROLLMENT_ARTICLES.includes("If an invoice remains unpaid 30 days after a failed re-presentment, CarmaCars may, on written notice, remove the Vehicle from the program and transfer its registration back to the Owner at the Owner's cost. Return of the Vehicle is not withheld for unpaid fees."));
  assert.match(ENROLLMENT_ARTICLES, /4\.6 \*\*Arrears\.\*\* If an invoice/);
  assert.ok(ENROLLMENT_SCHEDULE_B.includes('| Retry Date | on or after the 18th, within 30 days of the return |'));
  assert.doesNotMatch(ENROLLMENT_ARTICLES, /If a charge fails, CarmaCars adds the Late Fee/);
});

test('Form D: the Lien bullet, as approved', () => {
  assert.ok(FORM_D.includes('register a lien in my favour, and discharge it only once the registration of that Vehicle is back in my name or in the name of a person I named in writing.'));
});

const rule = 'If your bank returns the automatic debit of an invoice for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.';
const terms: DebitTerms = {
  debit_day: 15, retry_day: 18, notice_days: 10, max_attempts: 2, retry_gap_days: 3, late_fee_cents: 5000, late_fee: '$50.00',
  debit_day_text: '15th', retry_day_text: '18th', payout_day_text: '10th', interval_description: 'x', late_fee_rule: rule, own_debit_rule: 'x',
  payee: { name: '18122211 Canada Inc., operating as CarmaCars', address: '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2', phone: '647-555-0100', email: 'billing@carmacars.ca' }
};

test('the invoice page: the one-time box (required, with the waiver) and the recurring agreement with the payee and the rule', () => {
  assert.equal(oneTimeText(terms, '$536.75', 'INV-1042'), 'I authorize 18122211 Canada Inc., operating as CarmaCars, to debit $536.75 for invoice INV-1042 from the bank account I give now. I waive pre-notification and any waiting period for this one-time debit.');
  const recurring = mandateText('personal', terms);
  assert.match(recurring[0]!, /^You authorize 18122211 Canada Inc\., operating as CarmaCars, to debit/);
  assert.equal(recurring[1], rule);
  const form = read('web/src/features/owner/OwnerPayForm.tsx');
  assert.match(form, /useState\(true\)/, 'the recurring box is ticked to start with');
  assert.match(form, /One-time debit \(required\)/);
  assert.match(form, /Untick to pay this invoice only/);
});

test('signatures: the owner statement, the amendment section 4 and refund line, the witness statement, the rental added by staff', () => {
  assert.match(read('web/src/features/owner-agreement/model.ts'), /OWNER_SIGN_STATEMENT = 'I have read these documents and I sign them electronically\.'/);
  const am = read('web/src/features/agreement/amendment.ts');
  assert.ok(am.includes("'CarmaCars signs this amendment electronically at the moment the Renter signs it.'"));
  assert.ok(am.includes('(HST included) to ${f.card_on_file?.last4 ? `the card ending ${f.card_on_file.last4}` : \'the card on this booking\'} within 10 business days after this amendment is signed.'));
  assert.match(am, /CarmaCars refunds \*\*\$\{money/);
  assert.ok(read('web/src/features/owner-agreement/witnessed.ts').includes('`I witnessed ${owner} sign in my presence.`'));
  assert.ok(read('supabase/migrations/0053_legal_review.sql').includes("'Read and sign your rental agreement; your card is charged when you sign.'"));
  assert.match(read('web/src/app/account/bookings/[number]/sign/page.tsx'), /'Accept and sign'/);
});

test('emails: the failed debit (7.4), the void notice (6.2), the returned debit and the confirmation carry the approved lines', () => {
  const failed = read('emails/src/emails/owner_payment_failed.mjs');
  assert.ok(failed.includes("preheader: 'A {{late_fee}} late fee is added to your next debit. We retry {{amount}} on or after {{retry_date}}.'"));
  assert.ok(failed.includes("We retry {{amount}} on or after {{retry_date}}. The {{late_fee}} late fee is collected with your next debit."));
  assert.ok(failed.includes('If that fails too, this vehicle goes into arrears.'));
  assert.doesNotMatch(failed, /deducted from this car's revenue at the next payout/);
  assert.ok(read('emails/src/emails/owner_payment_reversed.mjs').includes('No late fee applies. If this invoice has an automatic debit scheduled, it is debited on {{debit_date}} for {{balance}}; otherwise pay it from the invoice page.'));
  const returned = read('emails/src/emails/owner_debit_returned.mjs');
  assert.ok(returned.includes('The debit of {{debit_date}} was returned: {{bank_reason}}'));
  assert.ok(returned.includes('Pay this invoice from its page or update your bank account under Banking. We will not debit this invoice again.'));
  const pad = read('emails/src/emails/owner_pad_confirmed.mjs');
  for (const k of ['{{agreement_1}}', '{{agreement_2}}', '{{agreement_3}}', '{{agreement_4}}', "button('Read the agreement'"]) assert.ok(pad.includes(k), k);
});

// Section 6, last test: a string search of the PAD, confirmation and Stripe fields for a bare "CarmaCars" payee, and of the
// renter-facing copy for "insurance" or "coverage" wording describing the Protection Plan.
function files(dir: string, out: string[] = []): string[] {
  for (const f of readdirSync(dir)) {
    const p = path.join(dir, f);
    if (f === 'node_modules' || f.startsWith('.')) continue;
    if (statSync(p).isDirectory()) files(p, out); else if (/\.(ts|tsx|mjs|json|md)$/.test(f) && !/\.test\.ts$/.test(f)) out.push(p);
  }
  return out;
}

test('string search: no bare "CarmaCars" payee in the PAD agreement, the confirmation or the Stripe fields', () => {
  const sql = read('supabase/migrations/0053_legal_review.sql');
  assert.ok(sql.includes("then s.company_legal_name || ', operating as ' || s.company_trade_name"), 'the payee name');
  assert.ok(sql.includes("format('%s o/a %s: fees on your %s invoices on the %s of each month, with notice %s days before.'"), 'the Stripe mandate description');
  assert.match(read('web/src/features/owner/mandate.ts'), /`I authorize \$\{t\.payee\.name\}/);
  assert.match(read('emails/src/emails/owner_pad_confirmed.mjs'), /\['Payee', '\{\{payee_name\}\}'\]/);
  for (const f of ['web/src/features/owner/mandate.ts', 'web/src/features/owner/OwnerPayForm.tsx', 'web/src/features/owner/DebitSetupForm.tsx', 'emails/src/emails/owner_pad_confirmed.mjs']) {
    assert.doesNotMatch(read(f), /(You authorize|I authorize|Payee[^\n]{0,8}) CarmaCars\b/, f);
  }
  assert.doesNotMatch(read('web/src/integrations/payments/stripe.ts'), /interval_description\]'\] = 'CarmaCars/);
});

test('string search: the renter Protection Plan is never called insurance or coverage, and the provider is never named', () => {
  const renterFacing = [...files(path.join(ROOT, 'web/src/app')), ...files(path.join(ROOT, 'web/src/features')), ...files(path.join(ROOT, 'emails/src/emails')),
    path.join(ROOT, 'web/scripts/content/site-content.json'), path.join(ROOT, 'docs/source/v2_rental.md'), path.join(ROOT, 'docs/source/website_terms_policies.md')];
  const bad = /(coverage|insurance) you (buy|add|get) with your booking|(coverage|insurance)[^.\n"]{0,30}(bought|sold|purchased|offered) (through|by|from) (CarmaCars|us)|(buy|purchase|add) (rental )?(coverage|insurance) (through|from) (CarmaCars|us|you)|Coverage Option 3|coverage sold through/i;
  const hits = renterFacing.flatMap((f) => readFileSync(f, 'utf8').split('\n').map((l, i) => [f, i + 1, l] as const)).filter(([, , l]) => bad.test(l));
  assert.deepEqual(hits.map(([f, n]) => `${path.relative(ROOT, f)}:${n}`), []);
  assert.match(read('web/src/features/booking/Estimate.tsx'), /case 'coverage_sold': return \{ k: 'Protection Plan' \}/);
  // the requirements page's third option (found by the review of October 16: it said "Coverage you buy with your booking")
  assert.match(read('web/src/app/requirements/page.tsx'), /<th scope="row">3\. Protection Plan<\/th><td>The \{s\.brand_name\} Protection Plan, added to your booking\./);
  assert.doesNotMatch(read('web/src/app/requirements/page.tsx'), /Coverage you buy/);
});
