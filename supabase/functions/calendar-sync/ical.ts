// The iCal reader of calendar sync (migration 0062; docs/changes/2026-10-19-calendar-sync-recovery-uptime.md). Plain
// TypeScript with no imports, so the same file runs in the calendar-sync Edge Function (Deno), in the site's
// "Sync now" (the Worker) and in the unit tests (Node: web/src/features/calendar/ical.test.ts).
//
// What it keeps: every VEVENT that holds time (not cancelled, not marked free), from a day ago to 18 months ahead,
// as UTC instants. Times with a TZID are read in that zone (IANA names, and the Windows names Outlook writes);
// floating times and all-day dates are read in the car's zone (America/Toronto); an all-day event runs from midnight
// of its first day to midnight after its last. Simple repeating events (daily, weekly with days, monthly, yearly;
// COUNT, UNTIL, INTERVAL, EXDATE, a changed occurrence by RECURRENCE-ID) are expanded within the window.

export interface IcalEvent {
  uid: string;
  summary: string;
  starts_at: string; // ISO, UTC
  ends_at: string; // ISO, UTC
  all_day: boolean;
}
export interface IcalResult {
  events: IcalEvent[];
  calendar_name: string | null;
  prodid: string | null;
  warnings: string[];
}
export interface IcalOptions {
  now?: Date;
  pastDays?: number; // events that ended before now minus this are dropped (1)
  horizonDays?: number; // events that start after now plus this are dropped (540)
  defaultTz?: string; // America/Toronto
  maxEvents?: number; // 2000
}

export class IcalError extends Error {}

const DAY = 86_400_000;

// Windows zone names (Outlook, Exchange) to IANA, for the zones a Canadian calendar meets.
const WINDOWS_TZ: Record<string, string> = {
  'Eastern Standard Time': 'America/Toronto', 'US Eastern Standard Time': 'America/Indianapolis', 'Central Standard Time': 'America/Chicago',
  'Mountain Standard Time': 'America/Denver', 'Pacific Standard Time': 'America/Los_Angeles', 'Atlantic Standard Time': 'America/Halifax',
  'Newfoundland Standard Time': 'America/St_Johns', 'Canada Central Standard Time': 'America/Regina', 'GMT Standard Time': 'Europe/London',
  'UTC': 'UTC', 'Coordinated Universal Time': 'UTC', 'W. Europe Standard Time': 'Europe/Berlin', 'Romance Standard Time': 'Europe/Paris'
};

interface Prop { name: string; params: Record<string, string>; value: string }

/** Lines unfolded (a line that starts with a space or tab continues the one before). */
export function unfold(text: string): string[] {
  const raw = text.replace(/\r\n?/g, '\n').split('\n');
  const out: string[] = [];
  for (const line of raw) {
    if ((line.startsWith(' ') || line.startsWith('\t')) && out.length) out[out.length - 1] += line.slice(1);
    else if (line.length) out.push(line);
  }
  return out;
}

export function parseProp(line: string): Prop | null {
  // NAME;PARAM=VALUE;PARAM="a:b":value  (a colon inside quotes is not the separator)
  let i = 0; let q = false;
  for (; i < line.length; i++) {
    const ch = line[i];
    if (ch === '"') q = !q;
    else if (ch === ':' && !q) break;
  }
  if (i >= line.length) return null;
  const head = line.slice(0, i); const value = line.slice(i + 1);
  const parts = head.split(';');
  const name = (parts.shift() ?? '').toUpperCase();
  const params: Record<string, string> = {};
  for (const p of parts) {
    const eq = p.indexOf('=');
    if (eq > 0) params[p.slice(0, eq).toUpperCase()] = p.slice(eq + 1).replace(/^"|"$/g, '');
  }
  return { name, params, value };
}

export function unescapeText(v: string): string {
  return v.replace(/\\([\\;,nN])/g, (_, c: string) => (c === 'n' || c === 'N' ? ' ' : c)).replace(/\s+/g, ' ').trim();
}

function validZone(tz: string): boolean {
  try { new Intl.DateTimeFormat('en-US', { timeZone: tz }); return true; } catch { return false; }
}

/** The zone a TZID names, or null when it cannot be read. */
export function resolveZone(tzid: string | undefined): string | null {
  if (!tzid) return null;
  let t = tzid.trim();
  if (WINDOWS_TZ[t]) return WINDOWS_TZ[t]!;
  // some writers prefix a path: /mozilla.org/20050126_1/America/New_York
  const m = /([A-Za-z]+\/[A-Za-z_+-]+(?:\/[A-Za-z_+-]+)?)$/.exec(t);
  if (!validZone(t) && m) t = m[1]!;
  return validZone(t) ? t : null;
}

/** Milliseconds the zone is ahead of UTC at the instant. */
function zoneOffset(utcMs: number, tz: string): number {
  const f = new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const p: Record<string, string> = {};
  for (const x of f.formatToParts(new Date(utcMs))) p[x.type] = x.value;
  return Date.UTC(+p.year!, +p.month! - 1, +p.day!, +p.hour! % 24, +p.minute!, +p.second!) - utcMs;
}

/** A wall-clock time in a zone, as a UTC instant (a time that does not exist in spring is moved forward). */
export function zonedToUtc(y: number, mo: number, d: number, h: number, mi: number, s: number, tz: string): number {
  const wall = Date.UTC(y, mo - 1, d, h, mi, s);
  let t = wall - zoneOffset(wall, tz);
  const off2 = zoneOffset(t, tz);
  if (wall - off2 !== t) {
    const t2 = wall - off2;
    // a gap (spring forward): keep the later reading
    t = zoneOffset(t2, tz) === off2 ? t2 : Math.max(t, t2);
  }
  return t;
}

interface When { ms: number; allDay: boolean; y: number; mo: number; d: number; h: number; mi: number; s: number; tz: string | null; utc: boolean }

export function parseWhen(p: Prop, defaultTz: string, warnings: string[]): When | null {
  const v = p.value.trim();
  const m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$/.exec(v);
  if (!m) return null;
  const [y, mo, d] = [+m[1]!, +m[2]!, +m[3]!];
  const allDay = p.params.VALUE === 'DATE' || m[4] === undefined;
  if (allDay) return { ms: zonedToUtc(y, mo, d, 0, 0, 0, defaultTz), allDay: true, y, mo, d, h: 0, mi: 0, s: 0, tz: defaultTz, utc: false };
  const [h, mi, s] = [+m[4]!, +m[5]!, +(m[6] ?? 0)];
  if (m[7]) return { ms: Date.UTC(y, mo - 1, d, h, mi, s), allDay: false, y, mo, d, h, mi, s, tz: null, utc: true };
  let tz = resolveZone(p.params.TZID);
  if (p.params.TZID && !tz) { warnings.push(`Unknown time zone "${p.params.TZID}": read as ${defaultTz}`); }
  tz = tz ?? defaultTz;
  return { ms: zonedToUtc(y, mo, d, h, mi, s, tz), allDay: false, y, mo, d, h, mi, s, tz, utc: false };
}

/** ISO 8601 duration (P1D, PT2H30M, P1W) in milliseconds. */
export function parseDuration(v: string): number | null {
  const m = /^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(v.trim());
  if (!m) return null;
  const ms = ((+(m[2] ?? 0)) * 7 * DAY) + (+(m[3] ?? 0)) * DAY + (+(m[4] ?? 0)) * 3_600_000 + (+(m[5] ?? 0)) * 60_000 + (+(m[6] ?? 0)) * 1000;
  return m[1] === '-' ? -ms : ms;
}

/** The same wall-clock time shifted by whole days (keeps 10:00 across a daylight-saving change). */
function shiftDays(w: When, days: number): number {
  const base = new Date(Date.UTC(w.y, w.mo - 1, w.d + days));
  const [y, mo, d] = [base.getUTCFullYear(), base.getUTCMonth() + 1, base.getUTCDate()];
  if (w.utc) return Date.UTC(y, mo - 1, d, w.h, w.mi, w.s);
  return zonedToUtc(y, mo, d, w.h, w.mi, w.s, w.tz!);
}
function shiftMonths(w: When, months: number): number | null {
  const y = w.y + Math.floor((w.mo - 1 + months) / 12); const mo = ((w.mo - 1 + months) % 12 + 12) % 12 + 1;
  const last = new Date(Date.UTC(y, mo, 0)).getUTCDate();
  if (w.d > last) return null; // the 31st of a short month does not happen
  if (w.utc) return Date.UTC(y, mo - 1, w.d, w.h, w.mi, w.s);
  return zonedToUtc(y, mo, w.d, w.h, w.mi, w.s, w.tz!);
}

const WEEKDAYS = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];

/** The starts of a repeating event within [from, to), the first start included. */
export function expandRule(start: When, rule: string, from: number, to: number, warnings: string[], limit = 1000): number[] {
  const r: Record<string, string> = {};
  for (const part of rule.split(';')) { const [k, v] = part.split('='); if (k && v) r[k.toUpperCase()] = v.toUpperCase(); }
  const freq = r.FREQ; const interval = Math.max(1, +(r.INTERVAL ?? 1) || 1);
  const count = r.COUNT ? +r.COUNT : Infinity;
  let until = Infinity;
  if (r.UNTIL) {
    const um = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/.exec(r.UNTIL);
    if (um) until = um[4] === undefined ? Date.UTC(+um[1]!, +um[2]! - 1, +um[3]!, 23, 59, 59) + (start.utc ? 0 : 12 * 3_600_000)
      : um[7] ? Date.UTC(+um[1]!, +um[2]! - 1, +um[3]!, +um[4]!, +um[5]!, +um[6]!) : zonedToUtc(+um[1]!, +um[2]!, +um[3]!, +um[4]!, +um[5]!, +um[6]!, start.tz ?? 'UTC');
  }
  const out: number[] = [];
  let n = 0;
  const push = (ms: number) => { n++; if (ms >= from && ms < to) out.push(ms); };
  if (freq === 'DAILY' || freq === 'YEARLY' || freq === 'MONTHLY') {
    for (let i = 0; n < count && out.length < limit && i < 5000; i++) {
      const ms = freq === 'DAILY' ? shiftDays(start, i * interval) : shiftMonths(start, i * interval * (freq === 'YEARLY' ? 12 : 1));
      if (ms === null) continue;
      if (ms > until || ms >= to) break;
      push(ms);
    }
  } else if (freq === 'WEEKLY') {
    const startDow = new Date(Date.UTC(start.y, start.mo - 1, start.d)).getUTCDay();
    const days = (r.BYDAY ? r.BYDAY.split(',').map((x) => WEEKDAYS.indexOf(x.replace(/^[+-]?\d+/, ''))).filter((x) => x >= 0) : [startDow]).sort((a, b) => a - b);
    for (let wk = 0; n < count && out.length < limit && wk < 1500; wk++) {
      let stop = false;
      for (const dow of days) {
        const offset = wk * 7 * interval + (dow - startDow);
        if (offset < 0) continue;
        const ms = shiftDays(start, offset);
        if (ms > until || ms >= to) { stop = true; break; }
        push(ms);
        if (n >= count) break;
      }
      if (stop) break;
    }
  } else {
    warnings.push(`Repeating rule ${freq ?? '(none)'} is not supported: only the first time is kept`);
    push(start.ms);
  }
  return out;
}

interface Raw { props: Prop[] }

/** Reads an iCal file. Throws IcalError when the text is not a calendar. */
export function parseIcal(text: string, opts: IcalOptions = {}): IcalResult {
  const now = (opts.now ?? new Date()).getTime();
  const defaultTz = opts.defaultTz ?? 'America/Toronto';
  const from = now - (opts.pastDays ?? 1) * DAY;
  const to = now + (opts.horizonDays ?? 540) * DAY;
  const maxEvents = opts.maxEvents ?? 2000;
  const warnings: string[] = [];
  const lines = unfold(text.replace(/^﻿/, ''));
  if (!lines.length || !/^BEGIN:VCALENDAR$/i.test(lines[0]!.trim())) {
    const head = text.slice(0, 200).trim().toLowerCase();
    if (head.startsWith('<')) throw new IcalError('The link answered with a web page, not a calendar. Copy the calendar (iCal) link again.');
    throw new IcalError('The link did not answer with a calendar (iCal).');
  }
  let calendarName: string | null = null; let prodid: string | null = null;
  const raws: Raw[] = [];
  let cur: Raw | null = null; let depth = 0;
  for (const line of lines) {
    const p = parseProp(line);
    if (!p) continue;
    if (p.name === 'BEGIN') {
      if (p.value.toUpperCase() === 'VEVENT' && !cur) { cur = { props: [] }; depth = 0; continue; }
      if (cur) depth++;
      continue;
    }
    if (p.name === 'END') {
      if (cur && p.value.toUpperCase() === 'VEVENT' && depth === 0) { raws.push(cur); cur = null; continue; }
      if (cur && depth > 0) depth--;
      continue;
    }
    if (cur) { if (depth === 0) cur.props.push(p); continue; }
    if (p.name === 'X-WR-CALNAME') calendarName = unescapeText(p.value).slice(0, 120);
    else if (p.name === 'PRODID') prodid = p.value.slice(0, 200);
  }
  // occurrences changed by RECURRENCE-ID, by uid
  const overrides = new Map<string, Set<number>>();
  const events: IcalEvent[] = [];
  const add = (e: IcalEvent) => { if (events.length < maxEvents) events.push(e); else if (!warnings.includes('Too many events: only the first kept')) warnings.push('Too many events: only the first kept'); };
  const get = (r: Raw, n: string) => r.props.find((x) => x.name === n);
  const parsed = raws.map((r) => {
    const startP = get(r, 'DTSTART');
    const start = startP ? parseWhen(startP, defaultTz, warnings) : null;
    const rid = get(r, 'RECURRENCE-ID');
    const ridWhen = rid ? parseWhen(rid, defaultTz, warnings) : null;
    return { r, start, ridWhen };
  });
  for (const x of parsed) {
    if (x.ridWhen) {
      const uid = get(x.r, 'UID')?.value ?? '';
      if (!overrides.has(uid)) overrides.set(uid, new Set());
      overrides.get(uid)!.add(x.ridWhen.ms);
    }
  }
  for (const { r, start, ridWhen } of parsed) {
    if (!start) { warnings.push('An event without a start was skipped'); continue; }
    const status = (get(r, 'STATUS')?.value ?? '').toUpperCase();
    const transp = (get(r, 'TRANSP')?.value ?? '').toUpperCase();
    const summary = unescapeText(get(r, 'SUMMARY')?.value ?? '').slice(0, 200);
    let uid = (get(r, 'UID')?.value ?? '').trim();
    if (!uid) uid = `nouid-${start.ms}-${summary.slice(0, 40)}`;
    if (status === 'CANCELLED' || transp === 'TRANSPARENT') continue;
    // length: an all-day event with an end date runs whole days (midnight to midnight in the zone, whatever daylight
    // saving does); otherwise the end minus the start, or DURATION, or one day for a date and nothing for a time
    const endP = get(r, 'DTEND');
    const end = endP ? parseWhen(endP, defaultTz, warnings) : null;
    const wholeDays = start.allDay && (!end || end.allDay);
    let days = 0; let len = 0;
    if (wholeDays) {
      if (end) days = Math.round((Date.UTC(end.y, end.mo - 1, end.d) - Date.UTC(start.y, start.mo - 1, start.d)) / DAY);
      else { const dur = get(r, 'DURATION'); const d = dur ? parseDuration(dur.value) : null; days = d !== null ? Math.round(d / DAY) : 1; }
    } else if (end) len = end.ms - start.ms;
    else { const dur = get(r, 'DURATION'); len = (dur ? parseDuration(dur.value) : null) ?? 0; }
    if ((wholeDays && days <= 0) || (!wholeDays && len <= 0)) { warnings.push(`"${summary || uid}" has no length and was skipped`); continue; }
    const endOf = (w: When) => (wholeDays ? shiftDays(w, days) : w.ms + len);
    if (ridWhen) {
      // a changed occurrence: its own times
      const s = start.ms; const e = endOf(start);
      if (e > from && s < to) add({ uid: `${uid}#${new Date(ridWhen.ms).toISOString()}`, summary, starts_at: new Date(s).toISOString(), ends_at: new Date(e).toISOString(), all_day: start.allDay });
      continue;
    }
    const rule = get(r, 'RRULE')?.value;
    if (rule) {
      const ex = new Set<number>();
      for (const p of r.props.filter((x) => x.name === 'EXDATE')) {
        for (const v of p.value.split(',')) { const w = parseWhen({ ...p, value: v }, defaultTz, warnings); if (w) ex.add(w.ms); }
      }
      const changed = overrides.get(uid) ?? new Set<number>();
      // occurrences that started before the window may still be running: look back by the length
      const lookBack = wholeDays ? days * DAY + DAY : len;
      for (const s of expandRule(start, rule, from - lookBack, to, warnings)) {
        if (ex.has(s) || changed.has(s)) continue;
        const occ = { ...start, ms: s };
        if (start.allDay) { const dd = new Date(s + 12 * 3_600_000); Object.assign(occ, { y: dd.getUTCFullYear(), mo: dd.getUTCMonth() + 1, d: dd.getUTCDate() }); }
        const e = endOf(occ);
        if (e <= from) continue;
        add({ uid: s === start.ms ? uid : `${uid}#${new Date(s).toISOString()}`, summary, starts_at: new Date(s).toISOString(), ends_at: new Date(e).toISOString(), all_day: start.allDay });
      }
      continue;
    }
    const e = endOf(start);
    if (e <= from || start.ms >= to) continue;
    add({ uid, summary, starts_at: new Date(start.ms).toISOString(), ends_at: new Date(e).toISOString(), all_day: start.allDay });
  }
  // one uid once (a feed that repeats an event keeps its first)
  const seen = new Set<string>();
  const unique = events.filter((e) => (seen.has(e.uid) ? false : (seen.add(e.uid), true)));
  unique.sort((a, b) => a.starts_at.localeCompare(b.starts_at));
  return { events: unique, calendar_name: calendarName, prodid, warnings };
}
