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
  if (kind === 'date') return isDay(t) ? t : '';
  if (kind === 'time') return isTime(t) ? t : '';
  const { day, time } = splitLocal(t);
  return isDay(day) && isTime(time) ? t.slice(0, 16) : '';
}
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
