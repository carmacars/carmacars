// Reading toll notices and statements (migration 0042): the text of a PDF (or a CSV) becomes lines with the
// issuer, the notice number, the plate, the date and time, the place, the amount, the fees and the due date.
// The rules come from the reading profiles in the database (Admin > Tolls > Reading profiles), so an issuer's
// layout is adjusted without code. Pure functions: the browser runs them, the unit tests check them.

export type Kind = 'toll_invoice' | 'ticket' | 'camera_offence' | 'parking' | 'fine' | 'tow' | 'impound';
export const KINDS: Array<[Kind, string]> = [['toll_invoice', 'Toll'], ['ticket', 'Ticket'], ['camera_offence', 'Camera offence'], ['parking', 'Parking'], ['fine', 'Fine'], ['tow', 'Tow'], ['impound', 'Impound']];
export type FieldKey = 'statement_number' | 'account_number' | 'statement_date' | 'due_on' | 'total' | 'authority' | 'notice_number' | 'plate' | 'transponder' | 'date' | 'time' | 'place' | 'amount' | 'fees';
export const FIELD_LABELS: Record<FieldKey, string> = {
  statement_number: 'Statement number', account_number: 'Account number', statement_date: 'Statement date', due_on: 'Due date', total: 'Total due',
  authority: 'Issuer', notice_number: 'Notice number', plate: 'Plate', transponder: 'Transponder', date: 'Date', time: 'Time', place: 'Location',
  amount: 'Amount', fees: 'Fees'
};
export interface Rules {
  layout?: 'statement' | 'single' | 'auto';
  detect?: string[];
  authority?: string;
  date_order?: 'auto' | 'ymd' | 'mdy' | 'dmy';
  fields?: Partial<Record<FieldKey, string[]>>;
  trip?: { skip_words?: string[]; statement_fee_words?: string[]; amount?: 'last' | 'first' | 'sum' };
}
export interface Profile { id: string; operator: string; name: string; source: 'csv' | 'pdf_text'; notice_kind: Kind; rules: Rules; priority: number; header_signature?: string; mapping?: Record<string, string>; date_format?: string | null; amount_unit?: string }
export interface TextLine { text: string; page: number; y: number; h?: number }
export interface Box { page: number; y: number; h: number }
export interface ReadLine {
  kind?: Kind; authority?: string | null; notice_number?: string | null; plate?: string | null; transponder?: string | null;
  /** Toronto wall-clock time, YYYY-MM-DDTHH:MM:00 (the database reads a time without a zone as Toronto time). */
  occurred_at?: string | null; time_unknown: boolean; place?: string | null; entry?: string | null; exit?: string | null;
  amount_cents?: number | null; fees_cents?: number | null; due_on?: string | null; confidence: number; source_text?: string; page?: number; box?: Box;
}
export interface ReadResult {
  profile: Profile | null; authority: string | null; kind: Kind; statement_number: string | null; account_number: string | null;
  statement_date: string | null; due_on: string | null; total_cents: number | null; lines: ReadLine[];
  statement_fees: Array<{ text: string; amount_cents: number }>; problems: string[]; layout: 'statement' | 'single';
}
export interface Ctx { plates: string[]; transponders?: string[]; today?: string }

const MONTHS: Record<string, number> = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12 };
const pad = (n: number) => String(n).padStart(2, '0');
const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
export const normPlate = (s: string | null | undefined) => (s ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '') || null;

// ---------------------------------------------------------------- values
/** Money on a line: "$12.34", "12.34", "1,234.50". A number followed by "km" is a distance, not money. */
export function moneyTokens(s: string): Array<{ cents: number; index: number; raw: string }> {
  const out: Array<{ cents: number; index: number; raw: string }> = [];
  const re = /(-?)\$?\s?(\d{1,3}(?:,\d{3})+|\d+)\.(\d{2})(?!\d)(?!\s?(?:km|kms|kilometres|kilometers|%))/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(s))) {
    const start = m.index + (m[0].length - m[0].trimStart().length);
    if (/[\d.,]/.test(s.slice(Math.max(0, start - 1), start))) continue;
    const cents = Number(m[2]!.replace(/,/g, '')) * 100 + Number(m[3]);
    if (!Number.isFinite(cents)) continue;
    out.push({ cents: m[1] === '-' ? -cents : cents, index: m.index, raw: m[0] });
  }
  return out;
}
export function parseMoney(s: string | null | undefined): number | null {
  if (!s) return null;
  const t = moneyTokens(s);
  if (t.length) return Math.abs(t[0]!.cents);
  const w = /\$\s?(\d{1,3}(?:,\d{3})+|\d+)(?![\d.])/.exec(s);
  return w ? Number(w[1]!.replace(/,/g, '')) * 100 : null;
}

export interface FoundDate { iso: string; index: number; raw: string; ambiguous: boolean }
/** The first date in a string: 2026-09-14, 09/14/2026, 14/09/2026, Sep 14, 2026, 14-Sep-2026, 14 September 2026. */
export function findDate(s: string, order: Rules['date_order'] = 'auto'): FoundDate | null {
  const cands: FoundDate[] = [];
  const ok = (y: number, m: number, d: number) => y >= 2000 && y <= 2099 && m >= 1 && m <= 12 && d >= 1 && d <= new Date(Date.UTC(y, m, 0)).getUTCDate();
  const push = (y: number, m: number, d: number, index: number, raw: string, ambiguous = false) => { if (ok(y, m, d)) cands.push({ iso: `${y}-${pad(m)}-${pad(d)}`, index, raw, ambiguous }); };
  let m: RegExpExecArray | null;
  const iso = /\b(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})\b/g;
  while ((m = iso.exec(s))) push(+m[1]!, +m[2]!, +m[3]!, m.index, m[0]);
  const num = /\b(\d{1,2})[-/.](\d{1,2})[-/.](20\d{2}|\d{2})\b/g;
  while ((m = num.exec(s))) {
    const a = +m[1]!, b = +m[2]!; let y = +m[3]!; if (y < 100) y += 2000;
    if (order === 'dmy') push(y, b, a, m.index, m[0]);
    else if (order === 'mdy') push(y, a, b, m.index, m[0]);
    else if (a > 12) push(y, b, a, m.index, m[0]);
    else if (b > 12) push(y, a, b, m.index, m[0]);
    else push(y, a, b, m.index, m[0], a !== b);
  }
  const mon = /\b(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(20\d{2})\b/gi;
  while ((m = mon.exec(s))) push(+m[3]!, MONTHS[m[1]!.toLowerCase()]!, +m[2]!, m.index, m[0]);
  const dmon = /\b(\d{1,2})(?:st|nd|rd|th)?[\s-]+(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?[\s,-]+(20\d{2})\b/gi;
  while ((m = dmon.exec(s))) push(+m[3]!, MONTHS[m[2]!.toLowerCase()]!, +m[1]!, m.index, m[0]);
  cands.sort((x, y) => x.index - y.index);
  return cands[0] ?? null;
}

/** The first time in a string: 8:12 PM, 20:12, 08:12:33, 8.12 p.m. Returns HH:MM on the 24-hour clock. */
export function findTime(s: string): { hhmm: string; index: number; raw: string } | null {
  const re = /\b(\d{1,2})[:h](\d{2})(?::(\d{2}))?\s*(a\.?\s?m\.?|p\.?\s?m\.?)?(?![\d/-])/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(s))) {
    let h = +m[1]!; const min = +m[2]!; const ap = m[4]?.toLowerCase().replace(/[.\s]/g, '');
    if (min > 59) continue;
    if (ap) { if (h < 1 || h > 12) continue; if (ap === 'pm' && h < 12) h += 12; if (ap === 'am' && h === 12) h = 0; }
    if (h > 23) continue;
    // a ratio such as 12:30 inside a date like 2026-12-30 is excluded by the look-ahead; a money amount has a dot, not a colon
    return { hhmm: `${pad(h)}:${pad(min)}`, index: m.index, raw: m[0] };
  }
  return null;
}

const PLATE_SHAPES = [/^[A-Z]{4}\d{3}$/, /^[A-Z]{3}\d{3}$/, /^\d{3}[A-Z]{3}$/, /^[A-Z]{2}\d{5}$/, /^[A-Z]{2}\d{4}$/, /^\d{2}[A-Z]{4}$/, /^[A-Z]\d{5}$/];
/** A plate on a line: one of the fleet's plates first (written with or without a space), else the shape of an Ontario plate. */
export function findPlate(s: string, fleet: Set<string>): { plate: string; inFleet: boolean; raw: string } | null {
  const toks = s.toUpperCase().split(/[^A-Z0-9]+/).filter(Boolean);
  const pairs: string[] = [];
  for (let i = 0; i < toks.length; i++) { pairs.push(toks[i]!); if (i + 1 < toks.length && toks[i]!.length <= 4 && toks[i + 1]!.length <= 4) pairs.push(toks[i]! + toks[i + 1]!); }
  for (const p of pairs) if (fleet.has(p)) return { plate: p, inFleet: true, raw: p };
  for (const p of pairs) if (/[A-Z]/.test(p) && /\d/.test(p) && PLATE_SHAPES.some((r) => r.test(p))) return { plate: p, inFleet: false, raw: p };
  return null;
}

// ---------------------------------------------------------------- labels
const labelRe = (label: string) => new RegExp(`(^|[^A-Za-z])${esc(label).replace(/\s+/g, '\\s*')}(?![A-Za-z])\\s*(?:no\\.?|number|#)?\\s*[:#.\\-]?\\s*`, 'i');
/** The text after a label on the same line, or the next line when the label stands alone. */
export function afterLabel(lines: TextLine[], labels: string[] | undefined): { value: string; line: TextLine; next?: TextLine } | null {
  if (!labels?.length) return null;
  // longer labels first, so "Payment Due Date" wins over "Due Date"
  const ordered = [...labels].sort((a, b) => b.length - a.length);
  for (const label of ordered) {
    const re = labelRe(label);
    for (let i = 0; i < lines.length; i++) {
      const l = lines[i]!;
      const m = re.exec(l.text);
      if (!m) continue;
      const rest = l.text.slice(m.index + m[0].length).trim();
      if (rest) return { value: rest, line: l, next: lines[i + 1] };
      const n = lines[i + 1];
      if (n && n.page === l.page) return { value: n.text.trim(), line: l, next: n };
    }
  }
  return null;
}
const firstWord = (s: string) => /^[#:\s]*([A-Z0-9][A-Z0-9\-/]{2,})/i.exec(s)?.[1]?.trim() ?? null;
/** A notice or statement number: the first run with a digit (a short prefix such as "PN" or "ST-" kept), not a date. */
const firstRef = (s: string) => {
  for (const seg of s.split(/\s{2,}|\s(?=[A-Z][a-z]+:)/)) {
    const re = /(?:^|[\s#:])((?:[A-Z]{1,4}[\s-]?)?\d[\dA-Z\-/]{2,}(?:[\s-][\dA-Z]{2,})?)/gi;
    let m: RegExpExecArray | null;
    while ((m = re.exec(seg))) { const w = m[1]!.trim(); if (!findDate(w)) return w; }
  }
  return firstWord(s);
};

// ---------------------------------------------------------------- profiles
/** The profile whose words appear most in the text (ties: the lower priority number); else the general one. */
export function pickProfile(text: string, profiles: Profile[]): Profile | null {
  const t = text.toLowerCase();
  let best: { p: Profile; score: number } | null = null;
  for (const p of profiles) {
    if (p.source !== 'pdf_text') continue;
    const words = p.rules.detect ?? [];
    const score = words.reduce((n, w) => n + (w && t.includes(w.toLowerCase()) ? 1 : 0), 0);
    if (score > 0 && (!best || score > best.score || (score === best.score && p.priority < best.p.priority))) best = { p, score };
  }
  if (best) return best.p;
  return profiles.filter((p) => p.source === 'pdf_text' && !(p.rules.detect ?? []).length).sort((a, b) => a.priority - b.priority)[0] ?? null;
}

// ---------------------------------------------------------------- reading
function remainder(text: string, cut: Array<string | undefined>): string {
  let r = text;
  for (const c of cut) if (c) r = r.replace(c, ' ');
  return r.replace(/\$?\s?\d{1,3}(?:,\d{3})*\.\d{2}/g, ' ').replace(/\b\d+(?:\.\d+)?\s?(?:km|kms|kilometres|kilometers)\b/gi, ' ').replace(/\s{2,}/g, '  ').trim();
}
function places(rest: string): { entry: string | null; exit: string | null; place: string | null } {
  const clean = rest.replace(/^[\s|,:-]+|[\s|,:-]+$/g, '');
  if (!clean) return { entry: null, exit: null, place: null };
  const parts = clean.split(/\s+(?:to|→|->|\u2013)\s+|\s{2,}|\s\|\s/).map((x) => x.trim()).filter((x) => x && /[A-Za-z]/.test(x));
  if (parts.length >= 2) return { entry: parts[0]!, exit: parts[1]!, place: null };
  return { entry: null, exit: null, place: parts[0] ?? clean };
}
const local = (date: string, time: string | null) => `${date}T${time ?? '00:00'}:00`;
const inWords = (text: string, words: string[] | undefined) => (words ?? []).some((w) => w && new RegExp(`(^|[^A-Za-z])${esc(w).replace(/\s+/g, '\\s*')}(?![A-Za-z])`, 'i').test(text));

/** How sure a line is (0 to 100), and why not more. */
export function lineConfidence(l: ReadLine, base: number, opts: { inFleet: boolean | null; ambiguousDate: boolean; needsNotice: boolean }): number {
  let c = base;
  if (!l.plate && !l.transponder) c -= 40; else if (opts.inFleet === false) c -= 25;
  if (!l.occurred_at) c -= 40; else if (l.time_unknown) c -= 10;
  if (opts.ambiguousDate) c -= 15;
  if (l.amount_cents == null) c -= 50;
  if (opts.needsNotice && !l.notice_number) c -= 20;
  return Math.max(0, Math.min(100, Math.round(c)));
}

/** Read the text of a notice or a statement with a profile. */
export function readText(lines: TextLine[], profile: Profile | null, ctx: Ctx): ReadResult {
  const rules: Rules = profile?.rules ?? { layout: 'auto' };
  const f = rules.fields ?? {};
  const order = rules.date_order ?? 'auto';
  const fleet = new Set(ctx.plates.map((p) => normPlate(p)!).filter(Boolean));
  const tags = new Set((ctx.transponders ?? []).map((t) => t.toUpperCase()));
  const all = lines.map((l) => l.text).join('\n');
  const problems: string[] = [];
  const kind: Kind = profile?.notice_kind ?? 'fine';

  const hText = (k: FieldKey) => { const a = afterLabel(lines, f[k]); return a ? firstRef(a.value) : null; };
  const hDate = (k: FieldKey) => { const a = afterLabel(lines, f[k]); return a ? (findDate(a.value, order) ?? (a.next ? findDate(a.next.text, order) : null))?.iso ?? null : null; };
  const hMoney = (k: FieldKey) => { const a = afterLabel(lines, f[k]); return a ? (parseMoney(a.value) ?? (a.next ? parseMoney(a.next.text) : null)) : null; };
  const authorityFound = (() => { const a = afterLabel(lines, f.authority); return a ? a.value.split(/\s{2,}/)[0]!.trim().slice(0, 80) : null; })();
  const authority = rules.authority || (profile && (profile.rules.detect ?? []).length ? profile.operator : null) || authorityFound || null;
  const statementPlate = (() => { const a = afterLabel(lines, f.plate); return a ? findPlate(a.value, fleet)?.plate ?? null : null; })();

  const head = {
    statement_number: hText('statement_number'), account_number: hText('account_number'), statement_date: hDate('statement_date'),
    due_on: hDate('due_on'), total_cents: hMoney('total')
  };

  // statement: every line with a date and an amount is a trip, unless its words say it is a total, a payment or a fee
  const trips: ReadLine[] = [];
  const statementFees: Array<{ text: string; amount_cents: number }> = [];
  if (rules.layout !== 'single') {
    const pick = rules.trip?.amount ?? 'last';
    for (const l of lines) {
      const money = moneyTokens(l.text).filter((t) => t.cents >= 0);
      const date = findDate(l.text, order);
      if (!money.length) continue;
      if (inWords(l.text, rules.trip?.statement_fee_words)) { statementFees.push({ text: l.text.trim(), amount_cents: money[money.length - 1]!.cents }); continue; }
      if (!date) continue;
      if (inWords(l.text, rules.trip?.skip_words) && !findTime(l.text)) continue;
      // a label line in the header ("Statement Date: ... Amount Due: $40.00") is not a trip
      if ([f.statement_date, f.due_on, f.total, f.statement_number].some((w) => inWords(l.text, w))) continue;
      const time = findTime(l.text.replace(date.raw, ' '));
      const plate = findPlate(l.text, fleet);
      const tag = l.text.toUpperCase().split(/[^A-Z0-9]+/).find((t) => tags.has(t)) ?? null;
      const first = money[0]!.cents, last = money[money.length - 1]!.cents;
      const amount = pick === 'first' ? first : pick === 'sum' ? money.reduce((n, t) => n + t.cents, 0) : last;
      const fees = pick === 'last' && money.length >= 2 && last > first ? last - first : null;
      const rest = remainder(l.text, [date.raw, time?.raw, plate?.raw, tag ?? undefined]);
      const where = places(rest.replace(new RegExp(`\\b${esc(plate?.raw ?? '#none#')}\\b`, 'i'), ' '));
      const line: ReadLine = {
        kind, authority, plate: plate?.plate ?? (tag ? null : statementPlate), transponder: tag, occurred_at: local(date.iso, time?.hhmm ?? null),
        time_unknown: !time, entry: where.entry, exit: where.exit, place: where.place, amount_cents: amount, fees_cents: fees,
        due_on: head.due_on, confidence: 0, source_text: l.text.trim().slice(0, 1000), page: l.page, box: { page: l.page, y: l.y, h: l.h ?? 0.02 }
      };
      line.confidence = lineConfidence(line, 92, { inFleet: line.plate ? fleet.has(normPlate(line.plate)!) : null, ambiguousDate: date.ambiguous, needsNotice: false });
      trips.push(line);
    }
  }

  let layout: 'statement' | 'single' = rules.layout === 'statement' ? 'statement' : 'single';
  if (rules.layout === 'auto' || !rules.layout) layout = trips.length >= 2 ? 'statement' : 'single';
  if (layout === 'statement') {
    if (!trips.length) problems.push('No trip lines were found: check the reading profile or read the notice by hand');
    if (head.total_cents != null && trips.length) {
      const sum = trips.reduce((n, t) => n + (t.amount_cents ?? 0), 0) + statementFees.reduce((n, x) => n + x.amount_cents, 0);
      if (sum !== head.total_cents) problems.push(`The lines add up to ${(sum / 100).toFixed(2)}, the statement says ${(head.total_cents / 100).toFixed(2)}`);
    }
    return { profile, authority, kind, ...head, lines: trips, statement_fees: statementFees, problems, layout };
  }

  // a single notice: each field from its label, else from the whole text
  const dateA = afterLabel(lines, f.date);
  const date = (dateA ? findDate(dateA.value, order) ?? (dateA.next ? findDate(dateA.next.text, order) : null) : null) ?? findDate(all.replace(/due date.*$/gim, ''), order);
  const timeA = afterLabel(lines, f.time);
  const time = (dateA ? findTime(dateA.value.replace(date?.raw ?? '#', ' ')) : null) ?? (timeA ? findTime(timeA.value) : null);
  const plateA = afterLabel(lines, f.plate);
  const plate = (plateA ? findPlate(plateA.value, fleet) : null) ?? findPlate(all, fleet);
  const amountA = afterLabel(lines, f.amount);
  let amount = amountA ? parseMoney(amountA.value) ?? (amountA.next ? parseMoney(amountA.next.text) : null) : null;
  let base = 88;
  if (amount == null) { const m = moneyTokens(all); if (m.length) { amount = Math.max(...m.map((x) => x.cents)); base -= 15; } }
  const feesA = afterLabel(lines, f.fees);
  const placeA = afterLabel(lines, f.place);
  const notice = hText('notice_number');
  const line: ReadLine = {
    kind, authority, notice_number: notice, plate: plate?.plate ?? null, transponder: null,
    occurred_at: date ? local(date.iso, time?.hhmm ?? null) : null, time_unknown: !time, place: placeA ? placeA.value.split(/\s{2,}/)[0]!.slice(0, 160) : null,
    entry: null, exit: null, amount_cents: amount, fees_cents: feesA ? parseMoney(feesA.value) : null, due_on: head.due_on, confidence: 0,
    source_text: [notice, plate?.raw, date?.raw, time?.raw, amountA?.value].filter(Boolean).join(' | ').slice(0, 1000),
    page: (dateA ?? plateA ?? amountA)?.line.page ?? 1, box: (dateA ?? plateA) ? { page: (dateA ?? plateA)!.line.page, y: (dateA ?? plateA)!.line.y, h: 0.03 } : undefined
  };
  line.confidence = lineConfidence(line, base, { inFleet: plate ? plate.inFleet : null, ambiguousDate: !!date?.ambiguous, needsNotice: kind !== 'toll_invoice' });
  if (!date && !plate && amount == null) problems.push('Nothing could be read from this text');
  return { profile, authority, kind, ...head, lines: date || plate || amount != null ? [line] : [], statement_fees: statementFees, problems, layout };
}

// ---------------------------------------------------------------- CSV (0021's column mapping, with the fees)
export const CSV_TARGETS: Array<[string, string]> = [['plate', 'Plate'], ['transponder', 'Transponder'], ['occurred_at', 'Date and time'], ['date', 'Date only'], ['time', 'Time only'], ['amount', 'Amount ($)'],
  ['fees', 'Fees ($)'], ['notice_number', 'Notice or transaction number'], ['external_ref', 'Other reference'], ['place', 'Place'], ['entry', 'Entry'], ['exit', 'Exit'], ['due_on', 'Due date']];

export function parseCsv(text: string): string[][] {
  const out: string[][] = []; let row: string[] = []; let cell = ''; let q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (q) { if (c === '"' && text[i + 1] === '"') { cell += '"'; i++; } else if (c === '"') q = false; else cell += c; continue; }
    if (c === '"') q = true; else if (c === ',') { row.push(cell); cell = ''; } else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(cell); cell = ''; if (row.some((x) => x.trim())) out.push(row); row = []; } else cell += c;
  }
  row.push(cell); if (row.some((x) => x.trim())) out.push(row);
  return out;
}

/** CSV rows to lines with a column mapping (column index to target). Dates follow the profile's date format. */
export function csvLines(rows: string[][], map: Record<string, string>, o: { kind: Kind; authority: string; dateOrder?: Rules['date_order']; plates: string[]; amountUnit?: string }): ReadLine[] {
  const fleet = new Set(o.plates.map((p) => normPlate(p)!).filter(Boolean));
  return rows.slice(1).map((r) => {
    const v: Record<string, string> = {};
    for (const [col, t] of Object.entries(map)) if (t) v[t] = (r[Number(col)] ?? '').trim();
    const whenText = v.occurred_at || [v.date, v.time].filter(Boolean).join(' ');
    const date = whenText ? findDate(whenText, o.dateOrder ?? 'auto') : null;
    const time = whenText ? findTime(date ? whenText.replace(date.raw, ' ') : whenText) : null;
    const money = (s?: string) => { if (!s) return null; if (o.amountUnit === 'cents' && /^\d+$/.test(s.trim())) return Number(s.trim()); const n = Number(s.replace(/[$,\s]/g, '')); return Number.isFinite(n) ? Math.round(n * 100) : null; };
    const plate = normPlate(v.plate);
    const line: ReadLine = {
      kind: o.kind, authority: o.authority, notice_number: v.notice_number || v.external_ref || null, plate, transponder: v.transponder || null,
      occurred_at: date ? local(date.iso, time?.hhmm ?? null) : null, time_unknown: !time, place: v.place || null, entry: v.entry || null, exit: v.exit || null,
      amount_cents: money(v.amount), fees_cents: money(v.fees), due_on: v.due_on ? findDate(v.due_on, o.dateOrder ?? 'auto')?.iso ?? null : null, confidence: 0,
      source_text: r.join(', ').slice(0, 1000)
    };
    line.confidence = lineConfidence(line, 96, { inFleet: plate ? fleet.has(plate) : null, ambiguousDate: !!date?.ambiguous, needsNotice: o.kind !== 'toll_invoice' });
    return line;
  });
}
