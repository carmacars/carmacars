// The booking amendment (migration 0040): an addendum to the rental agreement for one accepted change. The renter's
// page and the PDF render the same blocks, so what the renter reads is what is signed. Text markup: **bold** only.
import { money } from '@/lib/format';
import { when, type Block, type SignatureRow } from './model';

export const AMENDMENT_TEMPLATE_VERSION = 'amend-v3-2026-10';
export const AMENDMENT_STATEMENT = 'I have read this amendment to my rental agreement and I sign it electronically.';

export interface ChangeRow { label: string; before: string; after: string }
export interface ChangeFacts {
  change: {
    id: string; status: string; requested_by_role: 'renter' | 'staff'; note: string | null; accept_by: string | null; created_at: string;
    total_difference_cents: number | null; difference_cents: number | null; hst_cents: number | null; renter_agreed_at: string | null;
    decline_reason: string | null; applied_at: string | null; expired_at: string | null; payment_id: string | null; refund_id: string | null;
    before: Record<string, unknown> | null; after: Record<string, unknown> | null;
  };
  rows: ChangeRow[];
  open: boolean;
  booking: { id: string; booking_number: string; status: string; pickup_at: string; return_at: string; vehicle_name: string; renter_user_id: string | null; total_due_at_booking_cents: number };
  renter: { legal_name: string; email: string | null; address: string | null };
  agreement: { id: string; agreement_number: string; status: string; completed_at: string | null } | null;
  amendment: { id: string; amendment_number: string; status: 'open' | 'signed' | 'voided' | 'recorded'; document_id: string | null; document_sha256: string | null; signed_at: string | null; signed_document_id: string | null } | null;
  amendment_number_next: string;
  card_on_file: { method_id: string | null; customer_id: string | null; brand: string | null; last4: string | null } | null;
  company: { brand: string; legal_name: string; address: string; phone: string; email: string; logo_key?: string | null };
  /** Who signs for CarmaCars (0053): the signing officer of the settings, automatically when the Renter signs; the staff
   *  member who proposed or approved the change is only recorded as "Proposed by". */
  countersigner?: { user_id: string | null; name: string; title: string; proposed_by?: string | null } | null;
}

/** The name CarmaCars signs in: the signing officer, else the business name. */
export const countersignerName = (f: ChangeFacts) => f.countersigner?.name || f.company.brand;

/** The number this amendment carries: the open one's, or the next one for a document not opened yet. */
export const amendmentNumber = (f: ChangeFacts) => (f.amendment && f.amendment.status !== 'voided' ? f.amendment.amendment_number : f.amendment_number_next);

export function moneyLine(f: ChangeFacts): string {
  const d = f.change.total_difference_cents ?? 0;
  const card = f.card_on_file?.last4 ? `the card ending ${f.card_on_file.last4} on this booking` : 'the card on this booking';
  if (d > 0) return `The Renter pays **${money(d, { cents: true })}** more (HST included), charged to ${card} when this amendment is signed.`;
  if (d < 0) return `CarmaCars refunds **${money(-d, { cents: true })}** (HST included) to ${f.card_on_file?.last4 ? `the card ending ${f.card_on_file.last4}` : 'the card on this booking'} within 10 business days after this amendment is signed.`;
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
    { t: 'p', text: 'CarmaCars signs this amendment electronically at the moment the Renter signs it.' },
    { t: 'signatures', rows: signatures ?? [
      { party: 'Renter', name: f.renter.legal_name, signature: 'Not yet signed', when: '' },
      { party: 'CarmaCars', name: countersignerName(f), signature: 'Not yet signed', when: '' }
    ] }
  ];
  return blocks;
}

export const amendmentFooter = (f: ChangeFacts) => `CarmaCars booking amendment ${amendmentNumber(f)} for booking ${f.booking.booking_number}. ${AMENDMENT_TEMPLATE_VERSION}`;
