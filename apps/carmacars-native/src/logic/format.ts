// Money and Toronto time in words, as the site writes them. No imports.
const TZ = 'America/Toronto';

/** 12345 -> "$123.45"; whole dollars drop the cents ("$120"). */
export function money(cents: number | null | undefined): string {
  if (typeof cents !== 'number' || !Number.isFinite(cents)) return '';
  const neg = cents < 0; const c = Math.abs(Math.round(cents));
  const d = Math.floor(c / 100).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${neg ? '-' : ''}$${d}${c % 100 ? `.${String(c % 100).padStart(2, '0')}` : ''}`;
}
const fmt = (o: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat('en-CA', { timeZone: TZ, ...o });
/** "Fri, Nov 20, 10:00 a.m." in Toronto, whatever the phone's own time zone. */
export function when(iso: string | null | undefined, withTime = true): string {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const day = fmt({ weekday: 'short', month: 'short', day: 'numeric' }).format(d);
  return withTime ? `${day}, ${fmt({ hour: 'numeric', minute: '2-digit', hour12: true }).format(d)}` : day;
}
export const clock = (iso: string) => fmt({ hour: 'numeric', minute: '2-digit', hour12: true }).format(new Date(iso));
/** The Toronto calendar day of an instant, "2026-11-20". */
export function torontoDay(d: Date = new Date()): string {
  const p = Object.fromEntries(fmt({ year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(d).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day}`;
}
export function addDays(day: string, n: number): string {
  const [y, m, d] = day.split('-').map(Number);
  return new Date(Date.UTC(y!, m! - 1, d! + n)).toISOString().slice(0, 10);
}
export const daysBetween = (from: string, to: string) => Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86400_000);
export const carName = (c: { year?: number | null; vehicle_year?: number | null; make?: string; model?: string; vehicle_make?: string; vehicle_model?: string }) =>
  [c.year ?? c.vehicle_year, c.make ?? c.vehicle_make, c.model ?? c.vehicle_model].filter(Boolean).join(' ');
/** "12 min ago", "3 h ago", "2 days ago". */
export function ago(iso: string, now: number = Date.now()): string {
  const m = Math.max(0, Math.floor((now - new Date(iso).getTime()) / 60000));
  if (m < 1) return 'just now';
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  return h < 48 ? `${h} h ago` : `${Math.round(h / 24)} days ago`;
}
