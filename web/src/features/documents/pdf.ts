import 'server-only';
import { agreementPdf } from '@/features/agreement/pdf';
import type { Block } from '@/features/agreement/model';

// The generated documents (docs/blueprint/11-statements-and-reports.md sections 2, 4 and 7): owner
// statements, renter statements and receipts, insurer invoices, investor statements and the yearly
// summary. The facts come from the database (app.pdf_facts, migration 0032); this lays them out with the
// same pdf-lib renderer as the agreements, with the CarmaCars wordmark on every page. Deterministic: the
// same facts give the same bytes, so a stored copy is identified by its SHA-256.
export type DocKind = 'owner_statement' | 'renter_statement' | 'receipt' | 'insurer_invoice' | 'investor_statement' | 'investor_year';
export const DOC_KINDS: readonly DocKind[] = ['owner_statement', 'renter_statement', 'receipt', 'insurer_invoice', 'investor_statement', 'investor_year'];

type F = Record<string, unknown> & { title: string; file_name: string; final: boolean; company: Company };
interface Company { brand: string; legal_name: string; address: string; hst_number: string | null; phone: string; email: string; site: string }
type Row = Record<string, unknown>;

const n = (v: unknown) => (typeof v === 'number' ? v : typeof v === 'string' && v !== '' ? Number(v) : 0);
const s = (v: unknown) => (v === null || v === undefined ? '' : String(v));
export const dollars = (c: unknown) => {
  const v = n(c) / 100;
  return `${v < 0 ? '-' : ''}$${Math.abs(v).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
};
const TZ = 'America/Toronto';
const day = (v: unknown) => {
  if (!v) return '';
  const d = typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) ? new Date(`${v}T12:00:00Z`) : new Date(String(v));
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleDateString('en-CA', { timeZone: typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) ? 'UTC' : TZ, year: 'numeric', month: 'short', day: 'numeric' });
};
const month = (v: unknown) => (v ? new Date(`${String(v).slice(0, 10)}T12:00:00Z`).toLocaleDateString('en-CA', { timeZone: 'UTC', year: 'numeric', month: 'long' }) : '');
const label = (v: unknown) => s(v).replace(/_/g, ' ');
const pct = (bps: unknown) => `${(n(bps) / 100).toLocaleString('en-CA', { maximumFractionDigits: 2 })}%`;

function header(f: F, to: Array<[string, string]>, ref: Array<[string, string]>): Block[] {
  const c = f.company;
  return [
    { t: 'title', text: f.title },
    { t: 'table', head: ['From', ''], kv: true, rows: [
      ['Company', `${c.legal_name} (operating as ${c.brand})`], ...(c.address ? [['Address', c.address] as [string, string]] : []),
      ...(c.hst_number ? [['HST number', c.hst_number] as [string, string]] : []), ['Contact', [c.email, c.phone].filter(Boolean).join(', ')]] },
    ...(to.length ? [{ t: 'table' as const, head: ['To', ''], kv: true, rows: to }] : []),
    { t: 'table', head: ['Reference', ''], kv: true, rows: ref }
  ];
}

function ownerStatement(f: F): Block[] {
  const o = (f.owner ?? {}) as Row;
  const t = (f.totals ?? {}) as Row;
  const paid = f.paid as Row | null;
  const blocks = header(f, [['Owner', s(o.legal_name)], ...(s(o.address) ? [['Address', s(o.address)] as [string, string]] : []), ...(o.hst_number ? [['HST number', s(o.hst_number)] as [string, string]] : [])],
    [['Statement', s(f.statement_number)], ['Month', month(f.statement_month)], ['Payout date', day(f.payout_date)], ['Status', label(f.status)], ...(f.is_final ? [['Final statement', 'Yes'] as [string, string]] : [])]);
  for (const v of (f.vehicles ?? []) as Row[]) {
    blocks.push({ t: 'h2', text: `${s(v.vehicle)}${v.plate ? `, ${s(v.plate)}` : ''}` });
    const lines = (v.lines ?? []) as Row[];
    const rentals = lines.filter((l) => l.line_type === 'rental' || l.line_type === 'turo_trip');
    if (rentals.length) blocks.push({ t: 'table', head: ['Rental', 'Dates', 'Rental Charge', 'Kickback', 'Owner Revenue'],
      rows: rentals.map((l) => [s(l.booking_number) || label(l.line_type), `${day(l.starts_on)} to ${day(l.ends_on)}`, dollars(n(l.rental_charge_cents) + n(l.mileage_overage_cents)), dollars(-n(l.kickback_cents)), dollars(l.owner_revenue_cents)]) });
    const others = lines.filter((l) => !['rental', 'turo_trip'].includes(String(l.line_type)));
    if (others.length) blocks.push({ t: 'table', head: ['Item', 'Detail', 'Amount'], rows: others.map((l) => [label(l.line_type), s(l.description) || s(l.booking_number), dollars(n(l.amount_cents) || n(l.fee_cents) + n(l.late_fee_cents))]) });
    blocks.push({ t: 'table', head: ['Vehicle totals', ''], kv: true, rows: [
      ['Owner Revenue', dollars(v.owner_revenue_cents)], ['Revenue Share kept by CarmaCars', dollars(-n(v.revenue_share_cents))], ['Net earnings', dollars(v.net_earnings_cents)],
      ['Unpaid fees and Late Fees deducted', dollars(-(n(v.fees_deducted_cents) + n(v.late_fees_deducted_cents)))], ['Owner costs deducted', dollars(-n(v.owner_costs_deducted_cents))],
      ['Refund and chargeback shares', dollars(-n(v.refund_chargeback_deducted_cents))], ['Vehicle payable', dollars(v.payable_cents)]] });
  }
  const ol = (f.owner_lines ?? []) as Row[];
  if (ol.length) { blocks.push({ t: 'h2', text: 'Owner lines' }); blocks.push({ t: 'table', head: ['Item', 'Detail', 'Amount'], rows: ol.map((l) => [label(l.line_type), s(l.description) || s(l.booking_number), dollars(l.amount_cents)]) }); }
  blocks.push({ t: 'h2', text: n(t.payout_cents) > 0 ? 'Payout' : 'Balance' });
  blocks.push({ t: 'table', head: ['Totals', ''], kv: true, rows: [
    ['Vehicles payable', dollars(t.vehicles_payable_cents)], ['Arrears moved between vehicles', dollars(t.arrears_moved_cents)], ['Referral Kickbacks earned', dollars(t.kickbacks_earned_cents)],
    ['HST on payout', dollars(t.hst_on_payout_cents)], ['Balance brought forward', dollars(t.balance_brought_forward_cents)],
    [n(t.payout_cents) > 0 ? '**Payout**' : '**Balance owing**', `**${dollars(n(t.payout_cents) > 0 ? t.payout_cents : -n(t.balance_carried_forward_cents))}**`],
    ...(paid ? [['Paid', `${day(paid.paid_at)}, ${label(paid.method)}, reference ${s(paid.reference)}`] as [string, string]] : [])] });
  blocks.push({ t: 'p', text: 'Fees are billed separately on the 15th. Questions: reply to the statement email or use Statements in your owner portal.' });
  return blocks;
}

function renterStatement(f: F): Block[] {
  const r = (f.renter ?? {}) as Row;
  const lines = (f.lines ?? []) as Row[];
  const blocks = header(f, [['Renter', s(r.legal_name)]], [['Statement', s(f.statement_number)], ['Kind', label(f.kind)], ['Issued', day(f.issued_at)], ['Booking', s(f.booking_number)], ['Vehicle', s(f.vehicle)],
    ['Rental', `${day(f.handed_over_at ?? f.pickup_at)} to ${day(f.checked_in_at ?? f.return_at)}`]]);
  blocks.push({ t: 'h2', text: 'Charges' });
  blocks.push({ t: 'table', head: ['Charge', 'Amount', 'HST'], rows: lines.length ? lines.map((l) => [s(l.label), dollars(l.amount_cents), dollars(l.hst_cents)]) : [['No charges', dollars(0), dollars(0)]] });
  blocks.push({ t: 'table', head: ['Settlement', ''], kv: true, rows: [
    ['Charges', dollars(f.charges_cents)], ['HST', dollars(f.hst_cents)], ['**Total**', `**${dollars(n(f.charges_cents) + n(f.hst_cents))}**`],
    ['Paid from the Deposit', dollars(f.deposit_applied_cents)], ['Held back from the Deposit', dollars(f.held_back_cents)], ['Deposit returned', dollars(f.deposit_returned_cents)],
    ['Charged to your card', dollars(f.charged_to_card_cents)], ...(f.paid_at ? [['Paid', day(f.paid_at)] as [string, string]] : f.interest_starts_on ? [['Interest from', day(f.interest_starts_on)] as [string, string]] : [])] });
  blocks.push({ t: 'p', text: 'Questions about a charge: reply to the email that brought this statement, or message us from your booking page.' });
  return blocks;
}

function receipt(f: F): Block[] {
  const lines = (f.lines ?? []) as Row[];
  const payer = (f.payer ?? {}) as Row;
  const blocks = header(f, [['Paid by', s(payer.legal_name)]], [['Receipt', s(f.receipt_number)], ['Date', day(f.paid_at)],
    ...(f.booking_number ? [['Booking', s(f.booking_number)] as [string, string]] : []), ...(f.invoice_number ? [['Invoice', s(f.invoice_number)] as [string, string]] : []),
    ...(f.vehicle ? [['Vehicle', s(f.vehicle)] as [string, string]] : []), ['For', label(f.purpose)],
    ['Paid with', f.card_brand ? `${label(f.card_brand)} ending ${s(f.card_last4)}` : label(f.method)]]);
  if (lines.length) blocks.push({ t: 'table', head: ['Item', 'Amount', 'HST'], rows: lines.map((l) => [s(l.label), dollars(l.amount_cents), dollars(l.hst_cents)]) });
  blocks.push({ t: 'table', head: ['Amount paid', ''], kv: true, rows: [['**Total paid**', `**${dollars(f.amount_cents)}**`]] });
  blocks.push({ t: 'p', text: 'Thank you. Keep this receipt for your records.' });
  return blocks;
}

function insurerInvoice(f: F): Block[] {
  const i = (f.insurer ?? {}) as Row;
  const lines = (f.lines ?? []) as Row[];
  const blocks = header(f, [['Insurer', s(i.name)], ...(i.contact ? [['Attention', s(i.contact)] as [string, string]] : []), ...(i.address ? [['Address', s(i.address)] as [string, string]] : [])],
    [['Invoice', s(f.invoice_number)], ['Date', day(f.sent_at ?? f.created_at)], ['Claim number', s(f.claim_number) || 'Not given'], ['Renter', s(f.renter_name)],
     ['Booking', s(f.booking_number)], ['Vehicle', s(f.vehicle)], ['Period', `${day(f.period_start)} to ${day(f.period_end)}`]]);
  blocks.push({ t: 'table', head: ['Description', 'Amount'], kv: true, rows: lines.length ? lines.map((l) => [s(l.label ?? l.description) || 'Rental', dollars(l.amount_cents)]) : [['Replacement rental', dollars(f.amount_cents)]] });
  blocks.push({ t: 'table', head: ['Total', ''], kv: true, rows: [['Amount before HST', dollars(f.amount_cents)], ['HST', dollars(f.hst_cents)], ['**Total due**', `**${dollars(f.total_cents)}**`],
    ...(n(f.paid_cents) > 0 ? [['Paid', dollars(f.paid_cents)] as [string, string], ['**Balance**', `**${dollars(f.balance_cents)}**`] as [string, string]] : [])] });
  blocks.push({ t: 'p', text: `Please pay by bank transfer and quote invoice ${s(f.invoice_number)}. Questions: ${f.company.email}.` });
  return blocks;
}

function investorStatement(f: F): Block[] {
  const inv = (f.investor ?? {}) as Row;
  const blocks = header(f, [['Investor', s(inv.legal_name)], ...(inv.address ? [['Address', s(inv.address)] as [string, string]] : [])],
    [['Statement', s(f.statement_number)], ['Return Month', month(f.return_month)], ['Investment Agreement', s(f.agreement_number)]]);
  blocks.push({ t: 'table', head: ['This month', ''], kv: true, rows: [
    ['Invested Amount at the start of the month', dollars(f.opening_invested_cents)], ['Yearly rate', pct(f.yearly_bps)], ['Days earning', `${n(f.days_earning)} of ${n(f.days_in_month)}`],
    ['**Return**', `**${dollars(f.return_cents)}**`], ...(n(f.withheld_tax_cents) ? [['Tax withheld', dollars(-n(f.withheld_tax_cents))] as [string, string]] : []),
    ['Treatment', f.disposition === 'reinvest' ? 'Reinvested' : 'Paid to your bank account'], ['Payment date', day(f.payment_date)], ['Status', label(f.status)],
    ['Invested Amount at the end of the month', dollars(f.closing_invested_cents)]] });
  blocks.push({ t: 'p', text: 'This statement is issued under your Investment Agreement. Questions: reply to the statement email.' });
  return blocks;
}

function investorYear(f: F): Block[] {
  const inv = (f.investor ?? {}) as Row;
  const t = (f.totals ?? {}) as Row;
  const blocks = header(f, [['Investor', s(inv.legal_name)], ...(inv.address ? [['Address', s(inv.address)] as [string, string]] : [])], [['Year', s(f.year)], ['Status', f.final ? 'Complete year' : 'Year to date']]);
  blocks.push({ t: 'h2', text: 'Months' });
  const ms = (f.months ?? []) as Row[];
  blocks.push({ t: 'table', head: ['Month', 'Invested at start', 'Return', 'Treatment', 'Status'],
    rows: ms.length ? ms.map((m) => [month(m.return_month), dollars(m.opening_invested_cents), dollars(m.return_cents), m.disposition === 'reinvest' ? 'Reinvested' : 'Paid', label(m.status)]) : [['No returns this year', '', '', '', '']] });
  blocks.push({ t: 'table', head: ['Year totals', ''], kv: true, rows: [['**Returns**', `**${dollars(t.return_cents)}**`], ['Reinvested', dollars(t.reinvested_cents)], ['Paid out', dollars(t.paid_cents)], ['Tax withheld', dollars(t.withheld_tax_cents)]] });
  const xs = (f.investments ?? []) as Row[];
  if (xs.length) { blocks.push({ t: 'h2', text: 'Investments' }); blocks.push({ t: 'table', head: ['Date', 'Principal', 'Invested Amount', 'Yearly rate', 'Status'], rows: xs.map((x) => [day(x.investment_date), dollars(x.principal_cents), dollars(x.invested_amount_cents), pct(x.yearly_bps), label(x.status)]) }); }
  blocks.push({ t: 'p', text: 'A summary for your records; tax slips, where required, are sent separately.' });
  return blocks;
}

export function documentBlocks(kind: DocKind, f: F): Block[] {
  switch (kind) {
    case 'owner_statement': return ownerStatement(f);
    case 'renter_statement': return renterStatement(f);
    case 'receipt': return receipt(f);
    case 'insurer_invoice': return insurerInvoice(f);
    case 'investor_statement': return investorStatement(f);
    case 'investor_year': return investorYear(f);
  }
}

export async function renderDocument(kind: DocKind, facts: Record<string, unknown>): Promise<Uint8Array> {
  const f = facts as F;
  const stamp = String(f.issued_at ?? f.paid_at ?? f.sent_at ?? f.created_at ?? f.statement_month ?? f.return_month ?? `${s(f.year)}-12-31`);
  const created = new Date(/^\d{4}-\d{2}-\d{2}$/.test(stamp) ? `${stamp}T12:00:00Z` : stamp);
  return agreementPdf(documentBlocks(kind, f), {
    title: f.title, createdAt: Number.isNaN(created.getTime()) ? new Date(0) : created, brand: true,
    footer: `${f.company.brand}. ${f.title}.${f.final ? '' : ' Preview: this record can still change.'}`
  });
}
