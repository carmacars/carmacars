// Small display helpers of the field portal's job cards (2026-10-25 design pass): the time of a job in Toronto,
// split so the hour can be set large, and how far away it is in words a driver reads at a glance.
const TZ = 'America/Toronto';

export const KIND: Record<string, string> = { handover: 'Handover', delivery: 'Delivery', return_check_in: 'Return check-in', pickup_from_renter: 'Pickup from renter', detail: 'Detail', photo_shoot: 'Photo shoot', tracker_install: 'Tracker install', tracker_removal: 'Tracker removal', registry_run: 'Registry run', recovery: 'Recovery', other: 'Other' };
export const CHECK: Record<string, string> = { handover: 'Check out (pickup)', delivery: 'Check out (pickup)', return_check_in: 'Check in (return)', pickup_from_renter: 'Check in (return)' };
export const STATUS: Record<string, string> = { scheduled: 'Not acknowledged', acknowledged: 'Acknowledged', in_progress: 'In progress', done: 'Done', blocked: 'Stopped' };

export const maps = (p: string) => `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(p)}`;
export const tel = (p: string) => `tel:${p.replace(/[^\d+]/g, '')}`;

/** "2:30" and "p.m." of a time, in Toronto. */
export function clock(iso: string): { time: string; half: string } {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, hour: 'numeric', minute: '2-digit', hour12: true }).formatToParts(new Date(iso));
  const hour = parts.find((p) => p.type === 'hour')?.value ?? '';
  const minute = parts.find((p) => p.type === 'minute')?.value ?? '';
  const pm = /p/i.test(parts.find((p) => p.type === 'dayPeriod')?.value ?? '');
  return { time: `${hour}:${minute}`, half: pm ? 'p.m.' : 'a.m.' };
}

/** How far a job is from now: "in 25 min", "in 2 h 10 min", "now", "40 min ago". */
export function fromNow(iso: string, now: Date | string = new Date()): { text: string; late: boolean } {
  const min = Math.round((new Date(iso).getTime() - new Date(now).getTime()) / 60_000);
  const span = (m: number) => (m >= 60 ? `${Math.floor(m / 60)} h${m % 60 ? ` ${m % 60} min` : ''}` : `${m} min`);
  if (Math.abs(min) <= 2) return { text: 'now', late: false };
  return min > 0 ? { text: `in ${span(min)}`, late: false } : { text: `${span(-min)} ago`, late: true };
}

/** "Today", "Tomorrow" or "Thu, Oct 29": the Toronto day of a job, for jobs that are not all on one day's list. */
export function dayLabel(iso: string, now: Date | string = new Date()): string {
  const ymd = (d: Date | string) => new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(d));
  const days = Math.round((Date.parse(`${ymd(iso)}T12:00:00Z`) - Date.parse(`${ymd(now)}T12:00:00Z`)) / 86_400_000);
  if (days === 0) return 'Today';
  if (days === 1) return 'Tomorrow';
  return new Intl.DateTimeFormat('en-CA', { timeZone: TZ, weekday: 'short', month: 'short', day: 'numeric' }).format(new Date(iso));
}
