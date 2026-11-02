// Data health (migration 0441): the shape of the last run and the words the card uses.
export interface DataHealthItem { id: string | null; text: string; href: string | null; fix: { action: string; label: string } | null }
export interface DataHealthCheck { key: string; title: string; line: string; href: string | null; count: number; items: DataHealthItem[] }
export interface DataHealth { id?: string; ran_at: string | null; issues: number; checks: DataHealthCheck[]; fixed: Record<string, number>; fixed_week?: Record<string, number> }

/** The checks with something to look at, in the database's order (bookings and money first, car listings later), and the ones that are clear. */
export function splitChecks(checks: DataHealthCheck[]): { open: DataHealthCheck[]; clear: DataHealthCheck[] } {
  const open = checks.filter((c) => c.count > 0);
  return { open, clear: checks.filter((c) => c.count === 0) };
}

const FIXED: Array<[RegExp, string, string]> = [
  [/^test_/, 'test account taken off real work', 'test accounts taken off real work'],
  [/^duplicate_tasks$/, 'duplicate task closed', 'duplicate tasks closed'],
  [/^resolved_tasks$/, 'finished task closed', 'finished tasks closed']
];

/** What the auto-fix did, in words: "3 test accounts taken off real work, 2 duplicate tasks closed". Empty when nothing. */
export function fixedWords(fixed: Record<string, number> | null | undefined): string {
  const sums = FIXED.map(([re, one, many]) => {
    const n = Object.entries(fixed ?? {}).filter(([k]) => re.test(k)).reduce((s, [, v]) => s + (Number(v) || 0), 0);
    return n > 0 ? `${n} ${n === 1 ? one : many}` : '';
  }).filter(Boolean);
  return sums.join(', ');
}

/** "Checked 3:23 am" today, "Checked yesterday, 3:23 am", else the day; Toronto time. */
export function checkedWords(iso: string, now = new Date()): string {
  const at = new Date(iso);
  const day = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  const time = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' }).format(at).replace(/\./g, '').replace(/\s+/g, ' ');
  if (day(at) === day(now)) return `Checked ${time}`;
  if (day(at) === day(new Date(now.getTime() - 86400_000))) return `Checked yesterday, ${time}`;
  return `Checked ${new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric' }).format(at)}, ${time}`;
}
