// Release 44 (2792): the dates and filters of the availability view, from the page's address. No imports, so the unit
// tests run it as it is (availability.test.ts). Times are Toronto's: the database reads "YYYY-MM-DD HH:MM America/Toronto".
const LOCAL = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/;
const AVAIL_CLASS = /^(economy|standard|premium|suv|luxury|exotic)$/;

function torontoDay(now: Date, plusDays: number): string {
  const d = new Date(now.getTime() + plusDays * 86_400_000);
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
}

/** The pickup and the return shown (YYYY-MM-DDTHH:MM, Toronto): the address's, or tomorrow 10:00 for 3 days. */
export function availRange(sp: Record<string, string | undefined>, now = new Date()): { af: string; at: string } {
  const af = sp.af && LOCAL.test(sp.af) ? sp.af : `${torontoDay(now, 1)}T10:00`;
  const at = sp.at && LOCAL.test(sp.at) && sp.at > af ? sp.at : `${torontoDay(new Date(`${af.slice(0, 10)}T12:00:00Z`), 3)}T${af.slice(11)}`;
  return { af, at };
}

/** What the database is asked (va_read / admin_read fleet_availability). */
export function availQuery(sp: Record<string, string | undefined>, now = new Date()): Record<string, string | number> {
  const { af, at } = availRange(sp, now);
  const q: Record<string, string | number> = { from: `${af.replace('T', ' ')} America/Toronto`, to: `${at.replace('T', ' ')} America/Toronto` };
  if (sp.ac && AVAIL_CLASS.test(sp.ac)) q.class = sp.ac;
  if (sp.as && /^\d{1,2}$/.test(sp.as)) q.seats_min = Number(sp.as);
  if (sp.ap && /^\d{1,7}$/.test(sp.ap)) q.max_daily_rate_cents = Number(sp.ap);
  return q;
}
