// r50 (5020): resigning from the staff portal. Pure: the form, the Admin's Staff and roles and the tests share it.
export type ResignFacts = {
  staff: boolean; active?: boolean; portal?: 'va' | 'field'; name?: string; role?: string; today?: string; notice_days?: number;
  in_onboarding?: boolean; in_trial?: boolean; trial_days?: number; can_today?: boolean; earliest?: string; latest?: string; default_last_day?: string;
  words?: { final_pay_text: string; return_text: string; pay_timing: string; period_end: string | null };
  resignation?: { id: string; status: 'pending' | 'withdrawn' | 'ended'; resigned_on: string; last_day: string; reason: string | null; created_at: string;
    by_self: boolean; withdrawn_at: string | null; ended_at: string | null; can_withdraw: boolean } | null;
};

export type StaffResignation = {
  id: string; status: 'pending' | 'withdrawn' | 'ended'; resigned_on: string; last_day: string; reason: string | null; created_at: string; by_self: boolean;
  recorded_by: string; withdrawn_at: string | null; ended_at: string | null; task_id: string | null; task_open: boolean; started_on: string | null;
};

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/** "Wed, Dec 2, 2026" for a YYYY-MM-DD day (a calendar day, never shifted by a time zone); '' when not a day. */
export function dayWords(d: string | null | undefined): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(d ?? '');
  if (!m) return '';
  const dt = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return `${DAYS[dt.getUTCDay()]}, ${MONTHS[dt.getUTCMonth()]} ${dt.getUTCDate()}, ${dt.getUTCFullYear()}`;
}

/** Whole days from a to b (YYYY-MM-DD). */
export function daysBetween(a: string, b: string): number {
  const p = (s: string) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s); return m ? Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : NaN; };
  return Math.round((p(b) - p(a)) / 86_400_000);
}

/** Why a chosen last day cannot be sent, or null when it can (the database checks the same). */
export function lastDayProblem(f: ResignFacts, day: string): string | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) return 'Choose your last day.';
  if (f.earliest && day < f.earliest) return f.can_today ? 'Your last day can be today at the earliest.' : `Your last day can be ${dayWords(f.earliest)} at the earliest.`;
  if (f.latest && day > f.latest) return 'Choose a last day within 120 days.';
  return null;
}

/** True when the chosen day ends the access as soon as the resignation is sent. */
export const endsNow = (f: ResignFacts, day: string) => !!f.today && day <= f.today;

/** The confirm step: what happens next, one line each, in order. */
export function nextSteps(f: ResignFacts, day: string): string[] {
  const short = f.today && f.notice_days !== undefined && !endsNow(f, day) && daysBetween(f.today, day) < f.notice_days;
  const out: string[] = [];
  if (endsNow(f, day)) out.push('Your access ends as soon as you confirm: the portal closes after the confirmation screen.');
  else out.push(`You keep working as usual until the end of ${dayWords(day)}. Your access ends by itself after that day.`);
  if (short) out.push(`That is less than the ${f.notice_days} days' notice your agreement asks for. An Admin will confirm it with you.`);
  if (!endsNow(f, day) && f.portal === 'field') out.push('Your shifts and jobs after your last day go back to the team now.');
  if (f.words?.final_pay_text) out.push(f.words.final_pay_text);
  if (f.words?.return_text) out.push(f.words.return_text);
  out.push('We email you this confirmation, and the Admins and Finance are told.');
  if (!endsNow(f, day)) out.push(`Changed your mind? Withdraw it here any time up to ${dayWords(day)}.`);
  return out;
}

/** The Admin's badge on Staff and roles: Resigning (with the last day), Resigned, or nothing. */
export function resignBadge(r: Pick<StaffResignation, 'status' | 'last_day' | 'ended_at'> | null | undefined, userActive: boolean): { label: string; tone: 'amber' | 'grey' } | null {
  if (!r) return null;
  if (r.status === 'pending') return { label: `Resigning: last day ${dayWords(r.last_day)}`, tone: 'amber' };
  if (r.status === 'ended' && !userActive) return { label: `Resigned: last day ${dayWords(r.last_day)}`, tone: 'grey' };
  return null;
}
