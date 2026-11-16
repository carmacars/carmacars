// r48 part 2 (3053): tips in words, for staff (the Money tab, My sales) and the renter (the tip chooser). Pure: tips.test.ts.
export interface TipShare { staff_id: string | null; name: string; role: string; amount_cents: number }
export interface TipRow { id: string; amount_cents: number; method: string; source: string; status: string; paid_at: string | null; reference: string | null; split_by_admin: boolean; shares: TipShare[] | null }
export interface TipOptions { on: boolean; base_cents: number; options: Array<{ percent_bps: number; cents: number }>; paid: Array<{ id: string; amount_cents: number; method: string; paid_at: string }>; paid_cents: number }

const ROLE: Record<string, string> = { sales: 'the salesperson', handover: 'the handover', both: 'sold it and did the handover', company: 'CarmaCars', override: 'set by an Admin' };

/** "Ana Sales $5.01 (the salesperson), CarmaCars $5.00" */
export function tipShareWords(shares: TipShare[], fmt: (c: number) => string): string {
  if (!shares.length) return 'not split yet';
  return shares.map((s) => (s.staff_id ? `${s.name} ${fmt(s.amount_cents)} (${ROLE[s.role] ?? s.role})` : `CarmaCars ${fmt(s.amount_cents)}`)).join(', ');
}

/** The amount in cents of what the renter chose: a suggestion's percent, or what they typed (null: nothing valid). */
export function tipChoiceCents(o: Pick<TipOptions, 'options'>, choice: string, typed: string): number | null {
  if (choice === 'custom') {
    const t = typed.replace(/[$,\s]/g, '');
    const c = t && /^\d+(\.\d{1,2})?$/.test(t) ? Math.round(Number(t) * 100) : null;
    return c && c >= 100 ? c : null;
  }
  return o.options.find((x) => String(x.percent_bps) === choice)?.cents ?? null;
}

export const pctLabel = (bps: number) => `${bps % 100 ? (bps / 100).toFixed(1) : bps / 100}%`;
