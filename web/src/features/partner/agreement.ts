// The partner agreement (migration 0046): a short, plain-language agreement between CarmaCars and a partner rental
// company whose cars CarmaCars rents out on commission. DRAFT FOR LAWYER REVIEW (the lawyer's copy is kept
// outside this repository); change it here, bump PARTNER_AGREEMENT_VERSION, and partners sign the new version.
// Filled from the partner record (app.partner_agreement_facts) and signed in the owner portal or on paper.
import { markdown, type Block, type SignatureRow } from '@/features/agreement/model';

export const PARTNER_AGREEMENT_VERSION = 'partner-draft-2026-10-16';
export const PARTNER_AGREEMENT_TITLE = 'Partner agreement';

export interface PartnerFacts {
  owner_id: string; partner_id: string; partner_number: string;
  partner: { business_name: string; legal_name: string; signer_name: string; signer_title: string | null; address: string; email: string | null; phone: string | null; hst_number: string | null };
  commission_bps: number;
  insurance: { company: string | null; policy: string | null; expiry: string | null };
  payout_day: number;
  cars: Array<{ name: string; plate: string | null; vin: string; commission_bps: number }>;
  company: { brand: string; legal_name: string; address: string; phone: string; email: string };
}

// The text. {{tokens}} are filled from the facts.
export const PARTNER_AGREEMENT_MD = `**Draft for lawyer review. Not yet approved for use.**

This agreement is between **{{company}}**, operating as {{brand}} ("CarmaCars"), and **{{partner}}** ("the Partner"), partner number {{partner_number}}.

## 1. What this agreement is for

The Partner owns or controls rental cars. CarmaCars lists some of them on its website and its other channels, takes the bookings, deals with the renters and collects the money. CarmaCars keeps a commission and pays the Partner the rest.

## 2. The cars

The cars covered are the ones in the table below, and any car the Partner and CarmaCars later add in writing (an email is enough). Either party may take a car out of the program with 14 days' notice, but not while it has a confirmed booking.

## 3. Bookings and renters

- CarmaCars sets the prices for renters, unless the Partner and CarmaCars agree otherwise in writing.
- CarmaCars decides which bookings to accept and handles renters, payments, deposits, extensions and cancellations under its own rental terms.
- The Partner keeps each car available for its confirmed bookings and tells CarmaCars at once if a car cannot be rented.

## 4. Money

- CarmaCars keeps a commission of **{{commission}}** of the rental revenue of each car (the rental charge and the kilometre overage), unless the table below gives a different commission for a car.
- Fees CarmaCars charges renters for its own services (such as delivery, administration fees and coverage CarmaCars sells) are CarmaCars' own.
- Tolls, tickets and damage during a rental are charged to the renter where the law and the rental terms allow. Tolls and tickets when the Partner had the car are the Partner's.
- CarmaCars sends the Partner a statement for each month and pays the Partner's share by bank transfer or e-Transfer on or about day {{payout_day}} of the next month. A refund or chargeback after a payout comes off the next statement.
- HST is added to payments where the Partner gives CarmaCars its HST number.

## 5. Insurance and the cars' condition

- The Partner keeps each car insured for rental use at its own cost and keeps the insurance in force. Its insurance on file: {{insurance}}.
- The Partner sends CarmaCars proof of insurance when asked and when it renews, and tells CarmaCars at once if the insurance ends or changes.
- The Partner keeps each car safe, legal, clean and maintained, with valid plates and permit.

## 6. Damage and claims

If a car is damaged during a rental, CarmaCars collects what it can from the renter under its rental terms and helps the Partner with the claim. The Partner's insurer handles claims under the Partner's policy. CarmaCars is not responsible for damage it did not cause.

## 7. Information

CarmaCars keeps renters' personal information private and shares with the Partner only what the Partner needs for a car. Each party keeps the other's business information confidential.

## 8. Ending the agreement

Either party may end this agreement with 30 days' written notice. Bookings confirmed before the end are completed, and CarmaCars pays what is owed on the final statement.

## 9. General

This is the whole agreement about the cars below. A change must be in writing and agreed by both parties. The laws of Ontario apply. Signing electronically or on paper has the same effect.`;

const pct = (bps: number) => `${(bps / 100).toFixed(bps % 100 ? 2 : 0)}%`;

export function partnerAgreementBlocks(f: PartnerFacts, sig?: { partner?: SignatureRow; carmacars?: SignatureRow }): Block[] {
  const company = f.company.legal_name || f.company.brand;
  const insurance = f.insurance.company ? `${f.insurance.company}${f.insurance.policy ? `, policy ${f.insurance.policy}` : ''}${f.insurance.expiry ? `, expiring ${f.insurance.expiry}` : ''}` : 'to be provided before the first rental';
  const body = markdown(PARTNER_AGREEMENT_MD, { company, brand: f.company.brand, partner: f.partner.legal_name || f.partner.business_name, partner_number: f.partner_number,
    commission: pct(f.commission_bps), payout_day: String(f.payout_day), insurance });
  const blank = (party: string, name: string): SignatureRow => ({ party, name, signature: '', when: '' });
  return [
    { t: 'title', text: PARTNER_AGREEMENT_TITLE },
    ...body,
    { t: 'h2', text: 'The cars' },
    { t: 'table', head: ['Car', 'Plate', 'VIN', 'Commission'], rows: f.cars.length ? f.cars.map((c) => [c.name, c.plate ?? '', c.vin, pct(c.commission_bps)]) : [['Cars added later in writing', '', '', pct(f.commission_bps)]] },
    { t: 'table', kv: true, head: ['', ''], rows: [['Partner', `${f.partner.legal_name || f.partner.business_name}${f.partner.address ? `, ${f.partner.address}` : ''}`], ['Contact', [f.partner.email, f.partner.phone].filter(Boolean).join(', ')], ['CarmaCars', `${company}, ${f.company.address}`]] },
    { t: 'signatures', rows: [sig?.partner ?? blank(`Partner${f.partner.signer_title ? ` (${f.partner.signer_title})` : ''}`, f.partner.signer_name), sig?.carmacars ?? blank('CarmaCars', company)] }
  ];
}
