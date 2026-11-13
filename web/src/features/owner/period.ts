// Owner statement periods (1155): a statement covers the revenue earned through the cutoff day (the 7th) of the month its payout
// is paid in (the 10th); the first one from the earliest booking. Pure, for the pages and the tests.
const fmt = (iso: string, year: boolean) => new Intl.DateTimeFormat('en-CA', { month: 'short', day: 'numeric', ...(year ? { year: 'numeric' } : {}), timeZone: 'UTC' })
  .format(new Date(`${iso.slice(0, 10)}T12:00:00Z`)).replace('.', '');

/** "Oct 20 to Nov 7, 2026" from a statement's period; its month ("October 2026") when the period is not set. */
export function periodOf(s: { statement_month?: string | null; period_starts_on?: string | null; period_ends_on?: string | null }): string {
  if (s.period_ends_on) {
    const end = fmt(s.period_ends_on, true);
    if (!s.period_starts_on) return `Through ${end}`;
    const sameYear = s.period_starts_on.slice(0, 4) === s.period_ends_on.slice(0, 4);
    return `${fmt(s.period_starts_on, !sameYear)} to ${end}`;
  }
  return s.statement_month ? new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${s.statement_month.slice(0, 10)}T12:00:00Z`)) : '';
}

const addDays = (iso: string, n: number) => { const d = new Date(`${iso.slice(0, 10)}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const lessMonth = (iso: string) => { const [y, m, d] = iso.slice(0, 10).split('-').map(Number) as [number, number, number]; const last = new Date(Date.UTC(y, m - 1, 0)).getUTCDate();
  return new Date(Date.UTC(y, m - 2, Math.min(d, last), 12)).toISOString().slice(0, 10); };

/** r44 (2783): a statement shorter than a full period (a car's first statement, usually): it starts after the day following
 *  the cutoff of the month before. The same rule as app.owner_statement_partial; the database's answer wins when it is given. */
export function partialMonth(s: { period_starts_on?: string | null; period_ends_on?: string | null; partial_month?: boolean | null }): boolean {
  if (typeof s.partial_month === 'boolean') return s.partial_month;
  if (!s.period_starts_on || !s.period_ends_on) return false;
  return s.period_starts_on.slice(0, 10) > addDays(lessMonth(s.period_ends_on), 1);
}

/** The notice a partial-month statement shows on its page, in the owner portal and on the PDF; null for a full period. */
export function partialMonthNotice(s: { statement_month?: string | null; period_starts_on?: string | null; period_ends_on?: string | null; partial_month?: boolean | null }): string | null {
  return partialMonth(s) ? `This statement covers a partial month (${periodOf(s)}), not a full month.` : null;
}
