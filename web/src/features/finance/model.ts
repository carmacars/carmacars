// Release 49 (3480): what app.finance_dashboard and app.bank_lines_view return. Money is in cents.
export interface Dashboard {
  as_of: string; today: string; month: string; provider: string; unmatched_days: number;
  bank: {
    accounts: Array<{ id: string; nickname: string; last4: string; currency: string; provider: string; balance_cents: number | null; as_of: string | null; source: string | null; days_old: number | null; last_import_at: string | null }>;
    total_cad_cents: number;
    stripe_payouts_open: Array<{ ref: string; paid_on: string; amount_cents: number }>;
  };
  money_in: { month_rentals_cents: number; month_owner_fees_cents: number; month_insurers_cents: number; month_tips_cents: number };
  deposits: { cash_cents: number; holds_cents: number; held_back_cents: number; count: number; release_late: number };
  insurers: { total_cents: number; count: number; buckets: { d0_30: number; d31_60: number; d61_90: number; d90: number };
    rows: Array<{ id: string; invoice_number: string; insurer: string; booking_number: string; claim_number: string | null; total_cents: number; balance_cents: number; sent_on: string; days: number }> };
  renters_overdue: { total_cents: number; count: number; rows: Array<{ booking_number: string; renter: string; open_cents: number; since: string; days: number }> };
  money_out: {
    owner_payouts: { due_cents: number; due_count: number; next_on: string | null; paid_month_cents: number; failed_count: number };
    other_payouts_month_cents: number;
    commissions: { due_cents: number; accruing_cents: number; paid_month_cents: number; partners_paid_month_cents: number };
    expenses_month_cents: number;
    refunds: { paid_month_cents: number; owed_cents: number; owed_count: number };
  };
  hst: { from: string; to: string; collected_cents: number; collected: { renters: number; owners: number; insurers: number }; paid_cents: number;
    paid: { expenses: number; payouts: number }; owed_cents: number; insurance_with_hst: Array<{ invoice_number: string; hst_cents: number }> };
  pnl: Array<{ month: string; in_cents: number; refunds_cents: number; payouts_cents: number; commissions_cents: number; expenses_cents: number; net_cents: number; statement_net_cents: number | null }>;
  reconciliation: { total: number; matched: number; auto: number; ignored: number; unmatched: number; unmatched_in_cents: number; unmatched_out_cents: number; oldest_unmatched: string | null };
}

export interface Candidate { kind: string; table: string; id: string; label: string; amount_cents: number; on: string }
export interface BankLinesView {
  status: 'unmatched' | 'matched' | 'ignored' | 'all'; provider: string;
  accounts: Array<{ id: string; nickname: string; last4: string; currency: string; provider: string }>;
  counts: { unmatched: number; matched: number; ignored: number; all: number };
  imports: Array<{ id: string; account: string; source: string; file_name: string | null; lines_in: number; lines_new: number; lines_duplicate: number; lines_matched: number; first_on: string | null; last_on: string | null; created_at: string; by: string | null }>;
  rows: Array<{ id: string; posted_on: string; amount_cents: number; description: string; cheque_number: string | null; status: string; match_kind: string | null; matched_auto: boolean;
    note: string | null; account: string; last4: string; matched_label: string | null; candidates: Candidate[] }>;
}

export const MATCH_LABEL: Record<string, string> = {
  stripe_payout: 'Stripe payout', payment: 'Payment received', insurer_invoice: 'Insurer invoice', owner_payout: 'Payout', commission_payout: 'Commission payout',
  partner_payout: 'Referral partner payout', expense: 'Expense', refund: 'Refund'
};

/** The month before and after (YYYY-MM-01), for the month links. */
export function monthStep(m: string, by: number): string {
  const [y, mo] = m.split('-').map(Number) as [number, number];
  const d = new Date(Date.UTC(y, mo - 1 + by, 1));
  return d.toISOString().slice(0, 10);
}
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** "Nov 2026" */
export const monthName = (m: string) => `${MONTHS[Number(m.slice(5, 7)) - 1]} ${m.slice(0, 4)}`;

/** Free cash: what is in the bank and on its way from Stripe, less the money held for others (deposits taken as cash,
 *  owner payouts due, refunds owed and HST owed for the quarter). */
export function freeCash(d: Dashboard, stripe: { available_cents: number; pending_cents: number; in_transit_cents: number } | null): number {
  const s = stripe ? stripe.available_cents + stripe.pending_cents + stripe.in_transit_cents : 0;
  return d.bank.total_cad_cents + s - d.deposits.cash_cents - d.money_out.owner_payouts.due_cents - d.money_out.refunds.owed_cents - Math.max(0, d.hst.owed_cents);
}
