// Owner invoices and terms (migration 0067): labels and money input shared by the admin screens and the owner portal.
// Money is integer cents; the database computes every amount again.
export const INVOICE_STATUS: Record<string, string> = {
  draft: 'Draft', issued: 'Issued', processing: 'Processing', paid: 'Paid', failed: 'Failed', retry_processing: 'Retrying',
  in_arrears: 'In arrears', partially_deducted: 'Partly deducted', deducted: 'Deducted from payout', void: 'Void'
};
export const INVOICE_BADGE: Record<string, string> = { draft: 'draft', issued: 'sent', processing: 'sent', paid: 'paid', failed: 'failed', in_arrears: 'failed', void: 'cancelled' };
/** 0204: an invoice taken from the owner's revenue statement. */
const FROM_STATEMENT: Record<string, string> = { issued: 'From next statement', partially_deducted: 'Part paid from statement', deducted: 'Paid from statement' };
export const statusText = (status: string, partly?: boolean, fromStatement?: boolean) => (fromStatement && FROM_STATEMENT[status] ? FROM_STATEMENT[status]!
  : partly ? 'Partly paid' : INVOICE_STATUS[status] ?? status.replace(/_/g, ' '));
export const KIND_LABEL: Record<string, string> = { upfront: 'First and last month', monthly: 'Monthly fees', tracker_install: 'Tracker install', custom: 'Invoice', credit_note: 'Credit note', adjustment: 'Adjustment' };
export const SOURCE_LABEL: Record<string, string> = { car: 'set for this car', owner: 'the owner\'s terms', other_car: 'from their other car', standard: 'standard grid', mode: 'set by the management mode', two_months: '2 x the Insurance Fee' };

/** "123.45" or "$1,234.5" to cents; NaN when it is not an amount. */
export function toCents(v: string): number {
  const s = String(v ?? '').replace(/[$,\s]/g, '');
  if (!/^-?\d+(\.\d{0,2})?$/.test(s)) return Number.NaN;
  return Math.round(Number(s) * 100);
}
export const dollars = (c: number | null | undefined) => (c === null || c === undefined || Number.isNaN(c) ? '' : (c / 100).toFixed(2));
export const pctOf = (bps: number | null | undefined) => (bps === null || bps === undefined ? '' : String(+(bps / 100).toFixed(2)));
export const hstOf = (cents: number, bps: number) => Math.round((cents * bps) / 10000);
