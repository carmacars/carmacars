// Dates on the site are Toronto wall-clock dates and times (no time zone arithmetic in the browser
// beyond turning a Toronto date and time into an instant for the database).
export const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
export const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
export const TZ = 'America/Toronto';

export const parse = (iso: string) => { const [y, m, d] = iso.split('-').map(Number); return new Date(Date.UTC(y!, m! - 1, d!)); };
export const isoOf = (d: Date) => d.toISOString().slice(0, 10);
export const addDays = (iso: string, n: number) => { const d = parse(iso); d.setUTCDate(d.getUTCDate() + n); return isoOf(d); };
export const diffDays = (a: string, b: string) => Math.round((parse(b).getTime() - parse(a).getTime()) / 864e5);
export const dow = (iso: string) => parse(iso).getUTCDay();
export const validIso = (s: string | null | undefined): s is string => !!s && /^\d{4}-\d{2}-\d{2}$/.test(s) && !isNaN(parse(s).getTime());
export const shortDate = (iso: string) => { const d = parse(iso); return `${DAYS[d.getUTCDay()]!.slice(0, 3)}, ${MONTHS[d.getUTCMonth()]!.slice(0, 3)} ${d.getUTCDate()}`; };
export const longDate = (iso: string) => { const d = parse(iso); return `${DAYS[d.getUTCDay()]}, ${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}, ${d.getUTCFullYear()}`; };
export const clock = (t: string) => { const [h, m] = t.split(':').map(Number); return `${((h! + 11) % 12) + 1}:${String(m).padStart(2, '0')} ${h! < 12 ? 'a.m.' : 'p.m.'}`; };
export const validTime = (t: string | null | undefined): t is string => !!t && /^([01]\d|2[0-3]):[0-5]\d$/.test(t);

/** Today's date in Toronto. */
export function torontoToday(now = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(now);
}
/** Minutes since midnight in Toronto now. */
export function torontoMinutesNow(now = new Date()): number {
  const p = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(now);
  return Number(p.find((x) => x.type === 'hour')?.value) * 60 + Number(p.find((x) => x.type === 'minute')?.value);
}
/** The instant of a Toronto date and time, as an ISO string with its offset. */
export function torontoInstant(iso: string, time: string): string {
  const guess = new Date(`${iso}T${time}:00Z`);
  const offsetMin = (d: Date) => {
    const p = new Intl.DateTimeFormat('en-US', { timeZone: TZ, timeZoneName: 'longOffset' }).formatToParts(d).find((x) => x.type === 'timeZoneName')?.value ?? 'GMT-05:00';
    const m = p.match(/GMT([+-])(\d{2}):?(\d{2})?/);
    return m ? (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3] ?? 0)) : -300;
  };
  let off = offsetMin(guess);
  off = offsetMin(new Date(guess.getTime() - off * 60000));
  const sign = off < 0 ? '-' : '+'; const a = Math.abs(off);
  return `${iso}T${time}:00${sign}${String(Math.floor(a / 60)).padStart(2, '0')}:${String(a % 60).padStart(2, '0')}`;
}
/** Toronto date and minutes-of-day of an instant. */
export function torontoParts(instant: string | Date): { date: string; minutes: number } {
  const d = typeof instant === 'string' ? new Date(instant) : instant;
  return { date: torontoToday(d), minutes: torontoMinutesNow(d) };
}
export const minutesToClock = (m: number) => clock(`${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`);
export const timeSlots = (step = 30) => Array.from({ length: 1440 / step }, (_, i) => `${String(Math.floor((i * step) / 60)).padStart(2, '0')}:${String((i * step) % 60).padStart(2, '0')}`);
