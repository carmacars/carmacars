// One-step Hire (release 33, migration 0730): the functions a hire can be given, the invitation each needs, the agreement
// values that come from the Hire form, and the status card's words. Pure: the server, the screen and the unit tests share it.
import type { Field } from '@/features/person-agreements/model';

export const HIRE_FUNCTIONS = ['cs', 'fleet', 'finance', 'sales_in_person', 'sales_remote', 'field'] as const;
export type HireFunction = (typeof HIRE_FUNCTIONS)[number];
export const HIRE_FUNCTION_LABEL: Record<HireFunction, string> = {
  cs: 'Customer service', fleet: 'Fleet', finance: 'Finance', sales_in_person: 'Sales in person', sales_remote: 'Sales remote', field: 'Field work'
};
export type StepState = 'done' | 'waiting' | 'todo';
export interface HireStep { key: 'account' | 'agreement' | 'pay' | 'academy' | 'first_day' | 'hired'; label: string; state: StepState; detail: string; missing?: string[]; payout_id?: string | null; verify?: boolean }
export interface HireStatus { onboarding: boolean; user_id?: string; name?: string; email?: string; function?: HireFunction; function_label?: string; start_on?: string; pay?: string;
  pay_basis?: 'monthly' | 'hourly' | 'commission'; pay_cents?: number | null; pay_currency?: string | null; hired_at?: string; steps?: HireStep[] }
export interface StandardPay { basis: 'monthly' | 'hourly' | 'commission'; cents: number | null; currency: string | null; text: string }

/** The staff invitation of a function: the one staff portal (0197) with the function, the sales work mode, field work. */
export function inviteFor(fn: HireFunction, covers: string[] = []): { role: 'staff'; functions: string[]; field_function?: string; work_mode: 'in_person' | 'remote' | null } {
  if (fn === 'field') return { role: 'staff', functions: ['field'], field_function: 'driver_detailer', work_mode: null };
  if (fn === 'sales_in_person' || fn === 'sales_remote') return { role: 'staff', functions: ['sales'], work_mode: fn === 'sales_remote' ? 'remote' : 'in_person' };
  return { role: 'staff', functions: [fn, ...covers.filter((c) => c !== fn && c !== 'field')], work_mode: null };
}

const amount = (cents: number | null | undefined) => (typeof cents === 'number' ? (cents / 100).toFixed(2) : '');

/** The agreement's values: the defaults of the record, with the pay of the Hire form (and its start date, already on the profile). */
export function agreementValues(fields: Field[], s: Pick<HireStatus, 'pay_basis' | 'pay_cents' | 'pay_currency'> | null): Record<string, string> {
  const v: Record<string, string> = Object.fromEntries(fields.map((f) => [f.key, f.value ?? '']));
  if (!s?.pay_basis) return v;
  const has = (k: string) => fields.some((f) => f.key === k);
  if (has('pay_basis')) v.pay_basis = s.pay_basis;
  if (has('rate') && s.pay_basis !== 'commission') v.rate = amount(s.pay_cents);
  if (has('currency') && s.pay_currency) v.currency = s.pay_currency;
  if (has('wage') && s.pay_basis === 'hourly') v.wage = amount(s.pay_cents);
  return v;
}

/** Dollars typed on the form as cents (null when empty or not a positive amount). */
export function payCents(typed: string): number | null {
  const t = (typed ?? '').replace(/[$,\s]/g, '');
  if (!/^\d+(\.\d{1,2})?$/.test(t)) return null;
  const c = Math.round(Number(t) * 100);
  return c > 0 ? c : null;
}

export const STEP_WORDS: Record<StepState, string> = { done: 'Done', waiting: 'Waiting', todo: 'To do' };
