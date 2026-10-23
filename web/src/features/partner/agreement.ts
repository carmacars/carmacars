// The partner agreement (migration 0046), the text approved in the legal review of October 16, 2026 (sections 3 to 11
// replaced, no draft banner): a short, plain-language agreement between CarmaCars and a partner rental company whose
// cars CarmaCars rents out on commission. A partner paid on its own rate sheet (0093's partner_rate basis, 01 Motors)
// gets sections 1, 3 and 4 on that basis and its sheet rates in the table (0105). Change it here, bump PARTNER_AGREEMENT_VERSION, and partners sign the new
// version. Filled from the partner record (app.partner_agreement_facts) and signed in the owner portal or on paper.
import { markdown, type Block, type SignatureRow } from '@/features/agreement/model';

export const PARTNER_AGREEMENT_VERSION = 'partner-v3-2026-10-22';
export const PARTNER_AGREEMENT_TITLE = 'Partner agreement';

export interface PartnerFacts {
  owner_id: string; partner_id: string; partner_number: string;
  partner: { business_name: string; legal_name: string; signer_name: string; signer_title: string | null; address: string; email: string | null; phone: string | null; hst_number: string | null };
  commission_bps: number;
  // 0105: how the partner is paid (0093) and, on the partner_rate basis, the markup; absent before 0105 means renter_price
  payout_basis?: 'renter_price' | 'partner_rate';
  markup_bps?: number;
  insurance: { company: string | null; policy: string | null; expiry: string | null };
  payout_day: number;
  cars: Array<{ name: string; plate: string | null; vin: string | null; commission_bps: number; markup_bps?: number;
    sheet?: { base_cents: number; multi_day_cents: number; long_term_cents: number } | null }>;
  company: { brand: string; legal_name: string; address: string; phone: string; email: string };
}

// The text. {{tokens}} are filled from the facts.
export const PARTNER_AGREEMENT_MD = `This agreement is between **{{company}}** ("CarmaCars"), and **{{partner}}** ("the Partner"), partner number {{partner_number}}.

## 1. What this agreement is for

The Partner owns or controls rental cars. CarmaCars lists some of them on its website and its other channels, takes the bookings, deals with the renters and collects the money. CarmaCars keeps a commission and pays the Partner the rest.

## 2. The cars

The cars covered are the ones in the table below, and any car the Partner and CarmaCars later add in writing (an email is enough). Either party may take a car out of the program with 14 days' notice, but not while it has a confirmed booking.

## 3. Bookings and renters

CarmaCars acts as the Partner's agent to list the cars, take bookings, contract with renters, collect payments and deposits, and handle extensions and cancellations under CarmaCars' rental terms. CarmaCars sets renter prices unless the parties agree otherwise in writing. The Partner keeps each car available for its confirmed bookings and tells CarmaCars at once if a car cannot be rented.

## 4. Money

CarmaCars keeps a commission of {{commission}} of each car's rental revenue (the rental charge and the kilometre overage) unless the table gives another rate for a car. Fees CarmaCars charges renters for its own services (delivery, administration fees and the Protection Plan) are CarmaCars' own. CarmaCars sends the Partner a statement for each month and pays the Partner's share by bank transfer or e-Transfer on or about the {{payout_day}} of the next month. Refunds, chargebacks, uncollected damage and deposit shortfalls on a car come off that car's next statements. CarmaCars charges HST on its commission; the Partner remits HST on the rental revenue as the supplier to the renter.

## 5. Insurance and condition

The Partner keeps each car insured at its own cost under a policy that permits rental to the public through CarmaCars as agent, and has told its insurer. Policy on file: {{insurance}}. The Partner sends proof of insurance when asked and at renewal, and tells CarmaCars at once if the insurance lapses or changes. The Partner warrants that no lender, lessor or other person's consent is needed to rent the cars, or that it has been obtained. The Partner keeps each car safe, legal, clean and maintained, with valid plates and permit.

## 6. Damage and claims

CarmaCars pursues the renter under its rental terms and passes recovered amounts to the Partner, less the commission on any recovered rental charges. Claims are handled under the Partner's policy. CarmaCars is not liable for damage, loss or injury it did not cause.

## 7. Tolls and tickets

Within 2 business days of a request, CarmaCars gives the Partner the renter's name, licence details and rental dates so the Partner can transfer a toll, ticket or offence notice. Tolls and tickets during a rental are the renter's; when the Partner had the car, the Partner's.

## 8. Information and non-circumvention

CarmaCars shares with the Partner only the renter information needed for a car. Each party keeps the other's business information confidential. During this agreement and for 12 months after it ends, the Partner will not rent directly to a renter CarmaCars introduced.

## 9. Liability

Neither party is liable to the other for lost profits or indirect loss. Each party's liability to the other is limited to the commissions paid or payable under this agreement in the 12 months before the claim, except for a breach of section 5 or 8 or an indemnity. The Partner indemnifies CarmaCars against claims arising from a car's condition, the Partner's insurance or a missing consent. CarmaCars indemnifies the Partner against claims arising from CarmaCars' handling of renters and payments.

## 10. Ending the agreement

Either party may end this agreement with 30 days' written notice. CarmaCars may end it at once if a car's insurance lapses or the Partner breaches section 5. Bookings confirmed before the end are completed, and CarmaCars pays what is owed on the final statement.

## 11. General

This is the whole agreement about the cars below. A change must be in writing and agreed by both parties. The laws of Ontario apply. A dispute goes first to mediation in Toronto; failing that, to the Ontario courts. Signing electronically or on paper has the same effect.`;

// On the partner_rate basis: the partner's own rates, the renter's price above them, and the partner's share of them.
const PARTNER_RATE_SECTIONS: Record<string, string> = {
  '## 1. What this agreement is for': `## 1. What this agreement is for

The Partner owns or controls rental cars and has given CarmaCars a rate sheet for them. CarmaCars lists the cars on its website and its other channels, takes the bookings, deals with the renters and collects the money. CarmaCars pays the Partner its share of the Partner's sheet rates, as set out in section 4.`,
  '## 3. Bookings and renters': `## 3. Bookings and renters

CarmaCars acts as the Partner's agent to list the cars, take bookings, contract with renters, collect payments and deposits, and handle extensions and cancellations under CarmaCars' rental terms. The renter's price is set as in section 4 unless the parties agree otherwise in writing. The Partner keeps each car available for its confirmed bookings and tells CarmaCars at once if a car cannot be rented.`,
  '## 4. Money': `## 4. Money

**The Partner's rates.** The Partner's rates are the daily rates on its rate sheet, shown for each car in the table below (1 to 2 days, 3 or more days, 7 or more days). They are guideline rates. They may be adjusted by written agreement of the parties (an email is enough) or in CarmaCars' Admin, where CarmaCars keeps each car's current rates.

**What the renter pays.** The renter pays the Partner's sheet rate plus a CarmaCars markup of {{markup}} of the sheet rate, unless the table gives another markup for a car, rounded to the nearest dollar.

**What CarmaCars keeps.** CarmaCars keeps the markup plus {{commission}} of the sheet rate, unless the table gives another rate for a car. Fees CarmaCars charges renters for its own services (delivery, administration fees and the Protection Plan) are CarmaCars' own.

**What the Partner is paid.** For each completed rental, CarmaCars pays the Partner {{partner_share}} of its sheet rate for the rental's days, unless the table gives another rate for a car. Kilometre overage charged to the renter is shared in the same proportions. The Partner's payment is net of the deductions below.

**Statements and deductions.** CarmaCars sends the Partner a statement for each month showing each rental at the sheet rate, CarmaCars' share and the Partner's payment, and pays the Partner by bank transfer or e-Transfer on or about the {{payout_day}} of the next month. Refunds, chargebacks, uncollected damage and deposit shortfalls on a car come off that car's next statements; a refund lowers the Partner's payment in proportion to the part of the rental refunded. CarmaCars charges HST on its share; the Partner remits HST on its payment as the supplier to the renter.`
};

const ordinal = (n: number) => `${n}${n % 100 >= 11 && n % 100 <= 13 ? 'th' : ({ 1: 'st', 2: 'nd', 3: 'rd' } as Record<number, string>)[n % 10] ?? 'th'}`;
const money = (cents: number) => `$${(cents / 100).toLocaleString('en-CA', { minimumFractionDigits: cents % 100 ? 2 : 0, maximumFractionDigits: 2 })}`;
// The agreement on the partner_rate basis: sections 1, 3 and 4 replaced, the rest as approved.
export function partnerRateText(): string {
  return PARTNER_AGREEMENT_MD.split(/\n(?=## )/).map((sec) => {
    const head = sec.split('\n')[0] ?? '';
    return PARTNER_RATE_SECTIONS[head] ?? sec;
  }).join('\n');
}
const pct = (bps: number) => `${(bps / 100).toFixed(bps % 100 ? 2 : 0)}%`;

export function partnerAgreementBlocks(f: PartnerFacts, sig?: { partner?: SignatureRow; carmacars?: SignatureRow }): Block[] {
  const company = f.company.legal_name || f.company.brand;
  const insurance = f.insurance.company ? `${f.insurance.company}${f.insurance.policy ? `, policy ${f.insurance.policy}` : ''}${f.insurance.expiry ? `, expiring ${f.insurance.expiry}` : ''}` : 'none yet, to be provided before the first rental';
  const rate = f.payout_basis === 'partner_rate';
  const markup = f.markup_bps ?? 1000;
  const text = rate ? partnerRateText() : PARTNER_AGREEMENT_MD;
  const body = markdown(text.replace(/^## /gm, '### '), { company, brand: f.company.brand, partner: f.partner.legal_name || f.partner.business_name, partner_number: f.partner_number,
    commission: pct(f.commission_bps), markup: pct(markup), partner_share: pct(10000 - f.commission_bps), payout_day: ordinal(f.payout_day), insurance });
  const sheet = (c: PartnerFacts['cars'][number]) => (c.sheet ? `${money(c.sheet.base_cents)} / ${money(c.sheet.multi_day_cents)} / ${money(c.sheet.long_term_cents)}` : 'To be agreed in writing');
  // plate and VIN columns only once a car has one (a price sheet has neither; they are added before the first handover)
  const ids = f.cars.some((c) => c.plate || c.vin);
  const idCols = (c: PartnerFacts['cars'][number]) => (ids ? [c.plate ?? '', c.vin ?? ''] : []);
  const cars: Block = rate
    ? { t: 'table', head: ['Car', ...(ids ? ['Plate', 'VIN'] : []), 'Sheet rate a day (1-2 / 3+ / 7+ days)', 'Markup', 'CarmaCars share of sheet'],
        rows: f.cars.length ? f.cars.map((c) => [c.name, ...idCols(c), sheet(c), pct(c.markup_bps ?? markup), pct(c.commission_bps)]) : [['Cars added later in writing', 'To be agreed in writing', pct(markup), pct(f.commission_bps)]] }
    : { t: 'table', head: ['Car', 'Plate', 'VIN', 'Commission'], rows: f.cars.length ? f.cars.map((c) => [c.name, c.plate ?? '', c.vin ?? '', pct(c.commission_bps)]) : [['Cars added later in writing', '', '', pct(f.commission_bps)]] };
  const blank = (party: string, name: string): SignatureRow => ({ party, name, signature: '', when: '' });
  return [
    { t: 'title', text: PARTNER_AGREEMENT_TITLE },
    ...body,
    { t: 'h2', text: 'The cars' },
    cars,
    { t: 'table', kv: true, head: ['', ''], rows: [['Partner', `${f.partner.legal_name || f.partner.business_name}${f.partner.address ? `, ${f.partner.address}` : ''}`], ['Contact', [f.partner.email, f.partner.phone].filter(Boolean).join(', ')], ['CarmaCars', `${company}, ${f.company.address}`]] },
    { t: 'signatures', rows: [sig?.partner ?? blank(`Partner${f.partner.signer_title ? ` (${f.partner.signer_title})` : ''}`, f.partner.signer_name), sig?.carmacars ?? blank('CarmaCars', company)] }
  ];
}
