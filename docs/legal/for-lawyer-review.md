# Legal texts for lawyer review

Prepared October 16, 2026 for CarmaCars' lawyer. Every text below is copied verbatim from the code that shows it, with the
file it lives in and where it appears, so the lawyer can mark up the exact words. Placeholders in `{{double braces}}`
or `${...}` are filled from the records (company name, owner, partner, amounts, dates) when the document is made;
`[●]` marks a blank of the source document. Program settings values as configured today are noted where they fill a text.

To change a text: edit the file named, bump its version (where one is given) and redeploy. Documents already signed keep
the version that was signed (each signed document stores its SHA-256 and its text version).

Contents: 1. Owner pre-authorized debit (PAD) agreement and the Stripe mandate. 2. Booking amendment. 3. Forms C and D.
4. Partner agreement (draft). 5. Automatic countersignatures. 6. Paper-signature records. 7. The electronic signing statements.

## 1. Owner pre-authorized debit agreement and the Stripe mandate

**Where it appears.** Owner portal: Banking > Set up pre-authorized debit (`/owner/banking`, component
`web/src/features/owner/DebitSetupForm.tsx`, without the invoice words) and an invoice paid by bank debit
(`/owner/invoices/<number>`, `web/src/features/owner/OwnerPayForm.tsx`). The owner ticks "I accept the pre-authorized debit
agreement above." Heading: "Pre-authorized debit agreement (personal)" or "(business)" for a corporation.

**File.** `web/src/features/owner/OwnerPayForm.tsx`, `mandateText`. Values from Program settings today: debit day the 15th
(`debit_day_text`), retry from the 18th (`retry_day_text`), notice 10 days (`notice_days`), Late Fee $50.00 (`late_fee`).

```ts
export const mandateText = (kind: 'personal' | 'business', t: DebitTerms, withInvoice = true) => [
  `You authorize CarmaCars to debit the bank account you give${withInvoice ? ' for this invoice now, and' : ''} for the fees on your CarmaCars invoices: the monthly fees of your vehicles enrolled with CarmaCars (the Insurance Fee, and the Tracker Fee once a tracker is installed, plus HST, as set in your Vehicle Schedule), the first and last month's Insurance Fee, the Tracker Install Fee and other amounts invoiced to you, on the ${t.debit_day_text} of each month. If a debit is returned, we try again from the ${t.retry_day_text} with the ${t.late_fee} Late Fee your Enrollment Agreement sets.`,
  `The amount can change from month to month with your vehicles and their fees. We email you a notice listing every invoice and the total ${t.notice_days} days before each debit, and each invoice is in your owner portal.`,
  `This authorization is for ${kind} purposes and stays in effect until you cancel it. You may cancel it at any time by writing to billing@carmacars.ca; cancelling it does not end your agreement or the fees you owe. You have certain recourse rights if a debit does not comply with this agreement: for example, the right to be reimbursed for a debit that was not authorized or is not consistent with this agreement. For more information on your recourse rights, contact your financial institution or visit payments.ca.`
];
```

**The Stripe mandate.** The bank account is collected and the mandate accepted in Stripe's own bank form (ACSS debit,
SetupIntent or PaymentIntent, `web/src/integrations/payments/stripe.ts`). Stripe shows its standard Canadian PAD mandate
text in that form; it is Stripe's text, not in this code base. What we send Stripe to fill it:
`payment_schedule = interval`, `transaction_type = personal` or `business` (by owner type), and this interval description
(`'interval_description', format('On the %s of each month for the fees on your CarmaCars invoices, with notice %s days before; a returned debit is tried again from the %s',`, `supabase/migrations/0037_owner_debit.sql` line 702, function `app.owner_debit_terms`), today:

> On the 15th of each month for the fees on your CarmaCars invoices, with notice 10 days before; a returned debit is tried again from the 18th

## 2. Booking amendment

**Where it appears.** A change to a confirmed booking (dates, car, extras) proposed by staff or asked by the renter: the
renter reads and signs it in their portal (`/account/bookings/<number>/change`); the PDF is stored with the booking.
Signing statement: "I have read this amendment to my rental agreement and I sign it electronically."

**File.** `web/src/features/agreement/amendment.ts` (`amendmentBlocks`, `moneyLine`), text version `amend-v1-2026-10`.

```ts
export function moneyLine(f: ChangeFacts): string {
  const d = f.change.total_difference_cents ?? 0;
  const card = f.card_on_file?.last4 ? `the card ending ${f.card_on_file.last4} on this booking` : 'the card on this booking';
  if (d > 0) return `The Renter pays **${money(d, { cents: true })}** more (HST included), charged to ${card} when this amendment is signed.`;
  if (d < 0) return `CarmaCars refunds **${money(-d, { cents: true })}** (HST included) to ${card} after this amendment is signed.`;
  return 'The price of the booking does not change.';
}

export function amendmentBlocks(f: ChangeFacts, signatures?: SignatureRow[]): Block[] {
  const total = (f.change.after?.total_cents as number | undefined) ?? f.booking.total_due_at_booking_cents;
  const blocks: Block[] = [
    { t: 'title', text: `Amendment ${amendmentNumber(f)}` },
    { t: 'p', text: `This amends the rental agreement ${f.agreement ? `**${f.agreement.agreement_number}**` : ''} for booking **${f.booking.booking_number}** between **CarmaCars** and **${f.renter.legal_name}** (the **Renter**).` },
    { t: 'h2', text: '1. What changes' },
    { t: 'table', head: ['Item', 'Before', 'After'], rows: f.rows.map((r) => [r.label, r.before, r.after]) },
    ...(f.change.note ? [{ t: 'p' as const, text: `Reason: ${f.change.note}` }] : []),
    { t: 'h2', text: '2. Payment' },
    { t: 'p', text: moneyLine(f) },
    { t: 'p', text: `The booking total after this amendment is **${money(total, { cents: true })}** (HST included). The Deposit, the kilometre allowance per day and every fee rate stay as they were.` },
    { t: 'h2', text: '3. Everything else stays the same' },
    { t: 'ul', items: [
      'All other terms of the rental agreement continue to apply to the booking as changed here.',
      'This amendment takes effect when the Renter signs it and any amount above is paid. Until then the booking stays as it was.',
      f.change.accept_by ? `If it is not signed by ${when(f.change.accept_by)}, this amendment lapses and the booking stays as it was.` : 'If it is not signed before the pickup, this amendment lapses and the booking stays as it was.'
    ] },
    { t: 'h2', text: '4. Signature' },
    { t: 'signatures', rows: signatures ?? [
      { party: 'Renter', name: f.renter.legal_name, signature: 'Not yet signed', when: '' },
      { party: 'CarmaCars', name: f.company.brand, signature: 'Proposed or approved by CarmaCars staff', when: when(f.change.created_at) }
    ] }
  ];
  return blocks;
}
```

## 3. Forms C and D (witnessed, signed on paper)

**Where they appear.** Owner portal > Documents (`/owner/documents/witnessed/c` and `/d`, PDF made by
`web/src/app/owner/documents/witnessed/[code]/route.ts` with `web/src/features/owner-agreement/witnessed.ts`): printed,
signed in front of witnesses, uploaded; reviewed in Admin > Owner forms. Form C is for a financed or leased car; Form D for
every car under the Title-Holding and Lease Agreement.

**File.** `web/src/features/owner-agreement/forms.generated.ts` (generated from `docs/source/v2_title_holding.md` by
`web/scripts/gen-owner-agreements.mjs`), version `forms-cd-15ecb51df6`. `{{company}}` is the company legal name.
`witnessed.ts` adds the title, the vehicle table, the printed names and "How to complete this form".

### Form C: lender or lessor permission acknowledgment

```markdown
Owner: [●]. This form covers each Vehicle listed below that is Financed or Leased.

| Vehicle | VIN | Lender or lessor, and account | Written permission |
| --- | --- | --- | --- |
| [●] | [●] | [●] | ☐ Attached ☐ Not obtained |

> **WARNING.** Your loan or lease almost certainly restricts changing the registration of your vehicle, leasing it or renting it out. You must get your lender's or lessor's written permission before the registration is changed. Without it you may be in breach. Your lender or lessor may demand full payment, add charges, repossess the vehicle or end the lease. You alone bear those consequences.

Attached: I have written permission for that Vehicle, attached. Not obtained: I do not have written permission for that Vehicle and choose to go ahead.

| I acknowledge | Initials |
| --- | --- |
| I have read the warning. Getting permission is my responsibility, not CarmaCars'. | ____ |
| CarmaCars has not advised me on my loan or lease, or taken it on. I must keep paying on time. | ____ |
| If permission is missing, incomplete or withdrawn, I alone bear the consequences. I will not claim against CarmaCars, and I will reimburse its reasonable costs if my lender or lessor acts against a Vehicle. | ____ |

| | Owner | Witness |
| --- | --- | --- |
| Signature and date | ____________ | ____________ |
```

### Form D: limited power of attorney

```markdown
Owner: [●]. Vehicles: every Vehicle in the Title Schedule.

**Part 1: From the Owner to CarmaCars**

I appoint {{company}}, operating as CarmaCars, as my attorney for each Vehicle, only to:

- **Registry:** record the Onboarding Method, renew or replace the permit and plates, obtain vehicle records, and transfer the registration back to me or to a person I name in writing;
- **Insurance:** add the Vehicle to and remove it from CarmaCars' fleet policy, manage claims and repairs, sign releases and endorse insurer payments;
- **Tolls and tickets:** move a toll, ticket or offence notice to the person responsible; and
- **Lien:** register and discharge a lien in my favour.

My attorney may not sell a Vehicle, borrow against it, transfer it to anyone else, or act for me in any other matter.

For each Vehicle, this power lasts until the registration is back in my name and every claim, toll and ticket is closed. Before then I will not revoke it without also giving notice to take the Vehicle back. This is not a continuing power of attorney for property and revokes no other.

| | Owner | Witness 1 | Witness 2 |
| --- | --- | --- | --- |
| Signature and date | ____________ | ____________ | ____________ |

**Part 2: From CarmaCars to the Owner**

{{company}}, operating as CarmaCars, appoints the Owner as its attorney for one purpose only: to sign and file in CarmaCars' name the Registry forms needed to transfer the registration of a Vehicle back to the Owner or to a person the Owner names in writing, or to remove CarmaCars as lessee or registrant of a Vehicle.

The Owner may use this power only where section 11.5 of the Vehicle Title-Holding and Lease Agreement allows. It is given to protect the Owner's beneficial ownership of each Vehicle. CarmaCars may not revoke it while any registration of a Vehicle stands in CarmaCars' name.

| | CarmaCars | Witness |
| --- | --- | --- |
| Signature and date | ____________ | ____________ |
```

## 4. Partner agreement (DRAFT for lawyer review)

**Where it appears.** A partner rental company signs it on screen in the owner portal (`/owner/partner-agreement`), or on
paper: Admin > Partners > a partner > "Print the partner agreement" (`/admin/partners/<id>/agreement`), then "Record paper
signature". Filled from the partner record (`app.partner_agreement_facts`, `supabase/migrations/0046_supply_manual_rentals.sql`):
company, partner, partner number, commission (default 20% in Program settings, per partner and per car overrides),
insurance on file and the payout day. A table of the cars, the parties' details and the signature block follow the text.

**File.** `web/src/features/partner/agreement.ts` (`PARTNER_AGREEMENT_MD`), version `partner-draft-2026-10-16`. It is marked
"Draft for lawyer review. Not yet approved for use." in the document itself.

```markdown
**Draft for lawyer review. Not yet approved for use.**

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

This is the whole agreement about the cars below. A change must be in writing and agreed by both parties. The laws of Ontario apply. Signing electronically or on paper has the same effect.
```

## 5. Automatic countersignatures

CarmaCars' signature is added automatically (signature method `automatic`, in the name of the signing officer in Program
settings, or the trade name when none is set) when the other party signs. The wording below is stored as the consent text
of CarmaCars' signature record and printed on the signature record page of the signed PDF. `%s` is the company trade name
("CarmaCars").

- **Rental agreement (online booking): when the booking is confirmed (paid).** `supabase/migrations/0019_booking_app.sql` line 1679:

  ```
  format('Countersigned for %s automatically when the booking was confirmed, in the name of the staff member who sent the offer.',
  ```

- **Owner agreements (Vehicle Enrollment Agreement, Vehicle Schedule, Title-Holding and Lease Agreement): when the owner signs.** `supabase/migrations/0029_owner_portal.sql` line 543:

  ```
  format('Countersigned for %s automatically when the owner signed.', ps.company_trade_name), v_sha);
  ```

- **Forms A and B of the Title-Holding and Lease Agreement: when the owner signs on screen (investment and staff agreements get no automatic countersignature).** `supabase/migrations/0044_guides_manual_records.sql` line 1312:

  ```
  format('Countersigned for %s automatically when the owner signed.', ps.company_trade_name), r.document_sha256
  ```

- **Owner documents signed on paper: when staff record the paper signature.** `supabase/migrations/0044_guides_manual_records.sql` line 1476:

  ```
  format('Countersigned for %s when the owner''s paper signature was recorded.', ps.company_trade_name), v_sha
  ```

- **Partner agreement: when the partner signs (on screen or recorded on paper).** `supabase/migrations/0046_supply_manual_rentals.sql` line 861:

  ```
  format('Countersigned for %s automatically when the partner signed.', ps.company_trade_name), r.document_sha256
  ```

- **Rental agreement of a rental added by hand: when the renter signs (on screen or recorded on paper).** `supabase/migrations/0046_supply_manual_rentals.sql` line 1516:

  ```
  format('Countersigned for %s automatically when the renter signed, in the name of the staff member who added the rental.', v_set.company_trade_name),
  ```

## 6. Paper-signature records

When staff record a document signed on paper (Admin: the owner checklist, a partner, an investor, a staff member, a
booking), the scan is stored and a signature record is made for the signer and for each witness. Function
`app.paper_records`, `supabase/migrations/0044_guides_manual_records.sql` (also used for the partner agreement and the
rental agreement of a rental added by hand by 0046):

- Signer (line 990): "Signed on paper. The signed copy was scanned and is kept with this record."
- Each witness (line 994): "Witnessed the signature on paper."

CarmaCars' countersignature on paper-signed owner documents uses the wording in section 5 ("when the owner's paper
signature was recorded"); the partner agreement and a rental added by hand use their automatic wording.

## 7. The electronic signing statements

- Documents signed in a portal (Forms A and B, investment, staff and partner agreements):
  `web/src/features/manual/constants.ts` `SIGN_STATEMENT`: "I have read this document and I sign it electronically. My typed name or drawn signature is my signature, with the same effect as signing on paper."
- Booking amendment: `web/src/features/agreement/amendment.ts` `AMENDMENT_STATEMENT`: "I have read this amendment to my rental agreement and I sign it electronically."
- The rental agreement's consents (tracking, identity verification, electronic signature, card authorization) are in
  `web/src/features/agreement/` and the consent catalogue of `supabase/migrations/0019_booking_app.sql`; they were reviewed
  with the rental agreement and are unchanged.
