// Notification preferences (release 48, migration 3260): what public.server_notify_prefs returns for a person, and the
// words and small sums the page needs. Pure: the page, the app's API and the unit tests read it. The database decides
// what may be switched (a locked type is always sent) and holds every choice where messages are queued.
export type Channel = 'push' | 'email' | 'text';
export type Cadence = 'instant' | 'daily' | 'weekly';
export type Portal = 'renter' | 'owner' | 'investor' | 'staff' | 'admin' | 'partner';

export interface PrefType { code: string; label: string; detail: string | null; locked: boolean; channels: Channel[]; live: boolean; push: boolean; email: boolean; text: boolean }
export interface PrefGroup { name: string; locked: boolean; types: PrefType[] }
export interface PrefState {
  kind: 'user' | 'partner'; portal: Portal; portals: Portal[]; staff: boolean;
  profile: { quiet_on: boolean; quiet_from: number; quiet_until: number; cadence: Cadence; all_off: boolean };
  channels: {
    push: { on: boolean; devices: number };
    email: { on: boolean; address: string | null };
    text: { on: boolean; why_not: string | null; chosen: string | null; paused: boolean };
  };
  summary: { hour: number; weekly_dow: number };
  groups: PrefGroup[];
}
/** One change the page sends: a switch, the quiet hours, the rhythm, or everything optional off. */
export type PrefChange =
  | { type: string; channel: Channel; on: boolean }
  | { quiet_on?: boolean; quiet_from?: number; quiet_until?: number }
  | { cadence: Cadence }
  | { all_off: boolean };

export const CHANNELS: Array<{ key: Channel; label: string }> = [{ key: 'push', label: 'Push' }, { key: 'email', label: 'Email' }, { key: 'text', label: 'Text' }];
export const CADENCES: Array<{ key: Cadence; label: string; hint: string }> = [
  { key: 'instant', label: 'Instant', hint: 'Each one as it happens.' },
  { key: 'daily', label: 'Daily summary', hint: 'Optional emails once a day, in one email.' },
  { key: 'weekly', label: 'Weekly summary', hint: 'Optional emails once a week, in one email.' }
];
const DOW = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/** Minutes of the day as the value of a time input ("21:00"), and back (null when it is not a time). */
export function minutesToTime(m: number): string {
  const x = ((Math.round(m) % 1440) + 1440) % 1440;
  return `${String(Math.floor(x / 60)).padStart(2, '0')}:${String(x % 60).padStart(2, '0')}`;
}
export function timeToMinutes(v: string): number | null {
  const m = /^(\d{1,2}):(\d{2})$/.exec(v.trim());
  if (!m) return null;
  const h = Number(m[1]); const min = Number(m[2]);
  return h < 24 && min < 60 ? h * 60 + min : null;
}
/** "9:00 pm", the way the site writes a time (no periods). */
export function clockWords(m: number): string {
  const x = ((Math.round(m) % 1440) + 1440) % 1440; const h = Math.floor(x / 60); const min = x % 60;
  return `${h % 12 === 0 ? 12 : h % 12}:${String(min).padStart(2, '0')} ${h < 12 ? 'am' : 'pm'}`;
}

/** Why a channel cannot be used right now, in plain words (null when it can). */
export function channelNote(s: PrefState, c: Channel): string | null {
  if (c === 'push') {
    if (!s.channels.push.on) return s.kind === 'partner' ? 'Phone alerts need an account.' : 'Phone alerts are switched off for now.';
    return s.channels.push.devices > 0 ? null : 'No phone or browser has alerts turned on yet. Turn them on from the bell, then choose here.';
  }
  if (c === 'text') {
    if (s.channels.text.paused) return 'Texts are going by email right now. Nothing is lost: a text that cannot go is emailed instead.';
    if (s.channels.text.on) return null;
    switch (s.channels.text.why_not) {
      case 'no_verified_phone': return 'Add and confirm a mobile number to get texts.';
      case 'opted_out': return 'You replied STOP to our texts. Reply START to get them again.';
      case 'us_waiting': case 'not_canada': return 'We can only text Canadian mobile numbers for now.';
      default: return s.kind === 'partner' ? 'Partners are reached by email.' : 'Texts are switched off for now.';
    }
  }
  return s.channels.email.address ? null : 'There is no email address on this account.';
}

/** One line that says what the person gets, for the top of the page and the app. */
export function summaryLine(s: PrefState): string {
  const types = s.groups.flatMap((g) => g.types).filter((t) => !t.locked);
  if (s.profile.all_off) return 'Every optional notification is off. The ones marked Always on still reach you.';
  const off = types.filter((t) => t.channels.every((c) => !t[c])).length;
  const when = s.profile.cadence === 'instant' ? 'as they happen' : s.profile.cadence === 'daily' ? `in a daily summary at ${clockWords(s.summary.hour * 60)}`
    : `in a weekly summary on ${DOW[(s.summary.weekly_dow - 1 + 7) % 7]} at ${clockWords(s.summary.hour * 60)}`;
  const quiet = s.profile.quiet_on ? ` Quiet from ${clockWords(s.profile.quiet_from)} to ${clockWords(s.profile.quiet_until)}.` : '';
  return `${types.length - off} of ${types.length} optional kinds are on, ${when}.${quiet}`;
}

/** The state after a change, before the database answers (the switch moves at once; the answer replaces it). */
export function applyChange(s: PrefState, c: PrefChange): PrefState {
  if ('type' in c) {
    return { ...s, profile: c.on ? { ...s.profile, all_off: false } : s.profile,
      groups: s.groups.map((g) => ({ ...g, types: g.types.map((t) => (t.code === c.type && !t.locked ? { ...t, [c.channel]: c.on } : t)) })) };
  }
  if ('cadence' in c) return { ...s, profile: { ...s.profile, cadence: c.cadence } };
  if ('all_off' in c) {
    return { ...s, profile: { ...s.profile, all_off: c.all_off },
      groups: c.all_off ? s.groups.map((g) => ({ ...g, types: g.types.map((t) => (t.locked ? t : { ...t, push: false, email: false, text: false })) })) : s.groups };
  }
  return { ...s, profile: { ...s.profile, ...c } };
}

/** The key of a switch being saved (one switch waits, the others stay usable). */
export const switchKey = (type: string, channel: Channel) => `${type}:${channel}`;
