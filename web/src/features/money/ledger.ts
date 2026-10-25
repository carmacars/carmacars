// The Payments view (0151): the shape app.payments_ledger returns, the filters read from the address, and the CSV.
export const CHANNELS = ['card', 'e_transfer', 'cash', 'cheque', 'platform_payout', 'insurer', 'bank_transfer', 'pre_authorized_debit', 'other'] as const;
export type Channel = typeof CHANNELS[number];
export const CHANNEL_LABEL: Record<Channel, string> = {
  card: 'Card', e_transfer: 'e-Transfer', cash: 'Cash', cheque: 'Cheque', platform_payout: 'Platform payout', insurer: 'Insurer',
  bank_transfer: 'Bank transfer', pre_authorized_debit: 'Pre-authorized debit', other: 'Other'
};

export interface LedgerRow {
  id: string; day: string; at: string; channel: Channel; channel_label: string; kind: string; direction: 'in' | 'out' | 'held';
  what: string; how: string; reference: string | null; amount_cents: number; status: string;
  booking_number: string | null; who: string | null; recorded_by: string | null;
}
export interface MethodTotal { in: number; out: number; count: number }
export interface LedgerDay {
  day: string; by_method: Partial<Record<Channel, MethodTotal>>; in_cents: number; out_cents: number;
  cash_expected_cents: number; cash_counted_cents: number | null; cash_counted_by: string | null; cash_note: string | null; cash_difference_cents: number | null;
}
export interface RefundItem {
  id: string; booking_number: string; who: string | null; reason: string; reason_label: string; amount_cents: number; refund_bps: number | null;
  status: string; created_at: string; due_by: string | null; note: string | null; requested_by: string | null; method: string;
  maths: { paid_cents: number | null; tier?: string; refund_bps: number | null; refund_cents: number; kept_cents?: number; deposit_returned_cents?: number; matches?: boolean };
  can_approve: boolean; can_decline: boolean; can_issue: boolean;
}
export interface Ledger { from: string; to: string; methods: Channel[]; admin: boolean; rows: LedgerRow[]; days: LedgerDay[]; totals: Partial<Record<Channel, MethodTotal>>; refunds: RefundItem[] }

const ymd = (s: string | undefined | null) => (s && /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : null);

/** The filters from the address: from, to (local dates) and method (one or more, comma separated or repeated). */
export function ledgerFilters(sp: Record<string, string | string[] | undefined>, today: string): { from: string; to: string; methods: Channel[] } {
  const from = ymd(String(sp.from ?? '')) ?? today;
  const to = ymd(String(sp.to ?? '')) ?? from;
  const raw = ([] as string[]).concat(sp.method ?? []).flatMap((m) => String(m).split(','));
  const methods = CHANNELS.filter((c) => raw.includes(c));
  return to < from ? { from: to, to: from, methods } : { from, to, methods };
}

/** Today in Toronto as YYYY-MM-DD. */
export function torontoToday(now = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(now);
}

const cell = (v: unknown) => {
  const s = v === null || v === undefined ? '' : String(v);
  // a spreadsheet never runs a cell as a formula
  const safe = /^[=+\-@\t\r]/.test(s) ? `'${s}` : s;
  return /[",\n\r]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
};
const dollars = (c: number) => (c / 100).toFixed(2);

/** The rows as CSV: one line per payment, refunds as negative amounts, holds marked (not money in). */
export function ledgerCsv(rows: LedgerRow[]): string {
  const head = ['Date', 'Time', 'Method', 'What', 'How', 'Reference', 'Booking', 'From or to', 'Amount', 'Status', 'Recorded by'];
  const lines = rows.map((r) => {
    const t = new Date(r.at);
    const time = Number.isNaN(t.getTime()) ? '' : new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: '2-digit', minute: '2-digit', hour12: false }).format(t);
    const amount = r.direction === 'out' ? -r.amount_cents : r.amount_cents;
    const text = (v: unknown[]) => v.map(cell);
    // the amount is a number (a refund negative): written as it is, never guarded as text
    return [...text([r.day, time, r.channel_label, r.what, r.how, r.reference, r.booking_number, r.who]), dollars(amount), ...text([r.direction === 'held' ? 'Held (not money in)' : r.status, r.recorded_by])].join(',');
  });
  return [head.join(','), ...lines].join('\r\n') + '\r\n';
}

/** What the refund policy gave, in one sentence. */
export function refundMaths(r: RefundItem): string {
  const m = r.maths;
  const $ = (c: number | null | undefined) => (c === null || c === undefined ? '' : new Intl.NumberFormat('en-CA', { style: 'currency', currency: 'CAD' }).format(c / 100));
  const pct = (bps: number | null | undefined) => (bps === null || bps === undefined ? '' : `${bps / 100}%`);
  if (m.tier !== undefined) {
    return `Paid ${$(m.paid_cents)} · ${m.tier.replace(/_/g, ' ')}: ${pct(m.refund_bps)} back = ${$(m.refund_cents)}, kept ${$(m.kept_cents)}${m.deposit_returned_cents ? ` · deposit returned ${$(m.deposit_returned_cents)}` : ''}${m.matches === false ? ' · the amount asked differs from the policy' : ''}`;
  }
  return `${m.paid_cents ? `Paid ${$(m.paid_cents)} · ` : ''}${m.refund_bps !== null && m.refund_bps !== undefined ? `${pct(m.refund_bps)} back = ` : ''}${$(m.refund_cents)}`;
}

/** Friendly words for the codes the payment rows carry (raw codes never reach a staff screen). */
export const PURPOSE_LABEL: Record<string, string> = {
  booking_total: 'Rental', deposit: 'Deposit', extension: 'Extension', post_rental: 'Charges after the rental', toll_ticket: 'Toll or ticket', damage: 'Damage',
  deductible: 'Deductible', owner_upfront: 'Owner upfront invoice', owner_fees: 'Owner fees', other: 'Other'
};
export const KIND_LABEL: Record<string, string> = { charge: 'Payment', hold: 'Card hold', capture: 'Hold taken', release: 'Hold released', refund: 'Refund', payout: 'Payout', fee: 'Processor fee', adjustment: 'Adjustment' };
export const METHOD_LABEL: Record<string, string> = { ...CHANNEL_LABEL };
export const STATUS_LABEL: Record<string, string> = { succeeded: 'Received', pending: 'Pending', requires_action: 'Waiting for the renter', authorized: 'Held', failed: 'Failed', cancelled: 'Cancelled' };
export const friendly = (map: Record<string, string>, v: unknown) => (typeof v === 'string' ? map[v] ?? v.replace(/_/g, ' ') : '');
export function cardLabel(brand: unknown, last4: unknown): string {
  if (!last4) return '';
  const b = typeof brand === 'string' && brand ? brand.charAt(0).toUpperCase() + brand.slice(1) : 'Card';
  return `${b} ending ${String(last4)}`;
}
