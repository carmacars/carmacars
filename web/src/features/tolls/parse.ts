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
/** A run of text on a line with its left and right edge as a fraction of the page width (pdf.js text items; 5140). */
export interface Cell { text: string; x0: number; x1: number }
export interface TextLine { text: string; page: number; y: number; h?: number; cells?: Cell[] }
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
export function findDate(s: string, order: Rules['date_order'] = 'auto', year?: number | null): FoundDate | null {
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
  const mon = /\b(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(20\d{2}|\d{2})\b(?![:.]\d)/gi;
  while ((m = mon.exec(s))) push(+m[3]! % 100 + 2000, MONTHS[m[1]!.toLowerCase()]!, +m[2]!, m.index, m[0]);
  const dmon = /\b(\d{1,2})(?:st|nd|rd|th)?[\s-]+(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?[\s,-]+(20\d{2}|\d{2})\b(?![:.]\d)/gi;
  while ((m = dmon.exec(s))) push(+m[3]! % 100 + 2000, MONTHS[m[2]!.toLowerCase()]!, +m[1]!, m.index, m[0]);
  // 5140: a statement table may print the day without the year ("Nov 03", "03-Nov", "11/03"): the statement's year
  if (!cands.length && year) {
    const md = /\b(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?[\s-]+(\d{1,2})(?:st|nd|rd|th)?\b(?![\s,-]*(?:\d{3,}|\d{1,2}(?![:.\d])))/gi;
    while ((m = md.exec(s))) push(year, MONTHS[m[1]!.toLowerCase()]!, +m[2]!, m.index, m[0]);
    const dm = /\b(\d{1,2})(?:st|nd|rd|th)?[\s-]+(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\b(?![\s,-]*(?:\d{3,}|\d{1,2}(?![:.\d])))/gi;
    while ((m = dm.exec(s))) push(year, MONTHS[m[2]!.toLowerCase()]!, +m[1]!, m.index, m[0]);
    const nm = /\b(\d{1,2})[/-](\d{1,2})\b(?![/.-]?\d)/g;
    while ((m = nm.exec(s))) { const a = +m[1]!, b = +m[2]!; if (order === 'dmy' || a > 12) push(year, b, a, m.index, m[0]); else push(year, a, b, m.index, m[0], b <= 12 && a !== b && order !== 'mdy'); }
  }
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

// ---------------------------------------------------------------- columns (5140)
// A statement is a table. Its header names each column (Date, Time, Entry, Exit, Distance, Plate, Toll, Camera or video
// charge, Trip toll charge, Total), so each value is read from its own column, never guessed from its place on the line:
// a distance printed without "km" is not money, the fees are the fee columns, the total is the total column, and a
// plate printed once above its trips belongs to each of them. The PDF reader gives each run of text its position; a CSV
// gives its columns. Column words are English as 407 ETR, the cities and Ontario print them.
export type Col = 'date' | 'time' | 'datetime' | 'entry' | 'exit' | 'plate' | 'transponder' | 'distance' | 'toll' | 'fee' | 'total' | 'ref' | 'place' | 'skip';
const has = (s: string, re: RegExp) => re.test(s);
/** What a column header names; null: not a column the reader uses. */
export function classifyHeader(h: string): Col | null {
  const s = h.toLowerCase().replace(/[_\s]+/g, ' ').trim();
  if (!s || s.length > 40) return null;
  const exitish = has(s, /\b(exit|off|destination|end)\b/), entryish = has(s, /\b(entry|enter|entrance|on|from|origin|start)\b/);
  if (has(s, /\b(km|kms|distance|kilomet\w*)\b/)) return 'distance';
  if (has(s, /\b(plate|licen[cs]e)\b/)) return 'plate';
  if (has(s, /transponder|\btag\b/)) return 'transponder';
  if (has(s, /date/) && has(s, /time/)) return exitish && !entryish ? 'skip' : 'datetime';
  if (has(s, /\btime\b/)) return exitish && !entryish ? 'skip' : 'time';
  if (has(s, /\b(date|day)\b/)) return exitish && !entryish || has(s, /\b(due|posted|statement|payment)\b/) ? 'skip' : 'date';
  if (has(s, /\b(total|amount due|balance)\b/)) return 'total';
  if (has(s, /camera|video|trip toll|trip charge|\bfees?\b|admin|surcharge|processing|\bplate charge/)) return 'fee';
  if (has(s, /\b(toll|tolls|charge|charges|amount|cost|price|fare|fine|penalty)\b/)) return 'toll';
  if (has(s, /\b(class|axle|type|zone|rate)\b/)) return 'skip';
  if (exitish || s === 'to') return 'exit';
  if (entryish || s === 'from') return 'entry';
  if (has(s, /\b(trip|transaction|reference|ref|notice|invoice|ticket|journey)\b/)) return 'ref';
  if (has(s, /location|plaza|interchange|description|road|highway|place|gantry|where/)) return 'place';
  return null;
}
const isHeader = (roles: Array<Col | null>) => {
  const r = roles.filter((x) => x && x !== 'skip') as Col[];
  return r.length >= 3 && r.some((x) => x === 'date' || x === 'datetime') && r.some((x) => x === 'toll' || x === 'fee' || x === 'total');
};
/** The CSV row that is the header (a 407 ETR download starts with the account's details above it); -1: none. */
export function headerRow(rows: string[][]): number {
  for (let i = 0; i < Math.min(rows.length, 40); i++) if (isHeader(rows[i]!.map(classifyHeader)) && !rows[i]!.some((c) => findDate(c))) return i;
  return -1;
}
const TARGET: Partial<Record<Col, string>> = { date: 'date', time: 'time', datetime: 'occurred_at', entry: 'entry', exit: 'exit', plate: 'plate', transponder: 'transponder',
  toll: 'amount', fee: 'fees', total: 'total', ref: 'notice_number', place: 'place' };
/** The column mapping a header suggests: column index to target; several fee columns all count as fees. */
export function autoMap(header: string[]): Record<string, string> {
  const map: Record<string, string> = {};
  header.forEach((h, i) => {
    const t = TARGET[classifyHeader(h) ?? 'skip'];
    if (t && (t === 'fees' || !Object.values(map).includes(t))) map[String(i)] = t;
  });
  return map;
}

const cellsOf = (l: TextLine): Cell[] => l.cells ?? [];
interface Column { role: Col; x0: number; x1: number; text: string }
function columnsOf(cells: Cell[]): Column[] {
  return cells.map((c) => ({ role: classifyHeader(c.text) as Col, x0: c.x0, x1: c.x1, text: c.text })).filter((c) => c.role);
}
/** A header printed on two lines ("Trip" over "Toll Charge"): the words of the line under it join the column above them. */
function mergeHeader(a: Cell[], b: Cell[]): Cell[] {
  const out = a.map((c) => ({ ...c }));
  for (const c of b) {
    const over = out.map((o) => ({ o, w: Math.min(o.x1, c.x1) - Math.max(o.x0, c.x0) })).sort((x, y) => y.w - x.w)[0];
    if (over && over.w > 0) { over.o.text = `${over.o.text} ${c.text}`; over.o.x0 = Math.min(over.o.x0, c.x0); over.o.x1 = Math.max(over.o.x1, c.x1); } else out.push({ ...c });
  }
  return out.sort((x, y) => x.x0 - y.x0);
}
const plain = (l: TextLine | undefined) => !!l && !findDate(l.text) && !moneyTokens(l.text).length;
function columnFor(cols: Column[], c: Cell): Column | null {
  let best: Column | null = null; let bw = 0;
  for (const k of cols) { const w = Math.min(k.x1, c.x1) - Math.max(k.x0, c.x0); if (w > bw) { bw = w; best = k; } }
  if (best) return best;
  const mid = (c.x0 + c.x1) / 2;
  return cols.reduce<Column | null>((b, k) => (!b || Math.abs((k.x0 + k.x1) / 2 - mid) < Math.abs((b.x0 + b.x1) / 2 - mid) ? k : b), null);
}
const TOTAL_ROW = /^\s*(sub\s?total|total|balance|amount due|page \d|continued)/i;

/** The trips of a statement read by its columns; null when the text has no table header (the line reader then runs). */
function readTable(lines: TextLine[], o: { kind: Kind; authority: string | null; fleet: Set<string>; tags: Set<string>; order: Rules['date_order']; year: number | null;
  plateLabels: string[]; feeWords: string[] | undefined; skipWords: string[] | undefined; due: string | null; statementPlate: string | null; statementDate: string | null }): { trips: ReadLine[]; fees: Array<{ text: string; amount_cents: number }>; problems: string[] } | null {
  // only text with positions (a PDF's text layer) is read by columns; typed or pasted text keeps the line reader
  if (!lines.some((l) => l.cells?.length)) return null;
  const trips: ReadLine[] = []; const fees: Array<{ text: string; amount_cents: number }> = []; const problems: string[] = [];
  let cols: Column[] | null = null; let found = false; let groupPlate: string | null = null;
  type Rec = { vals: Partial<Record<Col, string[]>>; src: string[]; line: TextLine };
  let rec: Rec | null = null;
  const plateLabel = new RegExp(`(^|[^A-Za-z])(${[...o.plateLabels, 'Licence Plate', 'License Plate', 'Plate Number', 'Plate', 'Vehicle'].map(esc).join('|')})(?![A-Za-z])`, 'i');
  const flush = () => {
    if (!rec) return;
    const r = rec; rec = null;
    const get = (k: Col) => (r.vals[k] ?? []).join(' ').trim();
    const money = (k: Col) => (r.vals[k] ?? []).map((t) => moneyTokens(t)).flat();
    const date = findDate(get('date') || get('datetime'), o.order, o.year);
    if (!date) return;
    // a day printed without its year that falls after the statement date is from the year before (December on a January statement)
    if (!/\d{4}/.test(date.raw) && o.statementDate && date.iso > o.statementDate) date.iso = `${Number(date.iso.slice(0, 4)) - 1}${date.iso.slice(4)}`;
    const time = findTime((get('time') || get('datetime')).replace(date.raw, ' '));
    const toll = money('toll'), fee = money('fee'), total = money('total');
    const sum = (t: Array<{ cents: number }>) => t.reduce((n, x) => n + x.cents, 0);
    if ([...toll, ...fee, ...total].some((t) => t.cents < 0)) { problems.push(`A credit or reversal was left out: ${r.src.join(' ').slice(0, 160)}`); return; }
    if (!toll.length && !fee.length && !total.length) return;
    const feeC = fee.length ? sum(fee) : null;
    let amount = total.length ? total[total.length - 1]!.cents : sum(toll) + (feeC ?? 0);
    let feesOut = feeC ?? (total.length && toll.length && total[total.length - 1]!.cents > sum(toll) ? total[total.length - 1]!.cents - sum(toll) : null);
    let base = 95;
    if (total.length && (toll.length || fee.length) && sum(toll) + (feeC ?? 0) !== amount) { base -= 20; problems.push(`The charges on the line of ${date.iso} add up to ${((sum(toll) + (feeC ?? 0)) / 100).toFixed(2)}, its total says ${(amount / 100).toFixed(2)}`); }
    if (amount === 0) { amount = sum(toll); feesOut = feeC; }
    const plateCell = get('plate'); const p = plateCell ? findPlate(plateCell, o.fleet) : null;
    const tagText = get('transponder').toUpperCase().replace(/[^A-Z0-9]/g, '');
    const tag = tagText ? ([...o.tags].find((t) => t.replace(/[^A-Z0-9]/g, '') === tagText) ?? tagText) : null;
    const plate = p?.plate ?? (plateCell ? normPlate(plateCell) : null) ?? (tag ? null : groupPlate ?? o.statementPlate);
    const line: ReadLine = {
      kind: o.kind, authority: o.authority, notice_number: get('ref') || null, plate, transponder: tag, occurred_at: local(date.iso, time?.hhmm ?? null), time_unknown: !time,
      entry: get('entry') || null, exit: get('exit') || null, place: get('place') || null, amount_cents: amount, fees_cents: feesOut && feesOut > 0 ? feesOut : null,
      due_on: o.due, confidence: 0, source_text: r.src.join(' ').replace(/\s+/g, ' ').trim().slice(0, 1000), page: r.line.page, box: { page: r.line.page, y: r.line.y, h: r.line.h ?? 0.02 }
    };
    line.confidence = lineConfidence(line, base, { inFleet: plate ? o.fleet.has(normPlate(plate)!) : null, ambiguousDate: date.ambiguous, needsNotice: o.kind !== 'toll_invoice' });
    trips.push(line);
  };
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i]!; const cells = cellsOf(l);
    // a header, alone or on two lines; it repeats at the top of each page
    let head = false;
    if (plain(l)) for (const cand of [cells, plain(lines[i + 1]) && lines[i + 1]!.page === l.page ? mergeHeader(cells, cellsOf(lines[i + 1]!)) : null]) {
      if (!cand) continue;
      const c = columnsOf(cand);
      if (isHeader(c.map((x) => x.role))) { flush(); cols = c; found = true; head = true; if (cand !== cells) i++; break; }
    }
    if (head) continue;
    if (!cols) {
      // before the table: "Licence Plate: ABCD 123" heads the trips under it
      if (plateLabel.test(l.text) && !moneyTokens(l.text).length) { const p = findPlate(l.text.replace(plateLabel, ' '), o.fleet); if (p) groupPlate = p.plate; }
      continue;
    }
    const money = moneyTokens(l.text);
    if (inWords(l.text, o.feeWords) && money.length) { flush(); fees.push({ text: l.text.trim(), amount_cents: money[money.length - 1]!.cents }); continue; }
    if (TOTAL_ROW.test(l.text) || (inWords(l.text, o.skipWords) && !findTime(l.text) && !findDate(l.text, o.order, o.year))) { flush(); continue; }
    // a plate heading inside the table: the trips under it are that car's
    if (!money.length && !findDate(l.text, o.order, o.year) && plateLabel.test(l.text)) { const p = findPlate(l.text.replace(plateLabel, ' '), o.fleet); if (p) { flush(); groupPlate = p.plate; continue; } }
    const byCol: Partial<Record<Col, string[]>> = {};
    for (const c of cells) { const k = columnFor(cols, c); if (k) (byCol[k.role] ??= []).push(c.text); }
    const dated = !!findDate([...(byCol.date ?? []), ...(byCol.datetime ?? [])].join(' '), o.order, o.year);
    if (dated) { flush(); rec = { vals: byCol, src: [l.text], line: l }; continue; }
    // no date: the rest of the trip above (a place name on two lines, or its charges printed under it)
    if (rec && l.page === rec.line.page) {
      for (const [k, v] of Object.entries(byCol) as Array<[Col, string[]]>) {
        const isMoney = k === 'toll' || k === 'fee' || k === 'total';
        if (isMoney && (rec.vals[k] ?? []).some((t) => moneyTokens(t).length)) continue;
        (rec.vals[k] ??= []).push(...v);
      }
      rec.src.push(l.text);
    }
  }
  flush();
  return found ? { trips, fees, problems } : null;
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
  const year = Number((head.statement_date ?? head.due_on ?? ctx.today ?? '').slice(0, 4)) || null;
  const table = rules.layout !== 'single' ? readTable(lines, { kind, authority, fleet, tags, order: inferOrder(lines.map((l) => l.text), order), year, plateLabels: f.plate ?? [], feeWords: rules.trip?.statement_fee_words,
    skipWords: rules.trip?.skip_words, due: head.due_on, statementPlate, statementDate: head.statement_date }) : null;
  if (table && table.trips.length) {
    const problems = [...table.problems];
    if (head.total_cents != null) {
      const sum = table.trips.reduce((n, t) => n + (t.amount_cents ?? 0), 0) + table.fees.reduce((n, x) => n + x.amount_cents, 0);
      if (sum !== head.total_cents) problems.push(`The lines add up to ${(sum / 100).toFixed(2)}, the statement says ${(head.total_cents / 100).toFixed(2)}`);
    }
    return { profile, authority, kind, ...head, lines: table.trips, statement_fees: table.fees, problems, layout: 'statement' };
  }
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
export const CSV_TARGETS: Array<[string, string]> = [['plate', 'Plate'], ['transponder', 'Transponder'], ['occurred_at', 'Date and time'], ['date', 'Date only'], ['time', 'Time only'], ['amount', 'Charge ($)'],
  ['fees', 'Fee ($), each fee column'], ['total', 'Line total ($)'], ['notice_number', 'Notice or transaction number'], ['external_ref', 'Other reference'], ['place', 'Place'], ['entry', 'Entry'], ['exit', 'Exit'], ['due_on', 'Due date']];

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

/** The order of numeric dates in a file, from any date that can only be read one way (13/11/2026 is day first). */
export function inferOrder(texts: string[], order: Rules['date_order'] = 'auto'): Rules['date_order'] {
  if (order && order !== 'auto') return order;
  for (const t of texts) {
    const m = /\b(\d{1,2})[-/.](\d{1,2})[-/.](?:20)?\d{2}\b/.exec(t);
    if (m && +m[1]! > 12 && +m[2]! <= 12) return 'dmy';
    if (m && +m[2]! > 12 && +m[1]! <= 12) return 'mdy';
  }
  return 'auto';
}

/** CSV rows to lines with a column mapping (column index to target), the rows under the header row (5140). Dates follow the
 *  profile's date format. A line's amount is what the renter owes for it: the total column, else the charge plus every fee
 *  column; the fees are the fee columns (or the total less the charge). Rows without a date or a charge (a summary, a
 *  payment) are left out; a credit is left out and said. */
export function csvLines(rows: string[][], map: Record<string, string>, o: { kind: Kind; authority: string; dateOrder?: Rules['date_order']; plates: string[]; amountUnit?: string; header?: number }): { lines: ReadLine[]; problems: string[] } {
  const fleet = new Set(o.plates.map((p) => normPlate(p)!).filter(Boolean));
  const problems: string[] = [];
  const lines: ReadLine[] = [];
  const dateCols = Object.entries(map).filter(([, t]) => t === 'date' || t === 'occurred_at').map(([c]) => Number(c));
  const order = inferOrder(rows.slice((o.header ?? 0) + 1).flatMap((r) => dateCols.map((c) => r[c] ?? '')), o.dateOrder);
  const money = (s?: string) => {
    if (!s || !s.trim()) return null;
    const t = s.trim(); if (o.amountUnit === 'cents' && /^-?\d+$/.test(t)) return Number(t);
    const neg = /^\(.*\)$/.test(t) || /^-/.test(t.replace(/^\$/, ''));
    const n = Number(t.replace(/[$,\s()-]/g, '')); return Number.isFinite(n) ? Math.round(n * 100) * (neg ? -1 : 1) : null;
  };
  for (const r of rows.slice((o.header ?? 0) + 1)) {
    const v: Record<string, string[]> = {};
    for (const [col, t] of Object.entries(map)) if (t) (v[t] ??= []).push((r[Number(col)] ?? '').trim());
    const one = (k: string) => (v[k] ?? []).filter(Boolean).join(' ');
    const whenText = one('occurred_at') || [one('date'), one('time')].filter(Boolean).join(' ');
    const date = whenText ? findDate(whenText, order) : null;
    const time = whenText ? findTime(date ? whenText.replace(date.raw, ' ') : whenText) : null;
    const charges = (v.amount ?? []).map(money).filter((x): x is number => x != null);
    const fees = (v.fees ?? []).map(money).filter((x): x is number => x != null);
    const total = (v.total ?? []).map(money).filter((x): x is number => x != null);
    if (!date || (!charges.length && !fees.length && !total.length)) continue;
    if ([...charges, ...fees, ...total].some((x) => x < 0)) { problems.push(`A credit or reversal was left out: ${r.join(', ').slice(0, 160)}`); continue; }
    const charge = charges.reduce((n, x) => n + x, 0); const fee = fees.length ? fees.reduce((n, x) => n + x, 0) : null;
    const amount = total.length ? total[total.length - 1]! : charge + (fee ?? 0);
    const feesOut = fee ?? (total.length && charges.length && amount > charge ? amount - charge : null);
    if (amount === 0) continue;
    const p = one('plate') ? findPlate(one('plate'), fleet) : null;
    const plate = p?.plate ?? normPlate(one('plate'));
    const line: ReadLine = {
      kind: o.kind, authority: o.authority, notice_number: one('notice_number') || one('external_ref') || null, plate, transponder: one('transponder') || null,
      occurred_at: local(date.iso, time?.hhmm ?? null), time_unknown: !time, place: one('place') || null, entry: one('entry') || null, exit: one('exit') || null,
      amount_cents: amount, fees_cents: feesOut && feesOut > 0 ? feesOut : null, due_on: one('due_on') ? findDate(one('due_on'), order)?.iso ?? null : null, confidence: 0,
      source_text: r.join(', ').slice(0, 1000)
    };
    let base = 96;
    if (total.length && (charges.length || fees.length) && charge + (fee ?? 0) !== amount) { base -= 20; problems.push(`The charges on the row of ${date.iso} add up to ${((charge + (fee ?? 0)) / 100).toFixed(2)}, its total says ${(amount / 100).toFixed(2)}`); }
    line.confidence = lineConfidence(line, base, { inFleet: plate ? fleet.has(plate) : null, ambiguousDate: !!date?.ambiguous, needsNotice: o.kind !== 'toll_invoice' });
    lines.push(line);
  }
  return { lines, problems };
}
