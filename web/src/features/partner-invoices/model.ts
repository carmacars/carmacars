// Invoices to partners (migration 0547): the words and the line arithmetic the builder shows before saving (the database
// computes the same and is what counts). Pure: the builder and the unit test share it.
export const KINDS: ReadonlyArray<readonly [string, string]> = [['repair', 'Repair (claim)'], ['towing', 'Towing'], ['storage', 'Storage'], ['other', 'Other']];
export const DEFAULT_LINE: Record<string, string> = { repair: 'Outsourced repair services', towing: 'Outsourced towing services', storage: 'Outsourced storage services', other: 'Outsourced services' };
export const STATE_WORDS: Record<string, string> = { draft: 'Draft', sent: 'Sent', partly_paid: 'Partly paid', paid: 'Paid', overdue: 'Overdue', void: 'Void' };
export const METHODS: ReadonlyArray<readonly [string, string]> = [['cheque', 'Cheque'], ['e_transfer', 'e-Transfer'], ['cash', 'Cash']];

export interface DraftLine { description: string; quantity: string; unit: string; percent: string; base: string; hst: boolean }
const cents = (s: string) => { const t = s.replace(/[$,\s]/g, ''); return t ? Math.round(Number(t) * 100) : 0; };

/** A line's amount and HST in cents, as the database computes them (a percentage of a base, or quantity x unit). */
export function lineCents(l: DraftLine, hstBps = 1300): { amount: number; hst: number } {
  const pct = l.percent.trim() ? Number(l.percent) : null;
  const amount = pct !== null && Number.isFinite(pct) ? Math.round((cents(l.base) * Math.round(pct * 100)) / 10000) : Math.round((Number(l.quantity) || 0) * cents(l.unit));
  return { amount, hst: l.hst ? Math.round((amount * hstBps) / 10000) : 0 };
}
export function totals(lines: DraftLine[], hstBps = 1300) {
  const each = lines.map((l) => lineCents(l, hstBps));
  const subtotal = each.reduce((t, x) => t + x.amount, 0); const hst = each.reduce((t, x) => t + x.hst, 0);
  return { subtotal, hst, total: subtotal + hst };
}
/** The line as the database takes it. */
export function linePayload(l: DraftLine) {
  const pct = l.percent.trim();
  return { description: l.description, quantity: l.quantity || '1', unit_cents: cents(l.unit), percent_bps: pct ? Math.round(Number(pct) * 100) : null, base_cents: pct ? cents(l.base) : null, hst: l.hst };
}
