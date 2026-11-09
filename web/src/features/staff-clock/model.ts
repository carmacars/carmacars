// Clock in and out for customer service, Fleet and Finance (migration 1061). Pure: the cards and the unit tests share it.
export interface ClockEntry { id: string; started_at: string; ended_at: string | null; minutes: number; source: 'clock' | 'manual'; note: string | null; [k: string]: unknown }
export interface ClockState { open: { id: string; started_at: string; minutes: number } | null; start_today: string | null; today_minutes: number; week_minutes: number; entries: ClockEntry[] }

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
