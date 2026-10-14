// What the vision model is asked (migration 0042), and how its answer is checked before anyone sees it: a
// scanned notice or statement page becomes lines in the same shape as the text reader's, and a listing photo
// becomes plate boxes. A value the model could not read stays empty; nothing is made up here. Pure functions.
import { findDate, findTime, KINDS, lineConfidence, normPlate, parseMoney, type Kind, type ReadLine } from './parse.ts';

export const TOLL_SYSTEM = 'You read Ontario toll and traffic notices: 407 ETR statements, parking and administrative penalty notices, red light and speed camera notices, and provincial offence notices. Answer with JSON only, in the shape asked. Copy each value exactly as printed. Use null for anything you cannot read clearly. Never guess a plate, a number or an amount.';
export const TOLL_PROMPT = `Read this page of a notice or statement. Answer with one JSON object with every key below, using null for anything not printed or not readable:
{"issuer": "who issued it, as printed", "kind": "toll_invoice or ticket or camera_offence or parking or fine", "statement_number": "as printed", "account_number": "as printed", "notice_number": "as printed", "due_date": "YYYY-MM-DD", "total": 0.00,
 "lines": [{"notice_number": "as printed", "plate": "letters and digits only", "date": "YYYY-MM-DD", "time": "HH:MM on the 24-hour clock", "location": "as printed", "entry": "as printed", "exit": "as printed", "amount": 0.00, "fees": 0.00, "confidence": 0}]}
"lines" has one entry per toll trip or offence: a notice for one offence has one line. "amount" is the line's total in dollars as a number; "fees" is the part of it that is fees, or null; "total" is the amount due on the page. "confidence" is 0 to 100: how sure you are of that line. A page with no trips or offences has "lines": [].`;
export const TOLL_SCHEMA = {
  type: 'object',
  properties: {
    issuer: { type: ['string', 'null'] }, kind: { type: ['string', 'null'] }, statement_number: { type: ['string', 'null'] }, account_number: { type: ['string', 'null'] },
    notice_number: { type: ['string', 'null'] }, due_date: { type: ['string', 'null'] }, total: { type: ['number', 'string', 'null'] },
    lines: { type: 'array', items: { type: 'object', properties: {
      notice_number: { type: ['string', 'null'] }, plate: { type: ['string', 'null'] }, date: { type: ['string', 'null'] }, time: { type: ['string', 'null'] },
      location: { type: ['string', 'null'] }, entry: { type: ['string', 'null'] }, exit: { type: ['string', 'null'] }, amount: { type: ['number', 'string', 'null'] },
      fees: { type: ['number', 'string', 'null'] }, confidence: { type: ['number', 'null'] } } } }
  },
  required: ['lines']
} as const;

export const PLATE_SYSTEM = 'You find licence plates in photos of cars. Answer with JSON only, in the shape asked.';
export const PLATE_PROMPT = 'Find every licence plate visible in this photo (the front or rear plate of any car). Answer with one JSON object: {"plates": [{"x": 0.0, "y": 0.0, "w": 0.0, "h": 0.0, "confidence": 0}]}, one entry per plate, every key present. x and y are the left and top edges of the plate and w and h its width and height, each as a fraction of the image width or height (numbers from 0 to 1). confidence is 0 to 100. Answer {"plates": []} when no plate can be seen.';
/** With the image's size known, the corners in pixels: in live tests (0042) the model placed a fractional box below the plate. */
export const platePrompt = (size?: { width: number; height: number } | null) => (size && size.width > 0 && size.height > 0
  ? `This photo is ${Math.round(size.width)} pixels wide and ${Math.round(size.height)} pixels high. Find every licence plate visible in it (the front or rear plate of any car). Answer with one JSON object: {"plates": [{"x1": 0, "y1": 0, "x2": 0, "y2": 0, "confidence": 0}]}, one entry per plate, every key present: x1 and y1 are the pixel position of the plate's top left corner, x2 and y2 of its bottom right corner (x from the left edge, y from the top edge). confidence is 0 to 100. Answer {"plates": []} when no plate can be seen.`
  : PLATE_PROMPT);
export const PLATE_SCHEMA = {
  type: 'object',
  properties: { plates: { type: 'array', items: { type: 'object', properties: { x: { type: 'number' }, y: { type: 'number' }, w: { type: 'number' }, h: { type: 'number' }, confidence: { type: ['number', 'null'] } } } } },
  required: ['plates']
} as const;

type Obj = Record<string, unknown>;
const str = (v: unknown): string | null => (typeof v === 'string' && v.trim() && !/^(null|n\/a|none|unknown|-)$/i.test(v.trim()) ? v.trim().slice(0, 200) : typeof v === 'number' ? String(v) : null);
const cents = (v: unknown): number | null => {
  if (typeof v === 'number' && Number.isFinite(v) && v >= 0 && v < 1_000_000) return Math.round(v * 100);
  if (typeof v === 'string') { const n = parseMoney(v.includes('.') ? v : `${v}.00`); return n != null && n < 100_000_000 ? n : null; }
  return null;
};
const isKind = (k: unknown): k is Kind => KINDS.some(([x]) => x === k);

export interface VisionRead { authority: string | null; kind: Kind; statement_number: string | null; account_number: string | null; due_on: string | null; total_cents: number | null; lines: ReadLine[]; problems: string[] }

/** The model's answer for one page, checked: dates and times re-read, amounts in cents, plates as letters and digits. */
export function normalizeTollVision(data: unknown, o: { page: number; plates: string[]; fallbackKind?: Kind }): VisionRead {
  const d = (data && typeof data === 'object' && !Array.isArray(data) ? data : {}) as Obj;
  const fleet = new Set(o.plates.map((p) => normPlate(p)!).filter(Boolean));
  const issuer = str(d.issuer);
  const kind: Kind = isKind(d.kind) ? d.kind : issuer && /407/.test(issuer) ? 'toll_invoice' : (o.fallbackKind ?? 'fine');
  const due = str(d.due_date) ? findDate(str(d.due_date)!)?.iso ?? null : null;
  const problems: string[] = [];
  const raw = Array.isArray(d.lines) ? d.lines.slice(0, 300) : [];
  if (!Array.isArray(d.lines)) problems.push('The model did not return any lines for this page');
  const lines: ReadLine[] = [];
  for (const x of raw) {
    if (!x || typeof x !== 'object') continue;
    const r = x as Obj;
    const ds = str(r.date); const date = ds ? findDate(ds) : null;
    const ts = str(r.time); const time = ts ? findTime(ts) : null;
    const p = normPlate(str(r.plate));
    const plate = p && p.length >= 2 && p.length <= 8 ? p : null;
    const line: ReadLine = {
      kind, authority: issuer, notice_number: str(r.notice_number) ?? (raw.length === 1 ? str(d.notice_number) : null), plate, transponder: null,
      occurred_at: date ? `${date.iso}T${time?.hhmm ?? '00:00'}:00` : null, time_unknown: !time, place: str(r.location), entry: str(r.entry), exit: str(r.exit),
      amount_cents: cents(r.amount), fees_cents: cents(r.fees), due_on: due, confidence: 0, page: o.page,
      source_text: [str(r.notice_number), str(r.plate), ds, ts, str(r.location), str(r.entry), str(r.exit), str(r.amount)].filter(Boolean).join(' | ').slice(0, 1000)
    };
    if (!line.plate && !line.occurred_at && line.amount_cents == null) continue;
    const said = typeof r.confidence === 'number' && Number.isFinite(r.confidence) ? Math.max(0, Math.min(100, r.confidence <= 1 ? r.confidence * 100 : r.confidence)) : 60;
    // the model's own figure, never above what the checks allow
    line.confidence = Math.min(Math.round(said), lineConfidence(line, 90, { inFleet: plate ? fleet.has(plate) : null, ambiguousDate: !!date?.ambiguous, needsNotice: kind !== 'toll_invoice' }));
    lines.push(line);
  }
  return { authority: issuer, kind, statement_number: str(d.statement_number), account_number: str(d.account_number), due_on: due, total_cents: cents(d.total), lines, problems };
}

export interface PlateBox { x: number; y: number; w: number; h: number; confidence: number }
/** The model's plate boxes as fractions of the image, kept only when they look like a plate (shape and size), with a margin. */
export function normalizePlateBoxes(data: unknown, img: { width: number; height: number }): PlateBox[] {
  const d = (data && typeof data === 'object' ? data : {}) as Obj;
  const list = Array.isArray(d.plates) ? d.plates : Array.isArray(d.boxes) ? d.boxes : Array.isArray(data) ? data : [];
  const out: PlateBox[] = [];
  for (const it of list.slice(0, 6)) {
    if (!it || typeof it !== 'object') continue;
    const b = it as Obj;
    const arr = Array.isArray(b.bbox) ? b.bbox : Array.isArray(b.box) ? b.box : null;
    let x: number, y: number, w: number, h: number;
    if (arr && arr.length === 4 && arr.every((n) => typeof n === 'number')) { [x, y] = [arr[0] as number, arr[1] as number]; w = (arr[2] as number) - x; h = (arr[3] as number) - y; }
    else if (['x1', 'y1', 'x2', 'y2'].every((k) => typeof b[k] === 'number')) { x = b.x1 as number; y = b.y1 as number; w = (b.x2 as number) - x; h = (b.y2 as number) - y; }
    else if (['x', 'y', 'w', 'h'].every((k) => typeof b[k] === 'number')) { x = b.x as number; y = b.y as number; w = b.w as number; h = b.h as number; }
    else if (['x', 'y', 'width', 'height'].every((k) => typeof b[k] === 'number')) { x = b.x as number; y = b.y as number; w = b.width as number; h = b.height as number; }
    else continue;
    const max = Math.max(x + w, y + h);
    if (max > 1.0001) {
      // pixels of the image sent, or thousandths (some models answer on a 0 to 1000 grid)
      if (x + w <= img.width + 2 && y + h <= img.height + 2) { x /= img.width; w /= img.width; y /= img.height; h /= img.height; }
      else if (max <= 1000) { x /= 1000; w /= 1000; y /= 1000; h /= 1000; }
      else continue;
    }
    if (!(w > 0 && h > 0) || x < -0.01 || y < -0.01 || x + w > 1.01 || y + h > 1.01) continue;
    const ratio = (w * img.width) / (h * img.height);
    const area = w * h;
    if (ratio < 1.2 || ratio > 7 || area < 0.0002 || area > 0.2) continue;
    // a margin of 15% on each side, inside the photo
    const mx = w * 0.15, my = h * 0.15;
    const nx = Math.max(0, x - mx), ny = Math.max(0, y - my);
    out.push({ x: nx, y: ny, w: Math.min(1 - nx, w + 2 * mx), h: Math.min(1 - ny, h + 2 * my), confidence: typeof b.confidence === 'number' ? Math.max(0, Math.min(100, b.confidence <= 1 ? b.confidence * 100 : b.confidence)) : 50 });
  }
  return out;
}
