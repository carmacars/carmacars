// The weekly townhall (1062). Pure: the deck page and the unit tests share it.
export interface Point { label: string; value: string }
/** 1068: a staff member's tile on the people slide: their role's numbers and an Admin's shout-out. */
export interface Person { user_id: string; name: string; role: string; points: Point[] | null; shoutout?: string | null }
export interface Slide { key: string; title: string; admin_only: boolean; points: Point[]; board?: Point[]; lines?: string[]; note?: string | null; people?: Person[] }
export interface Townhall { admin: boolean; next_at: string | null; minutes: number; call_url: string | null; weekday: number; time: string; finance_to_staff: boolean; weeks: string[];
  deck: { id: string; week_of: string; built_at: string; slides: Slide[] } | null;
  /** 1068: attendance (join through the site or check in); for an Admin, the website's visitor sessions per weekday (8 weeks) */
  checked_in?: boolean; can_check_in?: boolean; visitors?: Record<string, number> | null; attendance?: { meetings: number; last_absent: number | null } | null }

export const WEEKDAY = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'] as const;
/** 1068: the visitor sessions per weekday (Monday first), for the Admin's table beside the fixed day; the quietest marked. */
export function visitorDays(v: Record<string, number> | null | undefined): Array<{ day: number; name: string; sessions: number; quietest: boolean }> {
  if (!v) return [];
  const rows = [1, 2, 3, 4, 5, 6, 7].map((d) => ({ day: d, name: WEEKDAY[d]!, sessions: Number(v[String(d)] ?? 0), quietest: false }));
  const min = Math.min(...rows.map((r) => r.sessions));
  return rows.map((r) => ({ ...r, quietest: rows.some((x) => x.sessions > 0) && r.sessions === min }));
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
