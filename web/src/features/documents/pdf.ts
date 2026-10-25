import 'server-only';
import { agreementPdf } from '@/features/agreement/pdf';
import type { Block } from '@/features/agreement/model';
import { hoursText } from '@/features/field-pay/model';

// The generated documents (docs/blueprint/11-statements-and-reports.md sections 2, 4 and 7): owner
// statements, renter statements and receipts, insurer invoices, investor statements and the yearly
// summary. The facts come from the database (app.pdf_facts, migration 0032); this lays them out with the
// same pdf-lib renderer as the agreements, with the CarmaCars wordmark on every page. Deterministic: the
// same facts give the same bytes, so a stored copy is identified by its SHA-256.
export type DocKind = 'owner_statement' | 'renter_statement' | 'receipt' | 'insurer_invoice' | 'investor_statement' | 'investor_year'
  | 'company_statement' | 'company_owners' | 'company_vehicles' | 'owner_invoice' | 'terms_notice' | 'pay_statement';
export const DOC_KINDS: readonly DocKind[] = ['owner_statement', 'renter_statement', 'receipt', 'insurer_invoice', 'investor_statement', 'investor_year',
  'company_statement', 'company_owners', 'company_vehicles', 'owner_invoice', 'terms_notice', 'pay_statement'];

type F = Record<string, unknown> & { title: string; file_name: string; final: boolean; company: Company };
interface Company { brand: string; legal_name: string; address: string; hst_number: string | null; phone: string; email: string; site: string; logo_key?: string | null }
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
    // every kickback is an expense of the booking before Owner Revenue: the Referral Kickback and the staff commission apart (0058)
    if (rentals.length) blocks.push({ t: 'table', head: ['Rental', 'Dates', 'Rental Charge', 'Referral Kickback', 'Staff commission', 'Booking expenses', 'Owner Revenue'],
      rows: rentals.map((l) => [s(l.booking_number) || label(l.line_type), `${day(l.starts_on)} to ${day(l.ends_on)}`, dollars(n(l.rental_charge_cents) + n(l.mileage_overage_cents)),
        dollars(-(n(l.kickback_cents) - n(l.staff_commission_cents))), dollars(-n(l.staff_commission_cents)), dollars(-n(l.owner_expense_cents)), dollars(l.owner_revenue_cents)]) });
    // 0156: every documented deduction on a booking, with its reason (an expense line, a Revenue Share for the booking)
    const itemized = rentals.filter((l) => n(l.owner_expense_cents) > 0 || (l.booking_share_bps !== null && l.booking_share_bps !== undefined));
    if (itemized.length) blocks.push({ t: 'table', head: ['Booking', 'Deductions on the booking'], rows: itemized.map((l) => [s(l.booking_number), s(l.description).split('; ').slice(1).join('; ')]) });
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
  blocks.push({ t: 'p', text: 'Fees are billed separately, on your monthly invoices. Questions: reply to the statement email or use Statements in your owner portal.' });
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
  // the insurer's taxes note from its rate sheet (0163)
  if (s(f.note)) blocks.push({ t: 'p', text: s(f.note) });
  blocks.push({ t: 'p', text: `Please pay by bank transfer and quote invoice ${s(f.invoice_number)}. Questions: ${f.company.email}.` });
  return blocks;
}

// An owner invoice (migration 0067): every line with its quantity, unit amount and HST, the totals, what was paid, a void.
function ownerInvoice(f: F): Block[] {
  const o = (f.owner ?? {}) as Row;
  const lines = (f.lines ?? []) as Row[];
  const pays = (f.payments ?? []) as Row[];
  const blocks = header(f, [['Owner', s(o.legal_name)], ...(s(o.address) ? [['Address', s(o.address)] as [string, string]] : []), ...(o.hst_number ? [['HST number', s(o.hst_number)] as [string, string]] : [])],
    [['Invoice', s(f.invoice_number)], ['For', s(f.subject) || s(f.kind_label)], ['Date', day(f.issued_at)], ...(f.due_on ? [['Due', day(f.due_on)] as [string, string]] : []),
     ['Vehicle', `${s(f.vehicle)}${f.plate ? `, ${s(f.plate)}` : ''}`], ...(f.period_month ? [['Period', month(f.period_month)] as [string, string]] : []),
     ['Status', f.status === 'void' ? `Void: ${s(f.void_reason)}` : label(f.status)], ...(f.replaces ? [['Replaces', s(f.replaces)] as [string, string]] : []),
     ...(f.credit_for ? [['Credit for invoice', s(f.credit_for)] as [string, string]] : []), ['Payee', s(f.payee)]]);
  blocks.push({ t: 'table', head: ['Description', 'Qty', 'Unit', 'Amount', 'HST'],
    rows: lines.map((l) => [s(l.description) + (l.note ? ` (${s(l.note)})` : ''), String(n(l.quantity)), dollars(l.unit_amount_cents), dollars(l.amount_cents), l.hst ? dollars(l.hst_cents) : 'No HST']) });
  blocks.push({ t: 'table', head: ['Totals', ''], kv: true, rows: [['Before HST', dollars(f.fees_cents)], ['HST', dollars(f.hst_cents)],
    ...(n(f.late_fee_cents) ? [['Late Fee', dollars(f.late_fee_cents)] as [string, string]] : []), ['**Total**', `**${dollars(f.total_cents)}**`],
    ...pays.map((p) => [`Paid by ${s(p.method)} on ${day(p.on)}`, dollars(-n(p.amount_cents))] as [string, string]),
    ...(n(f.deducted_cents) ? [['Deducted from payout', dollars(-n(f.deducted_cents))] as [string, string]] : []),
    ['**Balance**', `**${dollars(f.status === 'void' ? 0 : Math.max(0, n(f.balance_cents)))}**`]] });
  if (f.notes) blocks.push({ t: 'p', text: s(f.notes) });
  blocks.push({ t: 'p', text: `Amounts in Canadian dollars. Pay from the invoice page in your owner portal by card, pre-authorized debit or e-Transfer. Questions: ${f.company.email}.` });
  return blocks;
}

// The written notice of a change to an owner's terms for one car (migration 0135): lower amounts, higher Fees by notice,
// or a higher Revenue Share for the owner to sign.
function termsNotice(f: F): Block[] {
  const o = (f.owner ?? {}) as Row;
  const lines = (f.lines ?? []) as Row[];
  const blocks = header(f, [['Owner', s(o.legal_name)], ...(s(o.address) ? [['Address', s(o.address)] as [string, string]] : [])],
    [['Date of notice', day(f.notice_on)], ['Effective', day(f.effective_from)], ['Vehicle', `${s(f.vehicle)}${f.plate ? `, ${s(f.plate)}` : ''}, VIN ${s(f.vin)}`],
     ...(f.schedule_number ? [['Vehicle Schedule', s(f.schedule_number)] as [string, string]] : []),
     ...(f.status === 'cancelled' ? [['Status', `Cancelled${f.cancelled_reason ? `: ${s(f.cancelled_reason)}` : ''}`] as [string, string]] : [])]);
  blocks.push({ t: 'table', head: ['Term', 'Before', 'From the effective date'], rows: lines.length ? lines.map((l) => [s(l.label), s(l.before), s(l.after)]) : [['No amount changes', '', '']] });
  for (const p of (f.paragraphs ?? []) as string[]) blocks.push({ t: 'p', text: p });
  if (f.reason) blocks.push({ t: 'p', text: `Reason: ${s(f.reason)}` });
  blocks.push({ t: 'p', text: s(f.signature) });
  if (f.owner_signed) blocks.push({ t: 'p', text: s(f.owner_signed) });
  blocks.push({ t: 'p', text: `HST is extra on the Fees. Questions: ${f.company.email}.` });
  return blocks;
}

const clock = (v: unknown) => (v ? new Date(String(v)).toLocaleTimeString('en-CA', { timeZone: TZ, hour: 'numeric', minute: '2-digit', hour12: false }) : '');

// A field staff member's pay statement (0165): the hours worked in the two-week period, the amounts, the commissions paid with
// them and how it was paid. Vacation pay and statutory deductions are not computed here (docs/changes/2026-10-25-field-pay-class-rules-mode.md).
function payStatement(f: F): Block[] {
  const p = (f.person ?? {}) as Row;
  const blocks = header(f, [['Staff member', s(p.name)], ...(s(p.address) ? [['Address', s(p.address)] as [string, string]] : [])],
    [['Statement', s(f.statement_number)], ['Pay period', `${day(f.period_start)} to ${day(f.period_end)}`], ['Status', f.status === 'paid' ? `Paid ${day(f.paid_on)}` : 'Approved, payment to follow'],
     ...(f.status === 'paid' ? [['How it was paid', `${s(f.method) === 'e_transfer' ? 'e-Transfer' : s(f.method) === 'bank_transfer' ? 'Bank transfer' : label(f.method)}${f.reference ? `, reference ${s(f.reference)}` : ''}`] as [string, string]] : [])]);
  const reg = n(f.minutes_regular);
  const ot = n(f.minutes_overtime);
  const rows: string[][] = [[`Hours: ${hoursText(reg)} at ${dollars(f.rate_cents)} an hour`, dollars(f.wage_cents)]];
  if (ot > 0) rows.push([`Overtime: ${hoursText(ot)} at ${pct(f.overtime_bps)} of the hourly rate`, dollars(f.overtime_cents)]);
  if (n(f.commission_cents) !== 0) rows.push(['Commissions and referral fees (listed below)', dollars(f.commission_cents)]);
  if (n(f.vacation_cents) > 0) rows.push([`Vacation pay, ${pct(f.vacation_pay_bps)}`, dollars(f.vacation_cents)]);
  rows.push(['**Total paid**', `**${dollars(f.gross_cents)}**`]);
  blocks.push({ t: 'table', head: ['This pay', 'Amount'], rows });
  const shifts = (f.shifts ?? []) as Row[];
  blocks.push({ t: 'h2', text: `Hours worked: ${hoursText(f.minutes_total)}` });
  blocks.push({ t: 'table', head: ['Day', 'From', 'To', 'Hours', 'Note'], rows: shifts.length ? shifts.map((x) => [day(x.day), clock(x.from), clock(x.to), hoursText(x.minutes), s(x.note)]) : [['No hours in this period', '', '', '', '']] });
  const cs = (f.commissions ?? []) as Row[];
  if (cs.length) {
    blocks.push({ t: 'h2', text: 'Commissions and referral fees' });
    blocks.push({ t: 'table', head: ['Booking', 'Month', 'Kind', 'Amount'], rows: cs.map((c) => [s(c.booking), month(c.month), c.kind === 'commission' ? 'Commission' : label(c.kind), dollars(c.amount_cents)]) });
  }
  blocks.push({ t: 'p', text: 'Amounts are before any deduction: this statement does not show income tax, CPP or EI, which are not worked out here. Questions: ' + f.company.email + '.' });
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

// ---------------------------------------------------------------- CarmaCars' own monthly statements (migration 0037)
type SectionRow = { label: string; cents?: number; count?: number; unit?: string; bps?: number; text?: string; account?: string; strong?: boolean };
const sectionValue = (r: SectionRow) => r.text ?? (r.cents !== undefined ? dollars(r.cents) : r.bps !== undefined ? pct(r.bps) : r.count !== undefined ? `${n(r.count).toLocaleString('en-CA')}${r.unit ? ` ${r.unit}` : ''}` : '');
const bold = (v: string, on?: boolean) => (on ? `**${v}**` : v);
const nice = (k: string) => { const t = k.replace(/_cents$/, '').replace(/_bps$/, '').replace(/_/g, ' '); return t.charAt(0).toUpperCase() + t.slice(1); };
function companyHead(f: F, extra: Array<[string, string]> = []): Block[] {
  const c = f.company;
  return [
    { t: 'title', text: f.title },
    { t: 'table', head: ['Statement', ''], kv: true, rows: [
      ['Month', month(f.statement_month)], ['Status', !f.draft ? 'Final' : `Draft, version ${s(f.version)}`],
      ['Built', day(f.built_at)], ...(f.finalized_at ? [['Finalized', day(f.finalized_at)] as [string, string]] : []),
      ['Checks', f.ties_ok ? 'Every check ties' : `Not every check ties${f.tie_problems ? `: ${s(f.tie_problems)}` : ''}`], ...extra,
      ['Company', `${c.legal_name} (operating as ${c.brand})`], ...(c.hst_number ? [['HST number', c.hst_number] as [string, string]] : [])] }
  ];
}
const MONEY_COLS = ['rental_revenue_cents', 'mileage_cents', 'kickbacks_cents', 'owner_revenue_cents', 'revenue_share_cents', 'owner_share_out_cents',
  'discounts_cents', 'company_fees_cents', 'turo_gross_cents', 'turo_revenue_share_cents', 'turo_extras_cents', 'insurance_fees_cents', 'tracker_fees_cents',
  'install_fees_cents', 'other_owner_fees_cents', 'late_fees_cents', 'owner_fees_hst_cents', 'owner_fees_collected_cents', 'owner_fees_outstanding_cents',
  'insurer_billed_cents', 'refunds_cents', 'chargebacks_cents', 'pass_through_in_cents', 'pass_through_out_cents', 'claim_surplus_cents', 'hst_collected_cents',
  'processing_fees_cents', 'expenses_cents', 'owner_payout_cents', 'owner_deductions_cents', 'kickbacks_earned_cents', 'cash_collected_cents', 'company_net_cents'];
function companyStatement(f: F): Block[] {
  const t = (f.total ?? {}) as Row;
  const blocks = companyHead(f);
  blocks.push({ t: 'h2', text: 'The month at a glance' });
  blocks.push({ t: 'table', head: ['Measure', 'Amount'], kv: true, rows: [
    ['Rental revenue', dollars(t.rental_revenue_cents)], ['Revenue Share kept', dollars(n(t.revenue_share_cents) + n(t.turo_revenue_share_cents))],
    ['Renter fees kept', dollars(t.company_fees_cents)], ['Owner fees billed', dollars(n(t.insurance_fees_cents) + n(t.tracker_fees_cents) + n(t.install_fees_cents) + n(t.other_owner_fees_cents))],
    ['Utilization', pct(t.utilization_bps)], ['Rentals ended', s(n(t.rentals_ended))],
    ['**Contribution before costs not in the platform**', `**${dollars(t.company_net_cents)}**`]] });
  for (const sec of (f.sections ?? []) as Array<{ key: string; title: string; note?: string | null; rows: SectionRow[] }>) {
    blocks.push({ t: 'h2', text: sec.title });
    const withAccount = sec.rows.some((r) => r.account);
    blocks.push(sec.rows.length
      ? (withAccount
        ? { t: 'table', head: ['Line', 'Account', 'Amount'], rows: sec.rows.map((r) => [bold(r.label, r.strong), r.account ?? '', bold(sectionValue(r), r.strong)]) }
        : { t: 'table', head: ['Line', 'Value'], kv: true, rows: sec.rows.map((r) => [bold(r.label, r.strong), bold(sectionValue(r), r.strong)]) })
      : { t: 'p', text: 'Nothing this month.' });
    if (sec.note) blocks.push({ t: 'p', text: sec.note });
  }
  blocks.push({ t: 'p', text: 'Earned basis: rentals count in the month they end and owner fees in the month they cover; cash lines count by the day the money moved. The statement by owner and by vehicle are separate PDFs.' });
  return blocks;
}
function companyOwners(f: F): Block[] {
  const os = (f.owners ?? []) as Row[];
  const blocks = companyHead(f, [['Owners', s(os.length)]]);
  blocks.push({ t: 'h2', text: 'All owners' });
  blocks.push({ t: 'table', head: ['Owner', 'Owner Revenue', 'Revenue Share', 'Owner fees', 'Payout', 'Contribution'],
    rows: os.length ? [...os.map((o) => [s(o.owner_name), dollars(o.owner_revenue_cents), dollars(o.revenue_share_cents),
      dollars(n(o.insurance_fees_cents) + n(o.tracker_fees_cents) + n(o.install_fees_cents) + n(o.other_owner_fees_cents)), dollars(o.owner_payout_cents), dollars(o.company_net_cents)]),
      ['**Total**', `**${dollars(os.reduce((a, o) => a + n(o.owner_revenue_cents), 0))}**`, `**${dollars(os.reduce((a, o) => a + n(o.revenue_share_cents), 0))}**`,
       `**${dollars(os.reduce((a, o) => a + n(o.insurance_fees_cents) + n(o.tracker_fees_cents) + n(o.install_fees_cents) + n(o.other_owner_fees_cents), 0))}**`,
       `**${dollars(os.reduce((a, o) => a + n(o.owner_payout_cents), 0))}**`, `**${dollars(os.reduce((a, o) => a + n(o.company_net_cents), 0))}**`]]
      : [['No owner this month', '', '', '', '', '']] });
  for (const o of os) {
    blocks.push({ t: 'h2', text: s(o.owner_name) });
    const rows = MONEY_COLS.filter((k) => n(o[k]) !== 0).map((k) => [nice(k), dollars(o[k])] as [string, string]);
    blocks.push({ t: 'table', head: ['Line', 'Amount'], kv: true, rows: rows.length ? rows : [['Nothing this month', dollars(0)]] });
  }
  return blocks;
}
function companyVehicles(f: F): Block[] {
  const vs = (f.vehicles ?? []) as Row[];
  const blocks = companyHead(f, [['Vehicles', s(vs.length)]]);
  for (const v of vs) {
    blocks.push({ t: 'h2', text: `${s(v.vehicle_name)}${v.plate ? `, ${s(v.plate)}` : ''}` });
    blocks.push({ t: 'table', head: ['Fleet', 'Value'], kv: true, rows: [
      ['Owner', s(v.owner_name)], ['Mode', label(v.management_mode)], ['Days in the program', s(n(v.days_in_program))], ['Days available', s(n(v.days_available))],
      ['Days rented', s(n(v.days_rented))], ['Utilization', pct(v.utilization_bps)], ['Rentals ended', s(n(v.rentals_ended))],
      ['Average daily rate', dollars(v.avg_daily_rate_cents)], ['Revenue per available day', dollars(v.revpad_cents)]] });
    const rows = MONEY_COLS.filter((k) => n(v[k]) !== 0).map((k) => [k === 'company_net_cents' ? '**Contribution from this vehicle**' : nice(k), k === 'company_net_cents' ? `**${dollars(v[k])}**` : dollars(v[k])] as [string, string]);
    blocks.push({ t: 'table', head: ['Money', 'Amount'], kv: true, rows: rows.length ? rows : [['Nothing this month', dollars(0)]] });
  }
  if (!vs.length) blocks.push({ t: 'p', text: 'No vehicle this month.' });
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
    case 'company_statement': return companyStatement(f);
    case 'company_owners': return companyOwners(f);
    case 'company_vehicles': return companyVehicles(f);
    case 'owner_invoice': return ownerInvoice(f);
    case 'terms_notice': return termsNotice(f);
    case 'pay_statement': return payStatement(f);
  }
}

export async function renderDocument(kind: DocKind, facts: Record<string, unknown>, logo: Uint8Array | null = null): Promise<Uint8Array> {
  const f = facts as F;
  const stamp = String(f.issued_at ?? f.paid_at ?? f.sent_at ?? f.created_at ?? f.statement_month ?? f.return_month ?? `${s(f.year)}-12-31`);
  const created = new Date(/^\d{4}-\d{2}-\d{2}$/.test(stamp) ? `${stamp}T12:00:00Z` : stamp);
  return agreementPdf(documentBlocks(kind, f), {
    title: f.title, createdAt: Number.isNaN(created.getTime()) ? new Date(0) : created, brand: true, logo,
    footer: `${f.company.brand}. ${f.title}.${f.final && !f.draft ? '' : f.draft ? ' Draft: this statement can still change until it is finalized.' : ' Preview: this record can still change.'}`
  });
}
