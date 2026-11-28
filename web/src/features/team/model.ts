// R51 (5302, REQ-131): a manager's team (ops_read my_team, team_member). Pure: the words of each fact. No imports.
export interface TeamPay { pay_lines_cents: number; commission_cents: number; held: boolean }
export interface TeamRow { id: string; name: string; status: string; functions: string[]; last_seen_at: string | null; minutes_7d: number;
  academy: { core_passed: number; core_total: number; passed: number; total: number }; pay: TeamPay; jobs_open: number; jobs_done_7d: number }
export interface TeamMember extends TeamRow {
  scorecard: unknown | null;
  jobs: Array<{ id: string; kind: string; status: string; at: string; done_at: string | null; booking: string | null; car: string | null }>;
  clock: Array<{ from: string; to: string | null; kind: 'clock' | 'shift' }>;
  activity: Array<{ at: string; action: string; what: string | null }>;
}

/** "12 h 30 min" from minutes. */
export function hoursWords(min: number): string {
  const m = Math.max(0, Math.round(min || 0));
  const h = Math.floor(m / 60), r = m % 60;
  return h ? (r ? `${h} h ${r} min` : `${h} h`) : `${r} min`;
}
/** "3 of 9 basics, 10 of 33 in all" (or "All passed"). */
export function academyWords(a: TeamRow['academy']): string {
  if (a.total > 0 && a.passed >= a.total) return 'All passed';
  return `${a.core_passed} of ${a.core_total} basics, ${a.passed} of ${a.total} in all`;
}
/** Pay owed in cents (pay lines not paid and commissions not paid). */
export const owedCents = (p: TeamPay): number => (Number(p.pay_lines_cents) || 0) + (Number(p.commission_cents) || 0);
/** An audit action in plain words: "booking update", "vehicle insert". */
export const actionWords = (action: string, what: string | null): string => `${(what ?? '').replace(/_/g, ' ')} ${action.replace(/_/g, ' ').toLowerCase()}`.trim();
