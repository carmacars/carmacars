// Times of day in Toronto, written the same way by the server and by every browser (r35). Intl's words for a time
// ("p.m.", "PM", a narrow no-break space or a plain one) change with the ICU version, so a page drawn by the Worker
// and taken over by a browser with another ICU did not match (React error 418 on Today > Visitors). Only Intl's
// numbers are used here (hour, minute, day, month as digits); the words are ours. No imports: unit tested in Node.
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const DAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
let fmt: Intl.DateTimeFormat | null = null;

export interface TorontoParts { year: number; month: number; day: number; hour: number; minute: number; second: number; weekday: number }

/** The Toronto calendar date and time of an instant, as numbers (month 1 to 12, weekday 0 Sunday). */
export function torontoAt(t: string | number | Date): TorontoParts | null {
  const d = t instanceof Date ? t : new Date(t);
  if (Number.isNaN(d.getTime())) return null;
  fmt ??= new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
  const n: Record<string, number> = {};
  for (const p of fmt.formatToParts(d)) if (p.type !== 'literal') n[p.type] = Number(p.value);
  const year = n.year ?? 1970, month = n.month ?? 1, day = n.day ?? 1;
  return { year, month, day, hour: (n.hour ?? 0) % 24, minute: n.minute ?? 0, second: n.second ?? 0, weekday: new Date(Date.UTC(year, month - 1, day)).getUTCDay() };
}

const two = (n: number) => String(n).padStart(2, '0');
const hm = (p: TorontoParts, seconds = false) => `${((p.hour + 11) % 12) + 1}:${two(p.minute)}${seconds ? `:${two(p.second)}` : ''} ${p.hour < 12 ? 'a.m.' : 'p.m.'}`;

/** "3:05 p.m." */
export function clockTo(t: string | number | Date): string { const p = torontoAt(t); return p ? hm(p) : ''; }
/** "3:05:09 p.m." */
export function clockSecondsTo(t: string | number | Date): string { const p = torontoAt(t); return p ? hm(p, true) : ''; }
/** "Nov 8, 3:05 p.m." */
export function dayClockTo(t: string | number | Date): string { const p = torontoAt(t); return p ? `${MON[p.month - 1]} ${p.day}, ${hm(p)}` : ''; }
/** "Sat 3:05 p.m." */
export function weekdayClockTo(t: string | number | Date): string { const p = torontoAt(t); return p ? `${DAY[p.weekday]} ${hm(p)}` : ''; }
/** "Sat Nov 8" */
export function weekdayDateTo(t: string | number | Date): string { const p = torontoAt(t); return p ? `${DAY[p.weekday]} ${MON[p.month - 1]} ${p.day}` : ''; }
