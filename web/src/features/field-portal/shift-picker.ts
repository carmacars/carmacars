// The shift picker (r35 part SP, migration 1770): the availability grid, standing weekly shifts, the minimum, and the week view of
// My shifts. Pure and without imports, so the unit tests run it as is (shift-picker.test.ts).

export const WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'] as const;
export const WEEKDAYS_SHORT = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'] as const;
/** The parts of the day of the grid, as the database counts them (app.fx_parts): Toronto hours. */
export const PARTS = [
  { key: 'am', label: 'Morning', short: 'AM', hours: '6 AM to 12 PM' },
  { key: 'pm', label: 'Afternoon', short: 'PM', hours: '12 to 5 PM' },
  { key: 'eve', label: 'Evening', short: 'Eve', hours: '5 to 11 PM' },
] as const;
export type PartKey = typeof PARTS[number]['key'];
/** One cell: ISO weekday (1 Monday .. 7 Sunday) and part, as stored ("6:am"). */
export const cell = (dow: number, part: PartKey) => `${dow}:${part}`;
export const ALL_CELLS: string[] = [1, 2, 3, 4, 5, 6, 7].flatMap((d) => PARTS.map((p) => cell(d, p.key)));

export interface Availability { slots: string[]; note: string | null; updated_at?: string | null; required?: boolean; set?: boolean }
export interface Standing { id: string; weekday: number; start: string; end: string; words: string; note: string | null;
  next: Array<{ day: string; state: 'claimed' | 'skipped' | 'waiting' | 'no_slot' }> }
export interface Rules { min: number; ahead: number; claimed: number; standing_ahead?: number }

/** Toggle one cell; the result is kept in grid order. */
export function toggleCell(slots: string[], c: string): string[] {
  const on = new Set(slots);
  if (on.has(c)) on.delete(c); else on.add(c);
  return ALL_CELLS.filter((x) => on.has(x));
}
/** Toggle a whole row (a weekday) or column (a part): all on unless all are on already. */
export function toggleMany(slots: string[], cells: string[]): string[] {
  const on = new Set(slots);
  const all = cells.every((x) => on.has(x));
  for (const x of cells) { if (all) on.delete(x); else on.add(x); }
  return ALL_CELLS.filter((x) => on.has(x));
}
export const dayCells = (dow: number) => PARTS.map((p) => cell(dow, p.key));
export const partCells = (part: PartKey) => [1, 2, 3, 4, 5, 6, 7].map((d) => cell(d, part));

/** "Weekday mornings, Sat and Sun all day": the grid in a few words for the board and the profile. */
export function availabilityWords(slots: string[] | null | undefined): string {
  if (!slots?.length) return 'Not given';
  if (slots.length === ALL_CELLS.length) return 'Any time';
  const on = new Set(slots);
  const parts: string[] = [];
  const byDay = [1, 2, 3, 4, 5, 6, 7].map((d) => PARTS.filter((p) => on.has(cell(d, p.key))).map((p) => p.key).join('+'));
  // group the days with the same parts
  const groups = new Map<string, number[]>();
  byDay.forEach((k, i) => { if (k) groups.set(k, [...(groups.get(k) ?? []), i + 1]); });
  for (const [k, days] of groups) {
    const when = k === 'am+pm+eve' ? 'all day' : k.split('+').map((x) => PARTS.find((p) => p.key === x)!.label.toLowerCase()).join(' and ');
    parts.push(`${dayRange(days)} ${when}`);
  }
  return parts.join('; ');
}
/** [1,2,3,4,5] "Mon to Fri"; [6,7] "Sat, Sun"; [1,3] "Mon, Wed". */
export function dayRange(days: number[]): string {
  if (days.length === 7) return 'Every day';
  if (days.length >= 3 && days.every((d, i) => i === 0 || d === days[i - 1]! + 1)) return `${WEEKDAYS_SHORT[days[0]! - 1]} to ${WEEKDAYS_SHORT[days[days.length - 1]! - 1]}`;
  return days.map((d) => WEEKDAYS_SHORT[d - 1]).join(', ');
}

/** The half hours a standing shift may start or end at, as [value, label]. */
export function halfHours(from = 5, to = 24): Array<[string, string]> {
  const out: Array<[string, string]> = [];
  for (let m = from * 60; m <= to * 60 - 30; m += 30) {
    const h = Math.floor(m / 60), mm = m % 60;
    out.push([`${String(h).padStart(2, '0')}:${String(mm).padStart(2, '0')}`, timeWords(h, mm)]);
  }
  return out;
}
export function timeWords(h: number, m: number): string {
  const ap = h < 12 || h === 24 ? 'AM' : 'PM';
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}:${String(m).padStart(2, '0')} ${ap}`;
}

/** The minimum in words: "2 of 2 shifts claimed for the next 7 days" and whether it is met. */
export function minimumWords(r: Rules | null | undefined): { text: string; met: boolean; off: boolean } {
  if (!r || r.min <= 0) return { text: 'No minimum is set.', met: true, off: true };
  const met = r.claimed >= r.min;
  return { text: `${r.claimed} of ${r.min} shift${r.min === 1 ? '' : 's'} claimed for the next ${r.ahead} days`, met, off: false };
}

// ---------------------------------------------------------------- the week view
const tz = 'America/Toronto';
const ymd = new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' });
/** The Toronto calendar day of an instant, YYYY-MM-DD. */
export const torontoDay = (iso: string | number | Date) => ymd.format(new Date(iso));
/** Days after a YYYY-MM-DD (calendar arithmetic at noon UTC, so no zone shifts the date). */
export function addDays(day: string, n: number): string {
  const d = new Date(`${day}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
/** ISO weekday of a YYYY-MM-DD: 1 Monday .. 7 Sunday. */
export function isoDow(day: string): number { const w = new Date(`${day}T12:00:00Z`).getUTCDay(); return w === 0 ? 7 : w; }

export type WeekKind = 'mine' | 'open' | 'offer' | 'swap';
export interface WeekItem { kind: WeekKind; id: string; starts_at: string; ends_at: string; fits?: boolean; standing?: boolean; label?: string }
export interface WeekDay { day: string; dow: number; today: boolean; items: WeekItem[] }

/** Seven days from today + 7 * offset, each with its items in time order (mine first at the same time). */
export function buildWeek(items: WeekItem[], now: number, offset = 0): WeekDay[] {
  const start = addDays(torontoDay(now), offset * 7);
  const today = torontoDay(now);
  const order: Record<WeekKind, number> = { mine: 0, swap: 1, offer: 2, open: 3 };
  return Array.from({ length: 7 }, (_, i) => {
    const day = addDays(start, i);
    const its = items.filter((x) => torontoDay(x.starts_at) === day)
      .sort((a, b) => a.starts_at.localeCompare(b.starts_at) || order[a.kind] - order[b.kind]);
    return { day, dow: isoDow(day), today: day === today, items: its };
  });
}
