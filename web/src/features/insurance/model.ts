// Insurance replacements (release 50 hotfix 2, migration 5120): the list's stages, a version's differences from the one
// before, and the rules that read a pasted adjuster email or claim notice. Pure: the unit tests run it directly.

export const STAGES = ['upcoming', 'on_rent', 'returned', 'invoiced', 'negotiating', 'approved', 'paid', 'written_off'] as const;
export type Stage = (typeof STAGES)[number];
export const STAGE_LABEL: Record<Stage, string> = {
  upcoming: 'Upcoming', on_rent: 'On rent', returned: 'Returned', invoiced: 'Invoiced', negotiating: 'Negotiating',
  approved: 'Approved', paid: 'Paid', written_off: 'Written off'
};
export const stageLabel = (s: string) => STAGE_LABEL[s as Stage] ?? s.replace(/_/g, ' ');

export interface Line { description: string; quantity?: number | null; rate_cents?: number | null; amount_cents: number; taxable?: boolean }
export interface BillTo { name?: string | null; attention?: string | null; email?: string | null; address?: string | null }
/** What one version of an invoice or estimate said, as sent (insurer_invoice_versions.snapshot). */
export interface Snapshot {
  kind?: 'estimate' | 'invoice'; version?: number; lines: Line[]; amount_cents: number; hst_cents: number; total_cents: number;
  period_start?: string | null; period_end?: string | null; invoice_date?: string | null; due_date?: string | null;
  bill_to?: BillTo | null; notes?: string | null; claim_number?: string | null;
}
export interface DiffRow { label: string; before: string; after: string }

const money = (c: number | null | undefined) => (c === null || c === undefined ? '' : `${c < 0 ? '-' : ''}$${(Math.abs(c) / 100).toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',')}`);
const txt = (v: unknown) => (v === null || v === undefined ? '' : String(v).trim());

/** What changed from one version to the next: the totals, the dates, who it is billed to, the notes and each line
 *  (matched by its description: added, removed or a different amount). Empty when nothing changed. */
export function diffVersions(a: Snapshot | null, b: Snapshot): DiffRow[] {
  if (!a) return [];
  const out: DiffRow[] = [];
  const add = (label: string, x: string, y: string) => { if (x !== y) out.push({ label, before: x || 'none', after: y || 'none' }); };
  const byDesc = (ls: Line[]) => { const m = new Map<string, Line>(); for (const l of ls) { let k = txt(l.description); while (m.has(k)) k += ' '; m.set(k, l); } return m; };
  const la = byDesc(a.lines ?? []); const lb = byDesc(b.lines ?? []);
  const lineText = (l: Line) => `${l.quantity != null && l.rate_cents != null ? `${l.quantity} x ${money(l.rate_cents)} = ` : ''}${money(l.amount_cents)}`;
  for (const [k, l] of la) { const m = lb.get(k); if (!m) add(`Line: ${k.trim()}`, lineText(l), ''); else add(`Line: ${k.trim()}`, lineText(l), lineText(m)); }
  for (const [k, l] of lb) if (!la.has(k)) add(`Line: ${k.trim()}`, '', lineText(l));
  add('Before HST', money(a.amount_cents), money(b.amount_cents));
  add('HST', money(a.hst_cents), money(b.hst_cents));
  add('Total', money(a.total_cents), money(b.total_cents));
  add('Rental period', [txt(a.period_start), txt(a.period_end)].filter(Boolean).join(' to '), [txt(b.period_start), txt(b.period_end)].filter(Boolean).join(' to '));
  add('Invoice date', txt(a.invoice_date), txt(b.invoice_date));
  add('Due date', txt(a.due_date), txt(b.due_date));
  add('Claim number', txt(a.claim_number), txt(b.claim_number));
  for (const f of ['name', 'attention', 'email', 'address'] as const) add(`Bill to: ${f}`, txt(a.bill_to?.[f]), txt(b.bill_to?.[f]));
  add('Notes', txt(a.notes), txt(b.notes));
  return out;
}

/** A line's amount: typed, else its quantity times its rate (rounded to the cent). */
export function lineAmount(l: { quantity?: number | null; rate_cents?: number | null; amount_cents?: number | null }): number {
  if (typeof l.amount_cents === 'number' && Number.isFinite(l.amount_cents)) return Math.round(l.amount_cents);
  if (typeof l.quantity === 'number' && typeof l.rate_cents === 'number') return Math.round(l.quantity * l.rate_cents);
  return 0;
}

/** The totals of a working copy: before HST, the HST of the taxable lines at the booking's rate (basis points) unless
 *  typed, and the total. */
export function totals(lines: Line[], hstBps: number, hstTyped?: number | null): { amount_cents: number; hst_cents: number; total_cents: number } {
  const amount = lines.reduce((n, l) => n + lineAmount(l), 0);
  const taxable = lines.filter((l) => l.taxable !== false).reduce((n, l) => n + lineAmount(l), 0);
  const hst = typeof hstTyped === 'number' && Number.isFinite(hstTyped) ? Math.round(hstTyped) : Math.max(0, Math.round((taxable * hstBps) / 10000));
  return { amount_cents: amount, hst_cents: hst, total_cents: amount + hst };
}

/** Days between two times, a started day counting as a day (the list's Days column). */
export function rentalDays(from: string, to: string): number {
  const ms = new Date(to).getTime() - new Date(from).getTime();
  return Number.isFinite(ms) && ms > 0 ? Math.ceil(ms / 86_400_000) : 0;
}

// ---------------------------------------------------------------- reading a pasted text
/** What the rules found in a pasted adjuster email or claim notice. Every field is a suggestion: staff confirm it. */
export interface Parsed {
  renter_name?: string; renter_phone?: string; renter_email?: string; claim_number?: string; insurer_name?: string;
  adjuster_name?: string; adjuster_email?: string; adjuster_phone?: string; pickup_date?: string; return_date?: string;
  authorized_days?: number; daily_rate_cents?: number; car_year?: number; car_make?: string; car_model?: string; car_plate?: string;
}
export const PARSED_LABEL: Record<keyof Parsed, string> = {
  renter_name: 'Renter', renter_phone: 'Renter phone', renter_email: 'Renter email', claim_number: 'Claim number', insurer_name: 'Insurer',
  adjuster_name: 'Adjuster', adjuster_email: 'Adjuster email', adjuster_phone: 'Adjuster phone', pickup_date: 'Pickup date', return_date: 'Return date',
  authorized_days: 'Days authorized', daily_rate_cents: 'Daily rate', car_year: 'Car year', car_make: 'Car make', car_model: 'Car model', car_plate: 'Plate'
};

const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;
const PHONE = /(?:\+?1[\s.-]?)?\(?(\d{3})\)?[\s.-]?(\d{3})[\s.-]?(\d{4})(?:\s*(?:x|ext\.?)\s*\d+)?/i;
const pad = (n: number) => String(n).padStart(2, '0');

/** A date written as 2026-11-03, 11/03/2026 (month first, as Canadian insurers write it), Nov 3, 2026 or 3 November 2026. */
export function readDate(s: string, year = new Date().getFullYear()): string | undefined {
  let m = /(\d{4})-(\d{1,2})-(\d{1,2})/.exec(s);
  if (m) return `${m[1]}-${pad(+m[2]!)}-${pad(+m[3]!)}`;
  m = /\b(\d{1,2})\/(\d{1,2})\/(\d{4})\b/.exec(s);
  if (m && +m[1]! <= 12) return `${m[3]}-${pad(+m[1]!)}-${pad(+m[2]!)}`;
  m = /\b(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]{3,9}),?\s*(\d{4})?/.exec(s);
  if (m && MONTHS.includes(m[2]!.slice(0, 3).toLowerCase())) return `${m[3] ?? year}-${pad(MONTHS.indexOf(m[2]!.slice(0, 3).toLowerCase()) + 1)}-${pad(+m[1]!)}`;
  m = /\b([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b,?\s*(\d{4})?/.exec(s);
  if (m && MONTHS.includes(m[1]!.slice(0, 3).toLowerCase())) return `${m[3] ?? year}-${pad(MONTHS.indexOf(m[1]!.slice(0, 3).toLowerCase()) + 1)}-${pad(+m[2]!)}`;
  return undefined;
}

const cleanName = (s: string) => s.replace(/[<(].*$/, '').replace(/[,;:]+$/, '').replace(/\s+/g, ' ').trim();
const phoneOf = (s: string) => { const m = PHONE.exec(s); return m ? `${m[1]}${m[2]}${m[3]}` : undefined; };

/** The rules: labelled lines ("Insured: ...", "Claim #: ...", "Adjuster: ..."), the adjuster's signature, the dates, the
 *  days and the daily rate authorized, and the insurer when one of `insurers` is named. Never guesses beyond that. */
export function parseClaimText(text: string, insurers: readonly string[] = [], year?: number): Parsed {
  const out: Parsed = {};
  const lines = text.replace(/\r/g, '').split('\n').map((l) => l.trim());
  const val = (re: RegExp) => { for (const l of lines) { const m = re.exec(l); if (m && m[1]!.trim()) return m[1]!.trim(); } return undefined; };
  const near = (re: RegExp) => lines.filter((l) => re.test(l)).join('\n');

  const claim = val(/\bclaim\s*(?:#|no\.?|number|num)?\s*[:#-]?\s*([A-Z0-9][A-Z0-9-]{3,})/i);
  if (claim && /\d/.test(claim)) out.claim_number = claim.toUpperCase();
  const renter = val(/^(?:insured|claimant|customer|renter|driver|client|insured name|claimant name)\s*(?:name)?\s*[:-]\s*(.+)$/i);
  if (renter) out.renter_name = cleanName(renter);
  const renterLines = near(/\b(insured|claimant|customer|renter|client)\b/i);
  const rPhone = phoneOf(near(/\b(insured|claimant|customer|renter|client)\b.*(phone|cell|tel|mobile)|^(phone|cell|tel|mobile)\s*[:-]/i) || renterLines);
  if (rPhone) out.renter_phone = rPhone;
  const rEmail = EMAIL.exec(renterLines)?.[0];
  if (rEmail) out.renter_email = rEmail.toLowerCase();

  const adj = val(/^(?:adjuster|adjustor|claims? (?:adjuster|representative|handler))\s*(?:name)?\s*[:-]\s*(.+)$/i);
  if (adj) out.adjuster_name = cleanName(adj);
  const sign = lines.findIndex((l) => /^(regards|thanks|thank you|sincerely|best|cheers)\b/i.test(l));
  if (!out.adjuster_name && sign >= 0) { const n = lines.slice(sign + 1).find((l) => l && !EMAIL.test(l) && !PHONE.test(l)); if (n && /^[A-Za-z][A-Za-z'.-]+(\s+[A-Za-z][A-Za-z'.-]+){1,3}$/.test(n)) out.adjuster_name = n; }
  const adjBlock = [near(/\b(adjuster|adjustor|from)\b/i), sign >= 0 ? lines.slice(sign).join('\n') : ''].join('\n');
  const aEmail = EMAIL.exec(adjBlock)?.[0] ?? [...text.matchAll(new RegExp(EMAIL, 'g'))].map((m) => m[0]).find((e) => e.toLowerCase() !== out.renter_email);
  if (aEmail) out.adjuster_email = aEmail.toLowerCase();
  const aPhone = phoneOf(adjBlock);
  if (aPhone && aPhone !== out.renter_phone) out.adjuster_phone = aPhone;

  const named = val(/^(?:insurer|insurance company|carrier|company)\s*[:-]\s*(.+)$/i);
  const low = text.toLowerCase();
  const known = insurers.find((n) => n && low.includes(n.toLowerCase()));
  if (known) out.insurer_name = known;
  else if (named) out.insurer_name = cleanName(named);
  else if (out.adjuster_email) {
    const dom = out.adjuster_email.split('@')[1]!.split('.')[0]!;
    const hit = insurers.find((n) => n.toLowerCase().replace(/[^a-z]/g, '').startsWith(dom.replace(/[^a-z]/g, '')) && dom.length >= 3);
    if (hit) out.insurer_name = hit;
  }

  // the first labelled line whose value is a date ("From: Pat <...>" is a sender, not a date)
  const dateAt = (re: RegExp) => { for (const l of lines) { const m = re.exec(l); const v = m ? readDate(m[1]!, year) : undefined; if (v) return v; } return undefined; };
  const sd = dateAt(/\b(?:start(?:\s*date)?|pick\s*-?\s*up(?:\s*date)?|rental start|from|effective|beginning)\b\s*[:-]?\s*(.+)$/i);
  const ed = dateAt(/\b(?:end(?:\s*date)?|return(?:\s*date)?|rental end|until|to|ending|expires?)\b\s*[:-]?\s*(.+)$/i);
  if (sd) out.pickup_date = sd;
  if (ed && (!sd || ed >= sd)) out.return_date = ed;
  const days = /(\d{1,3})\s*(?:days?)\b[^.\n]*\b(?:authori[sz]ed|approved|covered)|(?:authori[sz]ed|approved|covered)[^.\n]*?\b(\d{1,3})\s*days?\b/i.exec(text);
  if (days) out.authorized_days = Number(days[1] ?? days[2]);
  const rate = /\$\s*(\d{1,4}(?:\.\d{2})?)\s*(?:\/|per|a)\s*day/i.exec(text) ?? /(?:daily rate|rate per day|per diem)\s*[:-]?\s*\$?\s*(\d{1,4}(?:\.\d{2})?)/i.exec(text);
  if (rate) out.daily_rate_cents = Math.round(Number(rate[1]) * 100);

  const plate = val(/\b(?:plate|licen[cs]e plate|plate #)\s*[:#-]?\s*([A-Z0-9 ]{2,10})$/i);
  if (plate) out.car_plate = plate.replace(/\s+/g, '').toUpperCase();
  const car = val(/\b(?:vehicle|car|replacement vehicle|rental vehicle)\s*[:-]\s*(.+)$/i);
  const cm = car ? /\b(19\d{2}|20\d{2})\s+([A-Za-z-]+)\s+([A-Za-z0-9][A-Za-z0-9 -]*)/.exec(car) : null;
  if (cm) { out.car_year = Number(cm[1]); out.car_make = cm[2]; out.car_model = cm[3]!.trim(); }
  return out;
}

/** The AI's reading laid under the rules': only the fields the rules left empty, and only well-formed values. */
export function mergeParsed(rules: Parsed, ai: unknown): Parsed {
  if (!ai || typeof ai !== 'object') return rules;
  const a = ai as Record<string, unknown>;
  const out: Parsed = { ...rules };
  const s = (k: keyof Parsed, ok: (v: string) => boolean = (v) => v.length > 0 && v.length <= 120) => {
    const v = a[k];
    if (out[k] === undefined && typeof v === 'string' && ok(v.trim())) (out as Record<string, unknown>)[k] = v.trim();
  };
  s('renter_name'); s('insurer_name'); s('adjuster_name'); s('car_make'); s('car_model');
  s('claim_number', (v) => /^[A-Za-z0-9-]{4,40}$/.test(v) && /\d/.test(v));
  s('renter_email', (v) => EMAIL.test(v)); s('adjuster_email', (v) => EMAIL.test(v));
  s('renter_phone', (v) => /^\d{10}$/.test(v.replace(/\D/g, '').slice(-10))); s('adjuster_phone', (v) => /^\d{10}$/.test(v.replace(/\D/g, '').slice(-10)));
  s('pickup_date', (v) => /^\d{4}-\d{2}-\d{2}$/.test(v)); s('return_date', (v) => /^\d{4}-\d{2}-\d{2}$/.test(v));
  s('car_plate', (v) => /^[A-Za-z0-9 ]{2,10}$/.test(v));
  for (const k of ['renter_phone', 'adjuster_phone'] as const) if (out[k] && !rules[k]) out[k] = out[k]!.replace(/\D/g, '').slice(-10);
  if (out.authorized_days === undefined && Number.isInteger(a.authorized_days) && (a.authorized_days as number) > 0 && (a.authorized_days as number) < 400) out.authorized_days = a.authorized_days as number;
  if (out.daily_rate_cents === undefined && Number.isInteger(a.daily_rate_cents) && (a.daily_rate_cents as number) > 0 && (a.daily_rate_cents as number) < 200000) out.daily_rate_cents = a.daily_rate_cents as number;
  if (out.car_year === undefined && Number.isInteger(a.car_year) && (a.car_year as number) > 1980 && (a.car_year as number) < 2100) out.car_year = a.car_year as number;
  return out;
}
