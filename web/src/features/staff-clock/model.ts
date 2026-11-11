// Clock in and out for customer service, Fleet and Finance (migration 1061). Pure: the cards and the unit tests share it.
export interface ClockEntry { id: string; started_at: string; ended_at: string | null; minutes: number; source: 'clock' | 'manual'; note: string | null; [k: string]: unknown }
export interface BreakEntry { id: string; started_at: string; ended_at: string | null; minutes: number; reason: string | null; open: boolean; edited_at: string | null; edit_reason: string | null }
export interface BreakSummary { count: number; minutes: number; longest: number }
export interface ClockState { open: { id: string; started_at: string; minutes: number } | null; start_today: string | null; today_minutes: number; week_minutes: number; entries: ClockEntry[];
  /** 1800: the open break (over: past the reminder), today's breaks, whether activity is counted now, the settings the browser needs */
  break?: (BreakEntry & { over: boolean }) | null; breaks_today?: BreakSummary; breaks?: BreakEntry[]; tracking?: boolean;
  settings?: { break_reminder_minutes: number; idle_nudge_minutes: number; idle_alert_minutes: number; breaks_paid: boolean } }

/** 125 minutes as "2 h 5 min". */
export function hoursWords(min: number): string {
  const m = Math.max(0, Math.round(min));
  const h = Math.floor(m / 60);
  return h ? `${h} h${m % 60 ? ` ${m % 60} min` : ''}` : `${m} min`;
}

/** The line under the button: clocked in since, or the start time and whether it has passed. */
export function clockLine(s: ClockState, now = Date.now()): string {
  const at = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));
  if (s.open) return `Clocked in since ${at(s.open.started_at)} (${hoursWords(s.open.minutes)}). Today ${hoursWords(s.today_minutes)}, this week ${hoursWords(s.week_minutes)}.`;
  if (s.start_today && new Date(s.start_today).getTime() < now && s.today_minutes === 0) return `Your day started at ${at(s.start_today)}: clock in now.`;
  return `${s.start_today ? `Your day starts at ${at(s.start_today)}. ` : ''}Today ${hoursWords(s.today_minutes)}, this week ${hoursWords(s.week_minutes)}.`;
}

/** 1800: today's breaks in words: "2 breaks, 25 min, longest 15 min". */
export function breaksWords(b: BreakSummary | undefined): string {
  if (!b || !b.count) return 'No breaks';
  return `${b.count} break${b.count === 1 ? '' : 's'}, ${hoursWords(b.minutes)}, longest ${hoursWords(b.longest)}`;
}

/** 1800: the browser's activity beat: at most one a minute, and only for a real interaction. */
export const BEAT_EVERY_MS = 60_000;
export const BEAT_EVENTS = ['pointerdown', 'pointermove', 'keydown', 'scroll', 'wheel', 'focus', 'touchstart'] as const;
export function beatDue(lastSent: number, now: number, tracking: boolean): boolean {
  // not counted (clocked out or on a break): one check every 5 minutes, to see a clock-in made elsewhere
  return now - lastSent >= (tracking ? BEAT_EVERY_MS : 5 * BEAT_EVERY_MS);
}
/** "Still there?" once the person has not interacted for the nudge minutes (only while counted and the tab is visible). */
export function nudgeDue(lastActive: number, now: number, nudgeMin: number, tracking: boolean, visible: boolean): boolean {
  return tracking && visible && nudgeMin > 0 && now - lastActive >= nudgeMin * 60_000;
}
