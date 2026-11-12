// A staff member's pay details (release 33, migration 0730): the methods, the checks of the form (the database checks
// again), and what is shown back (never the account number: its last 4 digits only). Pure, unit-tested.
export const PAY_METHODS = ['bank_transfer', 'e_transfer', 'paypal', 'wise', 'gcash', 'onlinejobs'] as const;
export type PayMethod = (typeof PAY_METHODS)[number];
export const PAY_METHOD_LABEL: Record<PayMethod, string> = {
  bank_transfer: 'Bank account', e_transfer: 'Interac e-Transfer (Canada)', paypal: 'PayPal', wise: 'Wise', gcash: 'GCash', onlinejobs: 'Through OnlineJobs.ph'
};
export interface PayDetailsInput { method: PayMethod; account_holder: string; country?: string; bank_name?: string; institution_no?: string; transit_no?: string; account_no?: string; email?: string }
export interface PayDetailsView { current: { id: string; method: PayMethod; shown: string; account_holder: string; verified: boolean; at: string } | null; methods: PayMethod[] }

export function checkPayDetails(p: PayDetailsInput): Record<string, string> {
  const fe: Record<string, string> = {};
  if (!PAY_METHODS.includes(p.method)) fe.method = 'Choose how you want to be paid.';
  if ((p.account_holder ?? '').trim().length < 2) fe.account_holder = 'Enter the account holder\'s name.';
  const digits = (p.account_no ?? '').replace(/[\s-]/g, '');
  if (p.method === 'bank_transfer') {
    if (!(p.bank_name ?? '').trim() && !/^\d{3}$/.test(p.institution_no ?? '')) fe.bank_name = 'Enter the bank.';
    if (p.institution_no && !/^\d{3}$/.test(p.institution_no)) fe.institution_no = 'The institution number is 3 digits.';
    if (p.transit_no && !/^\d{5}$/.test(p.transit_no)) fe.transit_no = 'The transit number is 5 digits.';
    if (!/^\d{5,20}$/.test(digits)) fe.account_no = 'The account number is 5 to 20 digits.';
  }
  if (p.method === 'gcash' && !/^(\+?63|0)?9\d{9}$/.test(digits)) fe.account_no = 'Enter the GCash mobile number, for example 0917 123 4567.';
  if (['e_transfer', 'paypal', 'wise'].includes(p.method) && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test((p.email ?? '').trim())) fe.email = 'Enter the email address.';
  return fe;
}

/** 2361: the methods offered to a person working in Canada (direct deposit, Interac e-Transfer); everyone else sees them all. */
export const CANADA_PAY_METHODS: PayMethod[] = ['bank_transfer', 'e_transfer'];
export const payMethodsFor = (canada: boolean, current?: PayMethod | null): PayMethod[] =>
  canada ? PAY_METHODS.filter((m) => CANADA_PAY_METHODS.includes(m) || m === current) : [...PAY_METHODS];
