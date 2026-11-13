// The late return choice (migration 2660). A car that comes back late is never charged by itself: staff choose on the
// return screen or on the booking how it is charged, and the database writes the charge from the choice
// (app.late_return_decide). Pure: what each choice costs, what a choice still needs, and the words staff read. The amounts
// come from app.late_return_options; nothing is priced here.
export type LateKey = 'extension' | 'extra_days' | 'late_fee' | 'custom' | 'waive';
export interface LateOption { key: LateKey; days?: number; max_days?: number; unit_cents?: number; amount_cents?: number; extra_days?: number; extra_days_cents?: number; late_fee_cents?: number; set?: boolean }
export interface LateDecision {
  status: 'pending' | 'needs_admin' | 'decided'; option: LateKey | null; days: number | null; amount_cents: number | null; reason: string | null;
  requested_by: string | null; requested_at: string | null; decided_by: string | null; decided_at: string | null; charged_cents: number;
}
export interface LateReturn {
  booking_id: string; booking_number: string; back: boolean; minutes_late: number; grace_minutes: number; late: boolean; late_text: string;
  daily_cents: number; hourly_cents: number | null; hst_bps: number; options: LateOption[]; decision: LateDecision | null; locked: boolean;
  may: { decide: boolean; admin: boolean; waive: boolean; limit_cents: number | null };
}
/** What staff picked, as the form holds it: '' is "decide later". */
export interface LateChoice { option: LateKey | ''; days: string; amount: string; reason: string }
export const NO_CHOICE: LateChoice = { option: '', days: '', amount: '', reason: '' };

export const LATE_KEYS: readonly LateKey[] = ['extension', 'extra_days', 'late_fee', 'custom', 'waive'];
export const LATE_LABEL: Record<LateKey, string> = {
  extension: 'Charge as an extension', extra_days: 'Charge extra days', late_fee: 'Charge the late return fee', custom: 'Charge a custom amount', waive: 'Waive it'
};
const dollars = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const days = (n: number) => `${n} day${n === 1 ? '' : 's'}`;
const opt = (l: LateReturn, k: LateKey) => l.options.find((o) => o.key === k);

/** "12.50" or "1,250" typed by staff, in cents; null when it is not an amount. */
export function centsOf(s: string): number | null {
  const t = s.replace(/[$,\s]/g, '');
  if (!/^\d+(\.\d{1,2})?$/.test(t)) return null;
  return Math.round(Number(t) * 100);
}

/** The days of the "extra days" choice: what staff typed, else the whole days late (at least one). */
export function chosenDays(c: LateChoice, l: LateReturn): number {
  const o = opt(l, 'extra_days');
  const n = /^\d+$/.test(c.days.trim()) ? Number(c.days.trim()) : o?.days ?? 1;
  return n;
}

/** What a choice charges before tax, in cents; null while it cannot be known (a custom amount not typed yet). */
export function choiceAmount(c: LateChoice, l: LateReturn): number | null {
  switch (c.option) {
    case 'extension': return opt(l, 'extension')?.amount_cents ?? null;
    case 'extra_days': return chosenDays(c, l) * (opt(l, 'extra_days')?.unit_cents ?? l.daily_cents);
    case 'late_fee': return opt(l, 'late_fee')?.amount_cents ?? null;
    case 'custom': return centsOf(c.amount);
    case 'waive': return 0;
    default: return null;
  }
}

/** One line under each choice: what it is and what it costs now. */
export function optionDetail(k: LateKey, l: LateReturn): string {
  const o = opt(l, k);
  switch (k) {
    case 'extension': return `${days(o?.days ?? 1)} at the daily rate of ${dollars(l.daily_cents)}: ${dollars(o?.amount_cents ?? 0)} plus tax. Every started day counts, as an extension would have.`;
    case 'extra_days': return `${dollars(l.daily_cents)} a day plus tax. You choose the days, from 1 to ${o?.max_days ?? 1}.`;
    case 'late_fee': return o?.set === false ? 'The late return fee is not set in the fee defaults: ask an Admin, or choose another way.'
      : `${dollars(o?.amount_cents ?? 0)} plus tax, by the rental terms${(o?.extra_days ?? 0) > 0 ? `: ${days(o!.extra_days!)} at the daily rate${(o?.late_fee_cents ?? 0) > 0 ? ` and ${dollars(o!.late_fee_cents!)} for the hours after` : ''}` : l.hourly_cents ? `: ${dollars(l.hourly_cents)} for each started hour, capped a day` : ''}.`;
    case 'custom': return l.may.limit_cents === null ? 'Any amount, with what it is for. The renter sees the reason.' : `Any amount, with what it is for. Above your limit of ${dollars(l.may.limit_cents)} it waits for an Admin.`;
    case 'waive': return l.may.waive ? 'No charge for the late return, with the reason.' : 'No charge for the late return, with the reason. It waits for an Admin.';
  }
}

/** Why the choice cannot be sent yet; null when it can (or when nothing is chosen: that is "decide later"). */
export function choiceProblem(c: LateChoice, l: LateReturn): string | null {
  if (!c.option) return null;
  if (c.option === 'late_fee' && opt(l, 'late_fee')?.set === false) return 'The late return fee is not set in the fee defaults: choose another way.';
  if (c.option === 'extra_days') {
    const max = opt(l, 'extra_days')?.max_days ?? 1;
    const n = chosenDays(c, l);
    if (c.days.trim() && !/^\d+$/.test(c.days.trim())) return 'Enter the extra days as a whole number.';
    if (n < 1 || n > max) return `Choose 1 to ${max} extra day${max === 1 ? '' : 's'}.`;
  }
  if (c.option === 'custom') {
    const a = centsOf(c.amount);
    if (a === null || a <= 0) return 'Enter the amount to charge.';
    if (c.reason.trim().length < 5) return 'Say what the amount is for: the renter sees it.';
  }
  if (c.option === 'waive' && c.reason.trim().length < 5) return 'Say why the late return is waived.';
  return null;
}

/** The choice waits for an Admin: a custom amount above the person's limit, or a waiver by someone who may not waive. */
export function choiceNeedsAdmin(c: LateChoice, l: LateReturn): boolean {
  if (l.may.admin) return false;
  if (c.option === 'waive') return !l.may.waive;
  if (c.option === 'custom') { const a = centsOf(c.amount); return a !== null && a > (l.may.limit_cents ?? 0); }
  return false;
}

/** What goes to the database (late_return_decide, or late_choice on the return); null for "decide later". */
export function choicePayload(c: LateChoice, l: LateReturn): Record<string, unknown> | null {
  if (!c.option || choiceProblem(c, l)) return null;
  return {
    option: c.option,
    ...(c.option === 'extra_days' ? { days: chosenDays(c, l) } : {}),
    ...(c.option === 'custom' ? { amount_cents: centsOf(c.amount) } : {}),
    ...(c.option === 'custom' || c.option === 'waive' ? { reason: c.reason.trim() } : {})
  };
}

/** The decision in a sentence, for the booking and the return screen. */
export function decisionText(d: LateDecision): string {
  const what = d.option === 'extension' ? `charged as an extension, ${days(d.days ?? 1)} at the daily rate`
    : d.option === 'extra_days' ? `charged ${days(d.days ?? 1)} at the daily rate`
    : d.option === 'late_fee' ? 'charged the late return fee of the rental terms'
    : d.option === 'custom' ? `charged a custom amount${d.reason ? ` (${d.reason})` : ''}`
    : d.option === 'waive' ? `waived${d.reason ? ` (${d.reason})` : ''}` : 'not chosen yet';
  if (d.status === 'pending') return 'No late return charge is chosen yet. Nothing is charged until someone chooses.';
  if (d.status === 'needs_admin') return `Waiting for an Admin: ${d.requested_by ?? 'staff'} asked for the late return to be ${what}${d.option === 'custom' && d.amount_cents ? `, ${dollars(d.amount_cents)}` : ''}.`;
  return `The late return was ${what}${d.option !== 'waive' ? `: ${dollars(d.charged_cents)} with tax` : ''}${d.decided_by ? `, by ${d.decided_by}` : ''}.`;
}

/** What the return screen says once the return is complete, from what the database answered about the late return. */
export function afterReturnText(late: { status?: string; problem?: string } | null | undefined): string {
  if (!late?.status) return '';
  if (late.status === 'decided') return ' The late return is charged as you chose, and the renter is told.';
  if (late.status === 'needs_admin') return ' Your late return choice waits for an Admin.';
  return ' The late return charge is not chosen yet: choose it on the booking. Nothing is charged for it until then.';
}
