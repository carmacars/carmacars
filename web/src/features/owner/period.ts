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
