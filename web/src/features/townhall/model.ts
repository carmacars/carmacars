// The weekly townhall (1062). Pure: the deck page and the unit tests share it.
export interface Point { label: string; value: string }
/** 1068: a staff member's tile on the people slide: their role's numbers and an Admin's shout-out. */
export interface Person { user_id: string; name: string; role: string; points: Point[] | null; shoutout?: string | null }
export interface Slide { key: string; title: string; admin_only: boolean; points: Point[]; /** 1505: the section's minutes in the 30-minute run */ minutes?: number; board?: Point[]; lines?: string[]; note?: string | null; people?: Person[] }
export interface Townhall { admin: boolean; next_at: string | null; minutes: number; call_url: string | null; weekday: number; time: string; finance_to_staff: boolean; weeks: string[];
  deck: { id: string; week_of: string; built_at: string; slides: Slide[]; recording_url?: string | null } | null;
  /** 1068: attendance (join through the site or check in); for an Admin, the website's visitor sessions per weekday (8 weeks) */
  checked_in?: boolean; can_check_in?: boolean; visitors?: Record<string, number> | null; attendance?: { meetings: number; last_absent: number | null } | null;
  /** 1505: a join waiting for Confirm; the run's minutes; the recordings; stories; social figures and attendance marks (Admin) */
  joined_unconfirmed?: boolean; run_minutes?: number; recordings?: Array<{ week_of: string; url: string }>;
  my_stories?: Array<{ id: string; body: string; picked: boolean; week_of: string }>; stories?: Array<{ id: string; name: string; body: string; picked: boolean; week_of: string }> | null;
  social?: Array<{ week_of: string; platform: string; followers: number | null; posts: number | null; views: number | null }> | null;
  mark?: { meeting_at: string | null; people: Array<{ user_id: string; name: string; present: boolean; locked: boolean }> } | null }

/** 1505: the run's clock: each section's start minute (0 for the first), for the presenter */
export function runClock(slides: Slide[]): number[] {
  let t = 0;
  return slides.map((s) => { const at = t; t += s.minutes ?? 0; return at; });
}

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

// ---------------------------------------------------------------- 2590: the townhall card of every portal home
export interface TownhallLinkRead { has_link: boolean; next_at: string | null; minutes: number; live: boolean; card?: boolean; ends_at?: string | null;
  checked_in?: boolean; missed_last?: boolean }
export interface TownhallCardModel { headline: string; when: string; countdown: string; joinOpen: boolean; live: boolean; checkedIn: boolean; warn: string | null }
const torontoWhen = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'long', month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));
const torontoDay = (ms: number) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto' }).format(new Date(ms));
/** "in 2 h 5 min", "in 12 min", "now" */
export function countdown(ms: number): string {
  if (ms <= 0) return 'now';
  const m = Math.ceil(ms / 60_000);
  if (m < 60) return `in ${m} min`;
  const h = Math.floor(m / 60);
  const r = m % 60;
  return h >= 24 ? `in ${Math.floor(h / 24)} d ${h % 24} h` : `in ${h} h${r ? ` ${r} min` : ''}`;
}
/** The card: from the day before (the read says) until the call ends; Join from 15 minutes before; the warning after a miss. */
export function townhallCard(v: TownhallLinkRead | null | undefined, now: number): TownhallCardModel | null {
  if (!v?.next_at || !v.card) return null;
  const at = Date.parse(v.next_at);
  const end = v.ends_at ? Date.parse(v.ends_at) : at + (v.minutes || 30) * 60_000;
  if (!Number.isFinite(at) || now >= end) return null;
  const live = now >= at;
  const today = torontoDay(now) === torontoDay(at);
  return {
    headline: live ? 'The townhall is on now' : today ? 'Townhall today' : 'Townhall tomorrow',
    when: `${torontoWhen(v.next_at)}, Toronto time`,
    countdown: live ? 'on now' : countdown(at - now),
    joinOpen: now >= at - 15 * 60_000,
    live,
    checkedIn: Boolean(v.checked_in),
    warn: v.missed_last ? 'You missed the last townhall: one more miss locks your account.' : null
  };
}
