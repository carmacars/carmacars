// The shared date fields (Release 27): what a typed or picked value looks like, as the form keeps it. No imports; unit tested.

export type DateKind = 'date' | 'datetime-local' | 'time';
const D = /^(\d{4})-(\d{2})-(\d{2})$/, T = /^([01]\d|2[0-3]):([0-5]\d)$/;
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** A real calendar day written YYYY-MM-DD (Feb 30 is not one). */
export function isDay(s: string): boolean {
  const m = D.exec(s);
  if (!m) return false;
  const d = new Date(Date.UTC(+m[1]!, +m[2]! - 1, +m[3]!));
  return d.getUTCFullYear() === +m[1]! && d.getUTCMonth() === +m[2]! - 1 && d.getUTCDate() === +m[3]!;
}
export const isTime = (s: string) => T.test(s);
/** The day and time of "2026-11-07T14:30" (the time empty for a plain day). */
export function splitLocal(v: string): { day: string; time: string } {
  const [day = '', time = ''] = v.split('T');
  return { day, time: time.slice(0, 5) };
}
export const joinLocal = (day: string, time: string) => (day ? `${day}T${time || '09:00'}` : '');
/** What a typed value is worth for this kind: the value to keep, or '' when it is not one (a partial typing). */
export function normalize(kind: DateKind, text: string): string {
  const t = text.trim().replace(' ', 'T');
  if (kind === 'date') { const m = maskDay(t); return isDay(m) ? m : ''; }
  if (kind === 'time') return isTime(t) ? t : '';
  const { day, time } = splitLocal(t);
  return isDay(day) && isTime(time) ? t.slice(0, 16) : '';
}
/** A day as it is typed (hotfix-date): a phone's number pad has no dash, so the digits get them as they come ("20270115" and
 *  "2027/01/15" read 2027-01-15). Anything else (letters, a day written 15/01/2027) is left as typed. */
export function maskDay(text: string): string {
  const t = text.trim();
  if (!/^\d{4}[\d\-/. ]*$/.test(t)) return t;
  const parts = t.split(/[-/. ]/);
  if (parts.length > 3 || (parts.length > 1 && parts[0]!.length !== 4)) return t;
  // a month or day the typing already ended with a separator ("2027-1-") is one digit: 01
  const d = parts.map((x, i) => (i > 0 && i < parts.length - 1 && x.length === 1 ? `0${x}` : x)).join('');
  if (d.length > 8) return t;
  return d.slice(0, 4) + (d.length > 4 ? `-${d.slice(4, 6)}` : '') + (d.length > 6 ? `-${d.slice(6, 8)}` : '');
}
/** The same day n years on (Feb 29 becomes Feb 28). */
export function addYears(day: string, n: number): string {
  const [y = 0, m = 1, d = 1] = day.split('-').map(Number);
  const last = new Date(Date.UTC(y + n, m, 0)).getUTCDate();
  return `${y + n}-${String(m).padStart(2, '0')}-${String(Math.min(d, last)).padStart(2, '0')}`;
}
/** An expiry date's range (hotfix-date): from today (or a later first day, such as the day after a return) to `years` on. */
export function expiryRange(today: string, years: number, from?: string): { min: string; max: string } {
  const min = from && from > today ? from : today;
  const far = addYears(today, years);
  return { min, max: far > min ? far : addYears(min, 1) };
}
/** The month the popover's calendar opens on: the value's, else today's kept inside [min, max]. */
export const openDay = (value: string, today: string, min?: string, max?: string) => (isDay(value) ? value : clampDay(today, min, max));
/** "Nov 7, 2026" and "Nov 7, 2026, 2:30 p.m." for the field when it is not being typed in. */
export function pretty(kind: DateKind, v: string): string {
  const { day, time } = splitLocal(v);
  if (kind === 'time') return isTime(v) ? clock12(v) : '';
  if (!isDay(day)) return '';
  const m = D.exec(day)!, base = `${MON[+m[2]! - 1]} ${+m[3]!}, ${m[1]}`;
  return kind === 'datetime-local' && isTime(time) ? `${base}, ${clock12(time)}` : base;
}
export function clock12(t: string): string {
  const [h = 0, m = 0] = t.split(':').map(Number);
  return `${((h + 11) % 12) + 1}:${String(m).padStart(2, '0')} ${h < 12 ? 'a.m.' : 'p.m.'}`;
}
/** The times of a day every `step` minutes ("00:00" to "23:45" for 15); a value that is off the grid is kept in the list. */
export function timeOptions(step = 15, current = ''): string[] {
  const out = Array.from({ length: Math.floor(1440 / step) }, (_, i) => `${String(Math.floor((i * step) / 60)).padStart(2, '0')}:${String((i * step) % 60).padStart(2, '0')}`);
  if (isTime(current) && !out.includes(current)) { out.push(current); out.sort(); }
  return out;
}
/** The first day of a range for the popover's calendar, the clamp of a value into [min, max]. */
export const clampDay = (day: string, min?: string, max?: string) => (min && day < min ? min : max && day > max ? max : day);
