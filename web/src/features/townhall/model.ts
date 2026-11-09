// The weekly townhall (1062). Pure: the deck page and the unit tests share it.
export interface Point { label: string; value: string }
/** 1068: a staff member's tile on the people slide: their role's numbers and an Admin's shout-out. */
export interface Person { user_id: string; name: string; role: string; points: Point[] | null; shoutout?: string | null }
export interface Slide { key: string; title: string; admin_only: boolean; points: Point[]; board?: Point[]; lines?: string[]; note?: string | null; people?: Person[] }
export interface Townhall { admin: boolean; next_at: string | null; minutes: number; call_url: string | null; weekday: number; time: string; finance_to_staff: boolean; weeks: string[];
  deck: { id: string; week_of: string; built_at: string; slides: Slide[] } | null;
  /** 1068: attendance (join through the site or check in) and the day the least busy weekday moves it to, with 7 days' notice */
  checked_in?: boolean; can_check_in?: boolean; next_weekday?: number | null; next_from?: string | null; attendance?: { meetings: number; last_absent: number | null } | null }

export const WEEKDAY = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'] as const;
/** The notice of a move: "From Tuesday, November 17 the townhall is on Tuesdays", or null. */
export function moveNotice(v: Pick<Townhall, 'weekday' | 'next_weekday' | 'next_from'>): string | null {
  if (!v.next_weekday || !v.next_from || v.next_weekday === v.weekday || !/^\d{4}-\d{2}-\d{2}$/.test(v.next_from)) return null;
  const d = new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', weekday: 'long', month: 'long', day: 'numeric' }).format(new Date(`${v.next_from}T12:00:00Z`));
  return `From ${d} the townhall is on ${WEEKDAY[v.next_weekday]}s (the least busy day of the last 8 weeks and the next 2).`;
}
export interface Release { release: string; title: string; date: string; summary: string }

/** The releases shipped in the week that starts on weekOf (a Monday, YYYY-MM-DD): the development updates slide. */
export function releasesOfWeek(list: Release[], weekOf: string): Release[] {
  const a = Date.parse(`${weekOf}T00:00:00Z`);
  const z = a + 7 * 86_400_000;
  return list.filter((r) => /^\d{4}-\d{2}-\d{2}$/.test(r.date) && Date.parse(`${r.date}T12:00:00Z`) >= a && Date.parse(`${r.date}T12:00:00Z`) < z);
}

/** The deck's slides with the platform updates filled in. */
export function withReleases(slides: Slide[], releases: Release[]): Slide[] {
  return slides.map((s) => (s.key === 'dev' ? { ...s, lines: releases.length ? releases.map((r) => `${r.title}: ${r.summary}`) : ['No release shipped this week.'] } : s));
}

/** A weekly calendar invite (iCalendar), repeating on the townhall's day and time, Toronto. */
export function townhallIcs(o: { nextAt: string; minutes: number; url: string | null; base: string }): string {
  const fmt = (ms: number) => new Date(ms).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
  const start = Date.parse(o.nextAt);
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//CarmaCars//Townhall//EN', 'BEGIN:VEVENT', 'UID:townhall@carmacars.ca', `DTSTAMP:${fmt(start)}`,
    `DTSTART:${fmt(start)}`, `DTEND:${fmt(start + o.minutes * 60_000)}`, 'RRULE:FREQ=WEEKLY', 'SUMMARY:CarmaCars weekly townhall',
    `DESCRIPTION:The week in review. Deck: ${o.base}/staff/townhall${o.url ? `\\nCall: ${o.url}` : ''}`, ...(o.url ? [`LOCATION:${o.url}`] : []),
    'BEGIN:VALARM', 'TRIGGER:-PT60M', 'ACTION:DISPLAY', 'DESCRIPTION:Townhall in an hour', 'END:VALARM', 'END:VEVENT', 'END:VCALENDAR'];
  return lines.join('\r\n') + '\r\n';
}
