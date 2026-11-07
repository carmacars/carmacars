// Kickbacks and repair costs in the profit numbers (release 29, C2; migration 0581). Pure: the views, the CSV route
// and the unit tests share it.
export type Level = 'business' | 'owner' | 'vehicle';
export interface Line { line: string; kind: 'revenue' | 'cost' | 'memo'; cents: number }
export interface Kickback { on_date: string; vehicle_id: string | null; car: string | null; line: string; cents: number; invoice_id?: string; invoice_number?: string | null; partner?: string; claim_id?: string | null }
export interface Repair { id: string; on_date: string; vehicle_id: string; car: string; vendor: string; description: string; cents: number; tax_cents: number; paid_by: PaidBy; claim_number: string | null; claim_id?: string | null; receipt?: string | null }
export type PaidBy = 'company' | 'owner' | 'insurer';
export interface Extras {
  level: Level; id: string | null; from: string; to: string; lines: Line[]; kickback_cents: number; repair_cents: number; net_cents: number; unassigned_kickback_cents?: number | null;
  by_car: Array<{ vehicle_id: string; name: string; body_shop_cents: number; tow_cents: number; storage_cents: number; other_cents: number; repair_cents: number }>;
  by_owner?: Array<{ owner_id: string; name: string; kickback_cents: number; repair_cents: number }> | null;
  kickbacks: Kickback[]; repairs: Repair[];
  show_to_owner?: boolean | null; partners?: Array<{ id: string; name: string }>; claims?: Array<{ id: string; claim_number: string }> | null; cars?: Array<{ id: string; name: string }> | null;
  visible?: boolean;
}
export const PAID_BY: Array<[PaidBy, string]> = [['company', 'CarmaCars'], ['owner', 'The owner'], ['insurer', 'The insurer']];
export const paidByLabel = (p: string) => PAID_BY.find(([k]) => k === p)?.[1] ?? p;

/** The period of a page's ?from=&to= (YYYY-MM-DD), or null for the database's default (this year to today). */
export function period(sp: Record<string, string | undefined>): { from: string | null; to: string | null } {
  const ok = (s?: string) => (s && /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : null);
  return { from: ok(sp.from), to: ok(sp.to) };
}

const cell = (v: unknown) => { const t = String(v ?? ''); return /[",\n\r]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t; };
const money = (c: number | null | undefined) => (Number(c ?? 0) / 100).toFixed(2);
/** The CSV of one view: the lines, then every kickback and repair cost row. */
export function toCsv(x: Extras): string {
  const rows: unknown[][] = [['Section', 'Date', 'Car', 'Line or vendor', 'Description', 'Amount', 'Tax', 'Paid by', 'Invoice', 'Partner', 'Claim']];
  for (const l of x.lines) rows.push(['Total', `${x.from} to ${x.to}`, '', l.line, l.kind, money(l.cents), '', '', '', '', '']);
  rows.push(['Total', `${x.from} to ${x.to}`, '', 'Net (kickbacks less repair costs)', '', money(x.net_cents), '', '', '', '', '']);
  for (const k of x.kickbacks) rows.push(['Kickback', k.on_date, k.car ?? '(no car)', k.line, '', money(k.cents), '', '', k.invoice_number ?? '', k.partner ?? '', '']);
  for (const r of x.repairs) rows.push(['Repair cost', r.on_date, r.car, r.vendor, r.description, money(r.cents), money(r.tax_cents), paidByLabel(r.paid_by), '', '', r.claim_number ?? '']);
  return rows.map((r) => r.map(cell).join(',')).join('\r\n') + '\r\n';
}
