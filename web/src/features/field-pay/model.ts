// Field pay (0165): the pure helpers of the hours and pay screens, the pay statement and the CSV (no server code, so they are unit tested).

/** Whole minutes as "8 h 30 min" (the same wording as the database's app.fp_hours_text). */
export function hoursText(minutes: unknown): string {
  const raw = typeof minutes === 'number' ? minutes : Number(minutes ?? 0);
  const m = Math.max(0, Math.round(Number.isFinite(raw) ? raw : 0));
  const h = Math.floor(m / 60);
  const r = m % 60;
  return h && r ? `${h} h ${r} min` : h ? `${h} h` : `${r} min`;
}

/** Cents as "$153.00" (negative with a minus sign). */
export function dollarsText(cents: unknown): string {
  const raw = typeof cents === 'number' ? cents : Number(cents ?? 0);
  const v = (Number.isFinite(raw) ? raw : 0) / 100;
  return `${v < 0 ? '-' : ''}$${Math.abs(v).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

/** Cents as a plain decimal for a spreadsheet: 15300 is 153.00. */
export const plainMoney = (cents: unknown): string => ((Number(cents ?? 0) || 0) / 100).toFixed(2);

/** Whole minutes as decimal hours for a spreadsheet: 510 is 8.50. */
export const decimalHours = (minutes: unknown): string => ((Number(minutes ?? 0) || 0) / 60).toFixed(2);

/** One CSV field: quoted when it holds a comma, a quote or a line break; a leading =, +, - or @ is defused so a spreadsheet never runs it as a formula. */
export function csvCell(v: unknown): string {
  let t = v === null || v === undefined ? '' : String(v);
  if (/^[=+@]/.test(t) || (/^-/.test(t) && !/^-?\d+(\.\d+)?$/.test(t))) t = `'${t}`;
  return /[",\n\r]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
}

export interface PayCsvRow { statement: string | null; name: string; minutes: number; overtime_minutes: number; rate_cents: number; wage_cents: number; overtime_cents: number;
  vacation_cents: number; commission_cents: number; gross_cents: number; status: string; paid_on: string | null; method: string | null; reference: string | null }

/** The pay run as a CSV: one row per person, hours as decimals and money as plain decimals, with a total row. */
export function payRunCsv(period: { start: string; end: string }, rows: PayCsvRow[]): string {
  const head = ['Statement', 'Staff member', 'Period start', 'Period end', 'Hours', 'Overtime hours', 'Hourly rate', 'Wages', 'Overtime pay', 'Vacation pay', 'Commissions and referral fees', 'Total', 'Status', 'Paid on', 'How paid', 'Reference'];
  const lines = [head.map(csvCell).join(',')];
  for (const r of rows) {
    lines.push([r.statement ?? '', r.name, period.start, period.end, decimalHours(r.minutes), decimalHours(r.overtime_minutes), plainMoney(r.rate_cents), plainMoney(r.wage_cents), plainMoney(r.overtime_cents),
      plainMoney(r.vacation_cents), plainMoney(r.commission_cents), plainMoney(r.gross_cents), r.status, r.paid_on ?? '', r.method ?? '', r.reference ?? ''].map(csvCell).join(','));
  }
  const sum = (f: (r: PayCsvRow) => number) => rows.reduce((a, r) => a + (f(r) || 0), 0);
  lines.push(['', 'Total', period.start, period.end, decimalHours(sum((r) => r.minutes)), decimalHours(sum((r) => r.overtime_minutes)), '', plainMoney(sum((r) => r.wage_cents)), plainMoney(sum((r) => r.overtime_cents)),
    plainMoney(sum((r) => r.vacation_cents)), plainMoney(sum((r) => r.commission_cents)), plainMoney(sum((r) => r.gross_cents)), '', '', '', ''].map(csvCell).join(','));
  return lines.join('\r\n') + '\r\n';
}

/** How long a shift has run, for the big clock on the phone: "2:05" (hours and minutes since it began). */
export function elapsedClock(startedAt: string, now: number): string {
  const ms = Math.max(0, now - new Date(startedAt).getTime());
  const m = Math.floor(ms / 60_000);
  return `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}`;
}

export const PAY_METHODS: Array<[string, string]> = [['e_transfer', 'e-Transfer'], ['bank_transfer', 'Bank transfer'], ['cash', 'Cash']];
export const methodWords = (m: string | null | undefined): string => PAY_METHODS.find(([k]) => k === m)?.[1] ?? '';

/** The hours worked beyond the weekly line, in words, for the settings page. */
export const overtimeWords = (on: boolean, weeklyHours: number, bps: number): string =>
  on ? `Overtime is on: hours past ${weeklyHours} in a week are paid at ${bps / 100}% of the hourly rate.` : 'Overtime is off: every hour is paid at the hourly rate.';

// ---- vehicle class rules (Admin > Settings > Vehicle class rules)
export interface ClassRule { id: string; rank: number; make_key: string | null; model_re: string | null; trim_re: string | null; body_re: string | null; class: string; class_label: string;
  aged_years: number | null; aged_class: string | null; aged_class_label: string | null; note: string; is_active: boolean }

/** What a rule matches, in words: "make crbrand, model ^zeta". */
export function ruleWhen(r: Pick<ClassRule, 'make_key' | 'model_re' | 'trim_re' | 'body_re'>): string {
  const parts = [r.make_key && `make ${r.make_key}`, r.model_re && `model ${r.model_re}`, r.trim_re && `trim ${r.trim_re}`, r.body_re && `body ${r.body_re}`].filter(Boolean);
  return parts.length ? parts.join(', ') : 'any car';
}

/** What a rule decides, in words: "Exotic, Luxury once 10 years old". */
export function ruleThen(r: Pick<ClassRule, 'class_label' | 'aged_years' | 'aged_class_label'>): string {
  return r.aged_years && r.aged_class_label ? `${r.class_label}, ${r.aged_class_label} once ${r.aged_years} years old` : r.class_label;
}

/** The checks the form can do before asking the database (which checks again): a rule needs a condition, a rank, a note; a pattern must compile; the older class needs the years. */
export function ruleProblems(v: { rank?: unknown; make?: unknown; model_re?: unknown; trim_re?: unknown; body_re?: unknown; class?: unknown; aged_years?: unknown; aged_class?: unknown; note?: unknown }): string[] {
  const out: string[] = [];
  const has = (x: unknown) => typeof x === 'string' && x.trim() !== '';
  if (!has(v.make) && !has(v.model_re) && !has(v.trim_re) && !has(v.body_re)) out.push('A rule needs at least one condition: a make, a model, a trim or a body pattern.');
  const rank = Number(v.rank);
  if (!Number.isInteger(rank) || rank < 1 || rank > 999) out.push('The rank is a whole number from 1 to 999; the lowest rank that matches wins.');
  if (!has(v.class)) out.push('Choose the class.');
  if (!has(v.note) || String(v.note).trim().length < 2) out.push('Say in a note what the rule is for.');
  for (const [k, x] of [['model', v.model_re], ['trim', v.trim_re], ['body', v.body_re]] as const) {
    if (has(x)) { try { new RegExp(String(x), 'i'); } catch { out.push(`The ${k} pattern is not a valid pattern.`); } }
  }
  const years = v.aged_years === null || v.aged_years === undefined || v.aged_years === '' ? null : Number(v.aged_years);
  if (years !== null && (!Number.isInteger(years) || years < 1 || years > 60)) out.push('Years old is from 1 to 60.');
  if ((years !== null) !== has(v.aged_class)) out.push('Years old and the older car gets class go together: fill in both or neither.');
  if (years !== null && has(v.aged_class) && v.aged_class === v.class) out.push('The older class is the same as the class.');
  return out;
}
