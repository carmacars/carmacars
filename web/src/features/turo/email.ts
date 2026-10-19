// Turo sync by email (migration 0063). Turo has no calendar link, but it emails the host for every trip booked,
// changed, extended or cancelled. rent@carmacars.ca forwards those emails (one Gmail filter) to the inbound address
// (trips@in.carmacars.ca, Cloudflare Email Routing on a subdomain, so the root domain's Google Workspace mail is
// untouched); the Worker's email handler posts the raw message to /api/inbound/turo, which reads it with this file.
//
// No imports, so the unit tests run it directly (email.test.ts) and the Worker carries no MIME library:
//   parseMime        the parts of the message: headers, the text (plain, or HTML turned into text)
//   gmailConfirmation Gmail's "forwarding confirmation" email (its code and link, shown in Admin)
//   parseTuroEmail   the rules: kind, trip id, start, end, guest first name, and which car (matchVehicle)
//   redact           the short excerpt kept for an email someone must look at (no addresses, phones or links)
// Nothing here stores anything; the caller keeps only the parsed fields and a short audit line.

export type TuroKind = 'booked' | 'changed' | 'extended' | 'cancelled' | 'request' | 'other';
export interface Mime { headers: Record<string, string>; subject: string; from: string; messageId: string; date: Date | null; text: string }
export interface MatchCar { vehicle_id: string; name: string; listing_name: string | null; turo_vehicle_id: string | null; plate: string | null; vin: string | null;
  make: string | null; model: string | null; year: number | null }
export interface TuroParsed {
  kind: TuroKind; fromTuro: boolean; tripId: string | null; start: string | null; end: string | null; guestFirstName: string | null;
  vehicleId: string | null; vehicleHint: string | null; vehicleWhy: string | null; missing: string[]; sentAt: string | null
}

// ---------------------------------------------------------------- MIME
const lower = (s: string) => s.toLowerCase();

function splitHead(raw: string): [string, string] {
  const m = /\r?\n\r?\n/.exec(raw);
  return m ? [raw.slice(0, m.index), raw.slice(m.index + m[0].length)] : [raw, ''];
}

export function headersOf(head: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of head.replace(/\r?\n[ \t]+/g, ' ').split(/\r?\n/)) {
    const i = line.indexOf(':');
    if (i <= 0) continue;
    const k = lower(line.slice(0, i).trim());
    if (!(k in out)) out[k] = line.slice(i + 1).trim();
  }
  return out;
}

function bytesToText(bytes: Uint8Array, charset: string): string {
  try { return new TextDecoder(charset || 'utf-8', { fatal: false }).decode(bytes); } catch { return new TextDecoder('utf-8').decode(bytes); }
}
function b64(s: string): Uint8Array {
  const clean = s.replace(/[^A-Za-z0-9+/=]/g, '');
  try { const bin = atob(clean); const a = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i); return a; } catch { return new Uint8Array(); }
}
function qp(s: string, header = false): Uint8Array {
  const src = (header ? s.replace(/_/g, ' ') : s).replace(/=\r?\n/g, '');
  const out: number[] = [];
  for (let i = 0; i < src.length; i++) {
    const c = src[i]!;
    if (c === '=' && /^[0-9A-Fa-f]{2}$/.test(src.slice(i + 1, i + 3))) { out.push(parseInt(src.slice(i + 1, i + 3), 16)); i += 2; }
    else { const code = src.charCodeAt(i); if (code < 128) out.push(code); else for (const b of new TextEncoder().encode(c)) out.push(b); }
  }
  return new Uint8Array(out);
}

/** RFC 2047 encoded words in a header ("=?UTF-8?Q?Trip_booked?="). */
export function decodeWords(s: string): string {
  return s.replace(/\?=\s+=\?/g, '?==?').replace(/=\?([^?]+)\?([BbQq])\?([^?]*)\?=/g, (_, cs: string, enc: string, txt: string) =>
    bytesToText(enc.toUpperCase() === 'B' ? b64(txt) : qp(txt, true), cs));
}

const param = (v: string, name: string) => new RegExp(`${name}\\s*=\\s*"?([^";]+)"?`, 'i').exec(v)?.[1]?.trim() ?? '';

const ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', ndash: '-', mdash: '-', rsquo: "'", lsquo: "'", ldquo: '"', rdquo: '"', hellip: '...', bull: '-', middot: '-', rarr: '-' };
export function htmlToText(html: string): string {
  return html
    .replace(/<(script|style|head)[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<!--[\s\S]*?-->/g, ' ')
    .replace(/<a\s[^>]*href\s*=\s*"([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi, (_, href: string, inner: string) => `${inner} ${/turo\.com|google\.com/i.test(href) ? `\u0001${href}\u0002` : ''} `)
    .replace(/<(br|\/p|\/div|\/tr|\/h\d|\/li|\/table|p|div|tr|li|h\d)\b[^>]*>/gi, '\n')
    .replace(/<\/t[dh]>/gi, ' \t ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&#(\d+);/g, (_, n: string) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n: string) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&([a-z]+);/gi, (m, n: string) => ENTITIES[lower(n)] ?? m)
    .replace(/\u0001([^\u0002]*)\u0002/g, '$1')
    .replace(/[ \t ]+/g, ' ')
    .replace(/ *\n */g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

interface Part { type: string; text: string }
function parts(head: Record<string, string>, body: string, depth = 0): Part[] {
  const ct = head['content-type'] ?? 'text/plain';
  const type = lower(ct.split(';')[0]!.trim());
  if (type.startsWith('multipart/') && depth < 5) {
    const boundary = param(ct, 'boundary');
    if (!boundary) return [];
    const out: Part[] = [];
    for (const chunk of body.split(new RegExp(`\\r?\\n?--${boundary.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?:--)?[ \\t]*\\r?\\n?`))) {
      if (!chunk.trim()) continue;
      const [h, b] = splitHead(chunk);
      out.push(...parts(headersOf(h), b, depth + 1));
    }
    return out;
  }
  if (type === 'message/rfc822' && depth < 5) { const [h, b] = splitHead(body); return parts(headersOf(h), b, depth + 1); }
  if (!type.startsWith('text/')) return [];
  const enc = lower(head['content-transfer-encoding'] ?? '');
  const cs = param(ct, 'charset') || 'utf-8';
  const text = enc === 'base64' ? bytesToText(b64(body), cs) : enc === 'quoted-printable' ? bytesToText(qp(body), cs) : body;
  return [{ type, text }];
}

export function parseMime(raw: string): Mime {
  const [h, b] = splitHead(raw.replace(/^﻿/, ''));
  const headers = headersOf(h);
  const ps = parts(headers, b);
  const plain = ps.filter((p) => p.type === 'text/plain').map((p) => p.text).join('\n').trim();
  const html = ps.filter((p) => p.type === 'text/html').map((p) => htmlToText(p.text)).join('\n').trim();
  // the HTML part usually holds the most (Turo's plain part can be a short version); keep the longer one
  const text = (html.length > plain.length * 1.2 ? html : plain || html).replace(/\r\n/g, '\n');
  const d = headers.date ? new Date(headers.date) : null;
  return { headers, subject: decodeWords(headers.subject ?? '').replace(/\s+/g, ' ').trim(), from: decodeWords(headers.from ?? ''),
    messageId: (headers['message-id'] ?? '').replace(/[<>\s]/g, '').slice(0, 300), date: d && !Number.isNaN(d.getTime()) ? d : null, text };
}

export const addressOf = (v: string) => lower(/<([^>]+)>/.exec(v)?.[1] ?? v).trim();
/** rent+caf_=trips=in.carmacars.ca@carmacars.ca (Gmail's forwarding envelope) is rent@carmacars.ca. */
export const plainAddress = (v: string) => addressOf(v).replace(/\+[^@]*@/, '@');

// ---------------------------------------------------------------- Gmail's forwarding confirmation
export function gmailConfirmation(m: Mime): { code: string; url: string | null; forAddress: string | null } | null {
  if (addressOf(m.from) !== 'forwarding-noreply@google.com' || !/forwarding confirmation/i.test(m.subject)) return null;
  const code = /\(#(\d{6,12})\)/.exec(m.subject)?.[1] ?? /confirmation code:\s*(\d{6,12})/i.exec(m.text)?.[1];
  if (!code) return null;
  const url = /https:\/\/(?:mail-settings\.google\.com|mail\.google\.com|isolated\.mail\.google\.com)\/mail\/[^\s<>"')]+/i.exec(m.text)?.[0] ?? null;
  const forAddress = /receive mail from\s+([^\s]+@[^\s]+)/i.exec(m.subject)?.[1] ?? null;
  return { code, url, forAddress };
}

// ---------------------------------------------------------------- dates (Turo writes times in the car's zone)
const MONTHS: Record<string, number> = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12 };
const MON = '(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sept?(?:ember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\\.?';
const DOW = '(?:(?:Mon|Tue|Tues|Wed|Thu|Thur|Thurs|Fri|Sat|Sun)[a-z]*\\.?,?\\s+)?';
const TIME = '(\\d{1,2})(?::(\\d{2}))?\\s*([AaPp]\\.?[Mm]\\.?)?';
// "Thu, Oct 22, 2026, 10:00 AM", "October 22 at 10:00 am", "Oct 22, 10 AM", "10/22/2026 10:00 AM", "2026-10-22 10:00"
export const DATE_RE = new RegExp(
  `${DOW}(?:${MON}\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s+(\\d{4}))?|(\\d{1,2})/(\\d{1,2})/(\\d{4})|(\\d{4})-(\\d{2})-(\\d{2}))` +
  `(?:,?\\s*(?:at|@|-)?\\s*${TIME})?`, 'gi');

function torontoOffsetMinutes(utcMs: number): number {
  const f = new Intl.DateTimeFormat('en-US', { timeZone: 'America/Toronto', hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric' });
  const p = Object.fromEntries(f.formatToParts(new Date(utcMs)).map((x) => [x.type, x.value]));
  const asUtc = Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day), Number(p.hour) % 24, Number(p.minute));
  return Math.round((asUtc - utcMs) / 60000);
}
/** A wall-clock time in Toronto as UTC (both daylight saving changes). */
export function torontoToUtc(y: number, mo: number, d: number, h: number, mi: number): Date {
  const guess = Date.UTC(y, mo - 1, d, h, mi);
  let t = guess - torontoOffsetMinutes(guess) * 60000;
  t = guess - torontoOffsetMinutes(t) * 60000;
  return new Date(t);
}

export interface FoundDate { at: Date; index: number; end: number; hasTime: boolean }
/** Every date with its time in the text, read as Toronto time. A date without a year takes the year that puts it
 * nearest after (or up to 60 days before) the email's own date. */
export function findDates(text: string, emailDate: Date): FoundDate[] {
  const out: FoundDate[] = [];
  DATE_RE.lastIndex = 0;
  for (let m = DATE_RE.exec(text); m; m = DATE_RE.exec(text)) {
    let y: number, mo: number, d: number;
    if (m[1]) { mo = MONTHS[lower(m[1]).slice(0, m[1].toLowerCase().startsWith('sept') ? 4 : 3)] ?? 0; d = Number(m[2]); y = m[3] ? Number(m[3]) : 0; }
    else if (m[4]) { mo = Number(m[4]); d = Number(m[5]); y = Number(m[6]); }
    else { y = Number(m[7]); mo = Number(m[8]); d = Number(m[9]); }
    if (!mo || mo > 12 || !d || d > 31) continue;
    const hasTime = m[10] !== undefined && (m[11] !== undefined || m[12] !== undefined);
    let h = hasTime ? Number(m[10]) : 0;
    const mi = hasTime && m[11] ? Number(m[11]) : 0;
    const ap = m[12] ? lower(m[12]).replace(/\./g, '') : '';
    if (ap === 'pm' && h < 12) h += 12;
    if (ap === 'am' && h === 12) h = 0;
    if (h > 23 || mi > 59) continue;
    if (!y) {
      y = emailDate.getUTCFullYear();
      if (torontoToUtc(y, mo, d, h, mi).getTime() < emailDate.getTime() - 60 * 86400000) y += 1;
      else if (torontoToUtc(y, mo, d, h, mi).getTime() > emailDate.getTime() + 300 * 86400000) y -= 1;
    }
    out.push({ at: torontoToUtc(y, mo, d, h, mi), index: m.index, end: m.index + m[0].length, hasTime });
  }
  return out;
}

// ---------------------------------------------------------------- the rules
const flat = (s: string) => s.replace(/[ \t ]+/g, ' ');

export function classify(subject: string, text: string): TuroKind {
  const s = lower(subject);
  const head = lower(text.slice(0, 600));
  const any = (re: RegExp) => re.test(s) || re.test(head);
  if (/\b(request|wants to book|would like to book|awaiting (your )?(approval|response))\b/.test(s) && !/\b(approved|accepted|confirmed)\b/.test(s)) return 'request';
  if (any(/\bcancel(l)?ed\b|\bcancellation (confirmed|notice)\b|\btrip (was|has been) cancel/)) return 'cancelled';
  if (any(/\bextended\b|\bextension (approved|accepted|confirmed)\b|\bextended (their|the|your) trip\b/)) return 'extended';
  if (any(/\b(changed|modified|updated|rescheduled)\b|\b(change|modification) (approved|accepted|confirmed)\b|\btrip (change|modification)\b/)) return 'changed';
  if (any(/\bbooked\b|\bnew (booking|trip|reservation)\b|\b(trip|reservation|booking) (is )?confirmed\b|\byou('| a)re booked\b/)) return 'booked';
  return 'other';
}

export function tripIdOf(text: string): string | null {
  const t = flat(text);
  return /turo\.com\/[^\s"'<>]*?\/(?:reservation|reservations|trips?|trip-details)\/(\d{5,12})/i.exec(t)?.[1]
    ?? /\b(?:reservation|trip|booking)\s*(?:id|number|no\.?|#)\s*[:#]?\s*#?\s*(\d{5,12})\b/i.exec(t)?.[1]
    ?? /\b(?:reservation|trip)\s*#\s*(\d{5,12})\b/i.exec(t)?.[1]
    ?? null;
}

const NOT_NAMES = new Set(["you're", 'you\u2019re', 'youre', 'your', 'the', 'turo', 'trip', 'guest', 'host', 'hi', 'hello', 'you', 'we', 'this', 'a', 'new', 'reservation', 'booking', 'good', 'great', 'congrats', 'congratulations', 'heads']);
export function guestOf(subject: string, text: string): string | null {
  const t = flat(`${subject}\n${text.slice(0, 1500)}`);
  const pats = [
    /\b([A-Z][a-zA-Z'-]{1,30})(?: [A-Z]\.?)? (?:has )?(?:booked|cancel(?:l)?ed|changed|modified|updated|extended|requested|wants to book)\b/,
    /\b(?:trip|booking|reservation) (?:with|from|for) ([A-Z][a-zA-Z'-]{1,30})\b/,
    /\bguest:?\s+([A-Z][a-zA-Z'-]{1,30})\b/i,
    /\b([A-Z][a-zA-Z'-]{1,30})['’]s (?:trip|booking|reservation)\b/
  ];
  for (const re of pats) {
    for (const m of t.matchAll(new RegExp(re.source, re.flags.includes('g') ? re.flags : re.flags + 'g'))) {
      const n = m[1];
      if (n && !NOT_NAMES.has(lower(n))) return n.slice(0, 40);
    }
  }
  return null;
}

// the start and end: labelled ("Trip start", "Pickup", "New end"), then a range "A to B", then the first two times
const START_LABEL = /\b(?:(?:new|updated)\s+)?(?:trip\s+start(?:s)?|start(?:s| date| time)?|pick-?\s?up|check-?in|begins?)\b\s*[:\-]?\s*/gi;
const END_LABEL = /\b(?:(?:new|updated)\s+)?(?:trip\s+end(?:s)?|end(?:s| date| time)?|return(?:s)?|drop-?\s?off|check-?out|until|now ends?|extended (?:until|to|through)|through)\b\s*[:\-]?\s*/gi;

function labelled(text: string, re: RegExp, dates: FoundDate[]): FoundDate | null {
  let best: FoundDate | null = null;
  let bestNew = false;
  re.lastIndex = 0;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    const after = m.index + m[0].length;
    const d = dates.find((x) => x.index >= after && x.index - after <= 40);
    if (!d) continue;
    const isNew = /\b(new|updated|now|extended)\b/i.test(m[0]);
    // the newest wording wins (a change email lists the old dates too); otherwise the first
    if (!best || (isNew && !bestNew)) { best = d; bestNew = isNew; }
  }
  return best;
}

export function datesOf(kind: TuroKind, text: string, emailDate: Date): { start: Date | null; end: Date | null } {
  const t = flat(text);
  const all = findDates(t, emailDate).filter((d) => d.hasTime);
  let start = labelled(t, START_LABEL, all);
  let end = labelled(t, END_LABEL, all);
  if (start && end && end.at <= start.at) end = all.find((d) => d.at > start!.at && d.index > start!.index) ?? null;
  if (!start || !end) {
    // a range: "Thu, Oct 22, 10:00 AM - Sun, Oct 25, 10:00 AM" or "... to ..."
    for (let i = 0; i + 1 < all.length; i++) {
      const gap = t.slice(all[i]!.end, all[i + 1]!.index);
      if (/^\s*(?:-|to|until|through|→|>)\s*$/i.test(gap) && all[i + 1]!.at > all[i]!.at) {
        // a change email may list the old range first: prefer a range after "new" or "updated"
        const before = t.slice(Math.max(0, all[i]!.index - 40), all[i]!.index);
        if (!start || !end || /\b(new|updated|now)\b/i.test(before)) { start = all[i]!; end = all[i + 1]!; }
      }
    }
  }
  if (kind === 'extended' && !end) end = labelled(t, /\b(?:new end|ends|until|through|to)\b\s*[:\-]?\s*/gi, all);
  return { start: start?.at ?? null, end: end?.at ?? null };
}

// ---------------------------------------------------------------- which car
const norm = (s: string) => lower(s).replace(/[^a-z0-9]+/g, ' ').trim();
const compact = (s: string) => lower(s).replace(/[^a-z0-9]+/g, '');

export function matchVehicle(subject: string, text: string, cars: MatchCar[]): { vehicleId: string | null; hint: string | null; why: string | null } {
  const all = `${subject}\n${text}`;
  const n = ` ${norm(all)} `;
  const c = compact(all);
  // a car's page on Turo: /ca/en/suv-rental/canada/toronto-on/mercedes-benz/glc-class/2711093, /car-rental/..., /vehicles/2711093
  const turoIds = new Set([...all.matchAll(/turo\.com\/[^\s"'<>]*?(?:-rental\/[^\s"'<>]*?|\/vehicles?|\/listings?)\/(\d{5,12})\b/gi)].map((m) => m[1]!));
  const scored: Array<{ car: MatchCar; score: number; why: string }> = [];
  for (const car of cars) {
    let score = 0, why = '';
    const hit = (s: number, w: string) => { if (s > score) { score = s; why = w; } };
    if (car.turo_vehicle_id && turoIds.has(car.turo_vehicle_id)) hit(100, `Turo car ${car.turo_vehicle_id}`);
    if (car.vin && car.vin.length >= 11 && c.includes(compact(car.vin))) hit(95, 'VIN');
    if (car.plate && compact(car.plate).length >= 4 && new RegExp(`(^|[^a-z0-9])${compact(car.plate).split('').join('[ -]?')}([^a-z0-9]|$)`, 'i').test(all)) hit(90, `plate ${car.plate}`);
    if (car.listing_name && norm(car.listing_name).length >= 4 && n.includes(` ${norm(car.listing_name)} `)) hit(80 + Math.min(9, norm(car.listing_name).length / 10), `Turo listing name "${car.listing_name}"`);
    if (car.make && car.model) {
      const mk = norm(car.make), md = norm(car.model);
      // the model's first real word ("glc" of GLC 300, "300" of C 300): two GLCs then tie, and the email goes to review
      const key = md.split(' ').find((w) => w.length > 1);
      const hasModel = !!key && n.includes(` ${key}`);
      if (n.includes(` ${mk.split(' ')[0]}`) && hasModel) hit(car.year && n.includes(` ${car.year} `) ? 50 : 40, `${car.year ?? ''} ${car.make} ${car.model}`.trim());
    }
    if (score) scored.push({ car, score, why });
  }
  scored.sort((a, b) => b.score - a.score);
  const top = scored[0];
  if (!top) return { vehicleId: null, hint: vehicleText(subject, text), why: null };
  const tied = scored.filter((s) => s.score === top.score);
  if (tied.length > 1) return { vehicleId: null, hint: vehicleText(subject, text) ?? top.why, why: `matches ${tied.length} cars (${tied.map((t) => t.car.name).join(', ')})` };
  // make and model alone are a guess only when the email names no other car
  return { vehicleId: top.car.vehicle_id, hint: top.car.name, why: top.why };
}

/** What the email calls the car (for the review list), e.g. "Mercedes-Benz GLC 2021". */
export function vehicleText(subject: string, text: string): string | null {
  const t = flat(`${subject}\n${text.slice(0, 2000)}`);
  const m = /\byour ((?:(?:19|20)\d{2} )?[A-Z][A-Za-z-]+(?: [A-Z0-9][A-Za-z0-9-]*){1,4}(?: (?:19|20)\d{2})?)/.exec(t);
  return m ? m[1]!.slice(0, 80) : null;
}

// ---------------------------------------------------------------- one email
export function isFromTuro(m: Mime): boolean {
  if (/@([a-z0-9-]+\.)*turo\.com>?\s*$/i.test(m.from.trim())) return true;
  // forwarded by hand: the original "From:" line inside the text
  return /(?:^|\n)\s*(?:\*?From:?\*?)\s*[^\n]*@([a-z0-9-]+\.)*turo\.com/i.test(m.text.slice(0, 4000));
}

export function parseTuroEmail(m: Mime, cars: MatchCar[], now = new Date()): TuroParsed {
  // a hand-forwarded email: read the forwarded message, not the forwarding lines
  const fwd = /-{3,} ?Forwarded message ?-{3,}|Begin forwarded message:/i.exec(m.text);
  const text = fwd ? m.text.slice(fwd.index) : m.text;
  const subject = m.subject.replace(/^(?:(?:fwd?|fw|tr)\s*:\s*)+/i, '');
  const emailDate = m.date ?? now;
  const kind = classify(subject, text);
  const tripId = tripIdOf(text) ?? tripIdOf(subject);
  const { start, end } = kind === 'cancelled' || kind === 'other' ? { start: null, end: null } : datesOf(kind, text, emailDate);
  const v = matchVehicle(subject, text, cars);
  const missing: string[] = [];
  if (kind === 'booked' || kind === 'changed') { if (!start) missing.push('start'); if (!end) missing.push('end'); }
  if (kind === 'extended' && !end) missing.push('end');
  if (['booked', 'changed', 'extended', 'cancelled'].includes(kind) && !tripId) missing.push('trip id');
  if (['booked', 'changed', 'extended'].includes(kind) && !v.vehicleId) missing.push('car');
  return { kind, fromTuro: isFromTuro(m), tripId, start: start?.toISOString() ?? null, end: end?.toISOString() ?? null,
    guestFirstName: guestOf(subject, text), vehicleId: v.vehicleId, vehicleHint: v.hint, vehicleWhy: v.why, missing,
    sentAt: m.date?.toISOString() ?? null };
}

/** A short excerpt for an email someone must look at: no email addresses, phone numbers, links or long numbers other
 * than a trip id; at most 600 characters. */
export function redact(text: string, max = 600): string {
  return flat(text)
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, '[email]')
    .replace(/https?:\/\/\S+/gi, (u) => (/turo\.com\/[^\s]*?\/(\d{5,12})/i.test(u) ? `[Turo link ${/\/(\d{5,12})/.exec(u)?.[1]}]` : '[link]'))
    .replace(/(?:\+?1[ .-]?)?\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}\b|\+1\d{10}\b/g, '[phone]')
    .replace(/\n{2,}/g, '\n')
    .trim()
    .slice(0, max);
}

// ---------------------------------------------------------------- the model's help, when the rules fall short
export const AI_SYSTEM = 'You read one email that Turo sent to a car rental host. Return JSON only. Use only what the email says. ' +
  'kind: booked (a new confirmed trip), changed (trip dates changed and accepted), extended (trip end moved later and accepted), cancelled, request (waiting for the host), other. ' +
  'start and end: the trip times as written, in the form YYYY-MM-DD HH:MM (24-hour, the times in the email), or empty. trip_id: the Turo reservation number (digits) or empty. ' +
  'guest_first_name: the guest\'s first name only, or empty. car: how the email names the car (make, model, year), or empty.';
export const AI_SCHEMA = { type: 'object', additionalProperties: false, required: ['kind', 'start', 'end', 'trip_id', 'guest_first_name', 'car'], properties: {
  kind: { type: 'string', enum: ['booked', 'changed', 'extended', 'cancelled', 'request', 'other'] }, start: { type: 'string' }, end: { type: 'string' },
  trip_id: { type: 'string' }, guest_first_name: { type: 'string' }, car: { type: 'string' } } };
export interface AiAnswer { kind?: string; start?: string; end?: string; trip_id?: string; guest_first_name?: string; car?: string }

const localIso = (s: string | undefined): Date | null => {
  const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})$/.exec((s ?? '').trim());
  return m ? torontoToUtc(Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4]), Number(m[5])) : null;
};

/** Fills only what the rules left missing, and only with values that check out (a date the text contains, a trip id
 * that appears in the email, a first name of letters, a car that matches one of ours). */
export function mergeAi(p: TuroParsed, a: AiAnswer, m: Mime, cars: MatchCar[]): TuroParsed {
  const out: TuroParsed = { ...p, missing: [] };
  const kinds: TuroKind[] = ['booked', 'changed', 'extended', 'cancelled', 'request', 'other'];
  if (p.kind === 'other' && kinds.includes(a.kind as TuroKind)) out.kind = a.kind as TuroKind;
  const inText = (d: Date | null) => d && findDates(flat(m.text), m.date ?? new Date()).some((x) => Math.abs(x.at.getTime() - d.getTime()) < 60000);
  if (!out.start) { const d = localIso(a.start); if (inText(d)) out.start = d!.toISOString(); }
  if (!out.end) { const d = localIso(a.end); if (inText(d)) out.end = d!.toISOString(); }
  if (!out.tripId && a.trip_id && /^\d{5,12}$/.test(a.trip_id) && m.text.includes(a.trip_id)) out.tripId = a.trip_id;
  if (!out.guestFirstName && a.guest_first_name && /^[A-Za-z'-]{2,30}$/.test(a.guest_first_name) && !NOT_NAMES.has(lower(a.guest_first_name)) && m.text.includes(a.guest_first_name)) out.guestFirstName = a.guest_first_name;
  if (!out.vehicleId && a.car) {
    const v = matchVehicle(a.car, '', cars);
    if (v.vehicleId) { out.vehicleId = v.vehicleId; out.vehicleHint = v.hint; out.vehicleWhy = `${v.why} (read by the assistant)`; }
  }
  if (out.start && out.end && new Date(out.end) <= new Date(out.start)) out.end = null;
  if (out.kind === 'booked' || out.kind === 'changed') { if (!out.start) out.missing.push('start'); if (!out.end) out.missing.push('end'); }
  if (out.kind === 'extended' && !out.end) out.missing.push('end');
  if (['booked', 'changed', 'extended', 'cancelled'].includes(out.kind) && !out.tripId) out.missing.push('trip id');
  if (['booked', 'changed', 'extended'].includes(out.kind) && !out.vehicleId) out.missing.push('car');
  return out;
}

export const aiPrompt = (m: Mime) => `Subject: ${m.subject}\nSent: ${m.date?.toISOString() ?? 'unknown'}\n\n${redact(m.text, 5000)}`;
