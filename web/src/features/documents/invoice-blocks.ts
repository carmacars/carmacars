// r35 UX (1108): the invoices' clean layout, shared by the insurer invoice (issued as Blind Spot Car Rental), the owner and
// partner invoices and the renter's statement and receipt. Pure (no server import): pdf.ts renders it, invoice-blocks.test.ts
// checks it. The owner, November 9: "super ugly formatting ... this needs to look professional and clean", "it can't say
// carmacars or have the carmacars logo", "instead of it saying fees charged at booking ... it needs to say what fees are
// being charged", "invoices also need to have the direct deposit info on the bottom of the invoice as well as the etransfer
// details".
// The layout: a header block (who issues it, with the legal entity), the bill-to block, the reference block, the line-item
// table, the totals, how to pay, the terms. Every two-column table has its labels left and its values right (the renderer's
// valuesRight), the claim number included.
import type { Block } from '../agreement/model.ts';
import { companyParty } from '../../lib/format.ts';

type Row = Record<string, unknown>;
export interface InvoiceCompany { brand: string; legal_name: string; address: string; hst_number: string | null; phone: string; email: string; site?: string | null; logo_key?: string | null }
export interface Pay { account_name?: string | null; institution?: string | null; institution_number?: string | null; transit_number?: string | null; account_number?: string | null; etransfer_email?: string | null }

const n = (v: unknown) => (typeof v === 'number' ? v : typeof v === 'string' && v !== '' ? Number(v) : 0);
const s = (v: unknown) => (v === null || v === undefined ? '' : String(v));
export const money = (c: unknown) => {
  const v = n(c) / 100;
  return `${v < 0 ? '-' : ''}$${Math.abs(v).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
};
const date = (v: unknown) => {
  if (!v) return '';
  const iso = typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v);
  const d = iso ? new Date(`${String(v)}T12:00:00Z`) : new Date(String(v));
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleDateString('en-CA', { timeZone: iso ? 'UTC' : 'America/Toronto', year: 'numeric', month: 'short', day: 'numeric' });
};
const kv = (head: string, rows: Array<[string, string]>): Block => ({ t: 'table', head: [head, ''], kv: true, rows: rows.filter(([, v]) => v !== '') });

/** The issuer block: the trade name as the heading line, the legal entity, the address, HST and the contact. */
export function issuerBlock(c: InvoiceCompany): Block {
  return kv('From', [['Issued by', s(c.brand)], ['Legal entity', companyParty(c.legal_name, c.brand)], ['Address', s(c.address)],
    ['HST number', s(c.hst_number)], ['Phone', s(c.phone)], ['Email', s(c.email)]]);
}

/** The fee lines of an invoice: a "Fees charged at booking" line is replaced by the fees by name when they add up to it. */
export function itemizeLines(lines: Row[], feeItems: Row[] | null | undefined): Array<[string, number]> {
  const out: Array<[string, number]> = [];
  const items = (feeItems ?? []).filter((x) => s(x.description) && n(x.amount_cents) !== 0);
  const sum = items.reduce((a, x) => a + n(x.amount_cents), 0);
  for (const l of lines) {
    const label = s(l.label ?? l.description) || 'Rental';
    if (/^Fees charged at booking/i.test(label)) {
      if (items.length && sum === n(l.amount_cents)) { for (const x of items) out.push([s(x.description), n(x.amount_cents)]); continue; }
      out.push(['Other charges at booking', n(l.amount_cents)]);
      continue;
    }
    out.push([label, n(l.amount_cents)]);
  }
  return out;
}

/** How to pay: direct deposit and Interac e-Transfer, each left out when nothing is entered. */
export function payBlocks(pay: Pay | null | undefined, invoiceNumber: string): Block[] {
  if (!pay) return [];
  const dd: Array<[string, string]> = [['Account name', s(pay.account_name)], ['Institution', s(pay.institution)], ['Institution number', s(pay.institution_number)],
    ['Transit number', s(pay.transit_number)], ['Account number', s(pay.account_number)]].filter(([, v]) => v !== '') as Array<[string, string]>;
  const et = s(pay.etransfer_email);
  if (!dd.length && !et) return [];
  const out: Block[] = [{ t: 'h2', text: 'How to pay' }];
  if (dd.length) out.push(kv('Direct deposit', dd));
  if (et) out.push(kv('Interac e-Transfer', [['Send to', et], ['Message', `Invoice ${invoiceNumber}`]]));
  out.push({ t: 'p', text: `Please quote invoice ${invoiceNumber} with your payment${et ? ' (put the invoice number in the e-Transfer message)' : ''}.` });
  return out;
}

/** The insurer invoice: issued as Blind Spot Car Rental (the company block the database gives it), the fees by name. */
export function insurerInvoiceBlocks(f: Row & { company: InvoiceCompany }): Block[] {
  const i = (f.insurer ?? {}) as Row;
  const num = s(f.invoice_number);
  const lines = itemizeLines((f.lines ?? []) as Row[], f.fee_items as Row[] | undefined);
  const items: Array<[string, number]> = lines.length ? lines : [['Replacement rental', n(f.amount_cents)]];
  const paid = n(f.paid_cents);
  const blocks: Block[] = [
    { t: 'title', text: `Invoice ${num}` },
    issuerBlock(f.company),
    kv('Bill to', [['Insurer', s(i.name)], ['Attention', s(i.contact)], ['Address', s(i.address)], ['Email', s(i.email)]]),
    kv('Invoice details', [['Invoice number', num], ['Invoice date', date(f.sent_at ?? f.created_at)], ['Claim number', s(f.claim_number) || 'Not given'],
      ['Insured / renter', s(f.renter_name)], ['Rental agreement', s(f.booking_number)], ['Vehicle', s(f.vehicle)], ['Rental period', f.period_start ? `${date(f.period_start)} to ${date(f.period_end)}` : '']]),
    { t: 'table', head: ['Description', 'Amount'], kv: true, rows: items.map(([d, a]) => [d, money(a)]) },
    kv('Totals', [['Subtotal', money(f.amount_cents)], ['HST', money(f.hst_cents)], ['**Total**', `**${money(f.total_cents)}**`], ['Paid', money(paid)],
      ['**Balance due**', `**${money(f.balance_cents ?? n(f.total_cents) - paid)}**`]])
  ];
  // the insurer's taxes note from its rate sheet (0163)
  if (s(f.note)) blocks.push({ t: 'p', text: s(f.note) });
  blocks.push(...payBlocks(f.pay as Pay | undefined, num));
  blocks.push({ t: 'h2', text: 'Terms' });
  blocks.push({ t: 'p', text: `Payment is due within 30 days of the invoice date. Please quote invoice ${num} and claim ${s(f.claim_number) || 'number'} with your payment.${f.company.email ? ` Questions: ${f.company.email}.` : ''}` });
  return blocks;
}

/** The footer of an invoice: the issuer and the title; "Draft" only while it can still change, never "Preview" on an issued one. */
export function invoiceFooter(f: Row & { title: string; company: InvoiceCompany }): string {
  const draft = s(f.status) === 'draft' || f.final === false;
  return `${s(f.company.brand)}. ${f.title}.${draft ? ' Draft: not yet issued.' : ''}`;
}
