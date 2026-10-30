// Agreements generated from the records (migration 0049): an investor's investment agreement (from the investor and
// their investments) and a staff member's agreement (VA contractor or field employee, from the staff profile, with the
// settings' defaults for what the profile does not hold). The text is the source document word for word
// (scripts/gen-person-agreements.mjs); this file fills its blanks: Schedule A, the names in the signature lines, and the
// initials and dates given with the electronic signature. Rendered with the same blocks and PDF as every agreement.
// Relative imports with their extension: the unit tests run this file in Node directly (model.test.ts).
import { money, phone } from '../../lib/format.ts';
import { FIELD_MD, INVESTMENT_MD, PERSON_AGREEMENTS_VERSION, VA_MD } from './source.generated.ts';

export { PERSON_AGREEMENTS_VERSION };
export type PersonKind = 'investment_agreement' | 'va_agreement' | 'field_agreement';
export interface Company { legal_name: string | null; brand: string; address: string | null; email: string | null; phone: string | null; signing_officer_name: string | null; signing_officer_title: string | null }
export interface InvestorFacts {
  investor: { id: string; legal_name: string; investor_type: string | null; address: string | null; email: string | null; phone: string | null; tax_resident_canada: boolean | null; tax_country: string | null; has_portal: boolean };
  agreement_number: string;
  investments: Array<{ principal_cents: number; yearly_bps: number; investment_date: string | null; lockup_end_date: string | null; is_initial: boolean }>;
  company: Company;
}
export interface StaffFacts {
  staff: { user_id: string; full_name: string; email: string | null; phone: string | null; staff_type: string; va_function: string | null; field_function: string | null; started_on: string | null;
    referral_code: string | null; single_limit_cents: number | null; dual_approval_threshold_cents: number | null; has_signed: boolean; home_address?: string | null };
  defaults: Record<string, string>;
  company: Company;
}
/** The values an Admin confirms before sending (a field the record does not hold starts from the settings' defaults). */
export interface Field { key: string; label: string; value: string; hint?: string; required?: boolean; options?: Array<[string, string]>;
  /** Not asked (and not required) when another field has this value: the hours and the Rate of a commission-only engagement (0059). */
  hiddenWhen?: { key: string; value: string } }
/** Whether a field is asked, given the values typed so far. */
export const fieldShown = (f: Field, v: Record<string, string>) => !f.hiddenWhen || (v[f.hiddenWhen.key] ?? '') !== f.hiddenWhen.value;
/** The labels of the required fields still empty (a field not asked is not required). */
export const missingRequired = (fields: Field[], v: Record<string, string>) => fields.filter((f) => f.required && fieldShown(f, v) && !(v[f.key] ?? '').trim()).map((f) => f.label);

const ON_SIGNATURE = 'given electronically (see the signature record)';
const DATE_SIGNED = 'the date of the electronic signature';
const day = (iso: string | null | undefined) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', month: 'long', day: 'numeric', year: 'numeric' }).format(new Date(`${iso.slice(0, 10)}T12:00:00Z`)) : '');
const VA_ROLE: Record<string, string> = { finance: 'Finance and Billing Coordinator', fleet: 'Fleet Operations Coordinator', cs: 'Customer Service Coordinator', sales: 'Sales Coordinator' };
const FIELD_ROLE: Record<string, string> = { driver: 'Driver', detailer: 'Detailer', driver_detailer: 'Driver and detailer', both: 'Driver and detailer' };
const companyName = (c: Company) => c.legal_name || c.brand;
const num = (v: string | undefined) => !!v && /^\d+(\.\d+)?$/.test(v.trim());
/** "350.00 a month, in USD" or "6.00 an hour, in USD" (a monthly Rate since 0057); commission only: no Rate (0059). */
export const isCommissionOnly = (v: Record<string, string>) => v.pay_basis === 'commission';
export const rateWords = (v: Record<string, string>) => (isCommissionOnly(v) ? 'None: commission only' : `${v.rate ?? ''} ${v.pay_basis === 'hourly' ? 'an hour' : 'a month'}, in ${v.currency ?? ''}`);
/** "Full time: 6 days a week, 10 hours a day"; commission only: a flexible schedule. */
export const scheduleWords = (v: Record<string, string>) => (isCommissionOnly(v) || v.schedule === 'flexible' ? 'Flexible: you choose when you work'
  : `${v.schedule === 'part_time' ? 'Part time' : 'Full time'}: ${v.days_per_week ?? ''} days a week, ${v.hours_per_day ?? ''} hours a day`);
/** The Pay row of Schedule A. */
export const payWords = (v: Record<string, string>) => (isCommissionOnly(v) ? 'Commission only, under section 3.4: no Rate, no set days or hours' : 'The Rate below and the commission in section 3.4');
/** Remove the table row whose first cell starts with the label (rows that make no sense for a commission-only engagement). */
const dropRow = (md: string, label: string) => md.replace(new RegExp(`^\\| ${label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[^|]*\\|[^\n]*\n`, 'm'), '');

/** Replace the second cell of the table row whose first cell starts with the label. */
function row(md: string, label: string, value: string): string {
  const esc = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return md.replace(new RegExp(`^\\| ${esc}[^|]*\\| [^\\n]*$`, 'm'), (line) => { const cells = line.split('|'); cells[2] = ` ${value.replace(/\|/g, '/')} `; return cells.slice(0, 4).join('|') + (cells.length > 4 ? '|' + cells.slice(4).join('|') : ''); });
}
/** The filled text as the agreement renderer reads it: sub-headings, the company's legal name, any blank left as a line. */
export const forBlocks = (md: string, company: Company) => md.replace(/^## /gm, '### ').replace(/\[●\]/g, '________').replace(/\{\{company\}\}/g, companyName(company));

// ---------------------------------------------------------------- the investment agreement
export function investorFields(f: InvestorFacts, exemption: { category: string; paragraph: string }): Field[] {
  const first = f.investments.find((i) => i.is_initial) ?? f.investments[0];
  return [
    { key: 'invested', label: 'Invested Amount', value: first ? money(first.principal_cents, { cents: true }) : '', required: true, hint: 'From the investor\'s first investment.' },
    { key: 'yearly', label: 'Yearly Percentage', value: first ? `${first.yearly_bps / 100}%` : '', required: true },
    { key: 'investment_date', label: 'Investment Date', value: first ? day(first.investment_date) : '', required: true },
    { key: 'lockup_end', label: 'Lockup End Date', value: first ? day(first.lockup_end_date) : '', required: true },
    { key: 'exemption_paragraph', label: 'Accredited investor paragraph (if accredited)', value: exemption.paragraph }
  ];
}

export function investmentMarkdown(f: InvestorFacts, v: Record<string, string>, exemption: { category: string; paragraph: string }): string {
  const i = f.investor;
  const c = f.company;
  const extra = f.investments.filter((x) => !x.is_initial);
  let md = INVESTMENT_MD;
  md = row(md, 'Company\'s address and email for notices', [c.address, c.email].filter(Boolean).join('; ') || 'As on the Company\'s website');
  md = row(md, 'Investor\'s full legal name and type', `${i.legal_name}${i.investor_type ? ` (${i.investor_type})` : ''}`);
  md = row(md, 'Investor\'s residential or head office address', [i.address, i.email, phone(i.phone)].filter(Boolean).join('; '));
  md = row(md, 'Resident of Canada for tax purposes', i.tax_resident_canada === false ? `No. Country: ${i.tax_country ?? ''}` : 'Yes');
  md = row(md, 'Invested Amount', v.invested ?? '');
  md = row(md, 'Yearly Percentage', `${(v.yearly ?? '').replace(/%$/, '')}% per year`);
  md = row(md, 'Investment Date', v.investment_date ?? '');
  md = row(md, 'Lockup End Date', v.lockup_end ?? '');
  md = row(md, 'Investor\'s bank account for payments', 'On file with the Company (not printed here)');
  md = row(md, 'Additional investments', extra.length ? extra.map((x) => `${money(x.principal_cents, { cents: true })}, ${day(x.investment_date)}, lockup ends ${day(x.lockup_end_date)}`).join('; ') : 'None');
  // the signature lines
  md = md.replace(/By: _+ {2}Name: \[●\] {2}Title: \[●\] {2}Date: \[●\]/, `By: ${ON_SIGNATURE}  Name: ${c.signing_officer_name ?? ''}  Title: ${c.signing_officer_title ?? ''}  Date: ${DATE_SIGNED}`);
  md = md.replace(/Signature: _+ {2}Name: \[●\] {2}Title, if not an individual: \[●\] {2}Date: \[●\]/, `Signature: ${ON_SIGNATURE}  Name: ${i.legal_name}  Title, if not an individual: ${i.investor_type && i.investor_type !== 'individual' ? 'Authorized signatory' : 'Not applicable'}  Date: ${DATE_SIGNED}`);
  md = md.replace(/^Company: _+ {2}Date: \[●\]$/m, `Company: ${ON_SIGNATURE}  Date: ${DATE_SIGNED}`);
  md = md.replace(/^Investor: _+ {2}Date: \[●\]$/m, `Investor: ${ON_SIGNATURE}  Date: ${DATE_SIGNED}`);
  md = md.replace(/^Investor: _+ {2}Name: \[●\] {2}Date: \[●\]$/gm, `Investor: ${ON_SIGNATURE}  Name: ${i.legal_name}  Date: ${DATE_SIGNED}`);
  // Schedule C: each statement initialled with the signature; the legal advice line chosen when signing
  md = md.replace(/^(\| (?!Statement|Choice|Category|---)[^|]+\| )\[●\] \|$/gm, `$1initialled with the signature |`);
  md = md.replace(/I obtained independent legal advice from \[●\] of \[●\] before signing\./, 'I obtained independent legal advice before signing (the lawyer\'s name, if given, is in the signature record).');
  md = md.replace(/\| initialled with the signature \|(\s*\n\| I was advised)/, '| chosen when signing (see the signature record) |$1');
  md = md.replace(/(\| I was advised to obtain independent legal advice[^|]+\| )initialled with the signature \|/, '$1chosen when signing (see the signature record) |');
  // Schedule D: the category the Admin set
  const acc = exemption.category === 'accredited_investor';
  md = md.replace(/Paragraph of the definition: \[●\]/, `Paragraph of the definition: ${acc ? exemption.paragraph || 'as stated by the Investor' : 'not applicable'}`);
  md = md.replace(/^(\| \*\*Accredited investor\*\*[^\n]*\| )\[●\] \|$/m, `$1${acc ? 'initialled with the signature' : 'not chosen'} |`);
  md = md.replace(/^(\| \*\*Offering memorandum exemption[^\n]*\| )\[●\] \|$/m, `$1${acc ? 'not chosen' : 'initialled with the signature'} |`);
  md = md.replace(/\*\*Company use only\.\*\* Exemption relied on: \[●\]\. Steps taken to verify: \[●\]\. Report of exempt distribution filed on: \[●\]\./,
    `**Company use only.** Exemption relied on: ${acc ? 'accredited investor' : 'offering memorandum, eligible investor'}. Steps taken to verify: recorded by the Company. Report of exempt distribution filed on: recorded by the Company.`);
  return md;
}


export function investmentSummary(f: InvestorFacts, v: Record<string, string>): Array<{ label: string; value: string; fix?: string | null }> {
  const i = f.investor;
  return [
    { label: 'Investor', value: `${i.legal_name}${i.investor_type ? ` (${i.investor_type})` : ''}`, fix: '/investor/profile' },
    { label: 'Address, email and phone', value: [i.address, i.email, phone(i.phone)].filter(Boolean).join('; '), fix: '/investor/profile' },
    { label: 'Invested Amount', value: v.invested ?? '', fix: null },
    { label: 'Yearly Percentage', value: v.yearly ?? '', fix: null },
    { label: 'Investment Date', value: v.investment_date ?? '', fix: null },
    { label: 'Lockup End Date', value: v.lockup_end ?? '', fix: null }
  ];
}

// ---------------------------------------------------------------- the staff agreements
export function staffFields(f: StaffFacts): Field[] {
  const s = f.staff;
  const d = f.defaults;
  if (s.staff_type === 'va') {
    // pay, schedule and hours start from the defaults of the person's function (Program settings, 0057); Sales is
    // commission only (0059): no Rate, no hours asked
    const perWeek = num(d.days_per_week) && num(d.hours_per_day) ? String(+(Number(d.days_per_week) * Number(d.hours_per_day)).toFixed(2)) : (d.hours_per_week ?? '');
    const hours = { key: 'pay_basis', value: 'commission' };
    return [
      { key: 'country', label: 'Country', value: d.country ?? '', required: true },
      { key: 'pay_basis', label: 'Pay', value: d.pay_basis ?? '', required: true, options: [['monthly', 'A month'], ['hourly', 'An hour'], ['commission', 'Commission only']] },
      { key: 'rate', label: 'Rate', value: d.rate ?? '', required: true, hint: 'For example 350.00 a month, or 6.00 an hour', hiddenWhen: hours },
      { key: 'currency', label: 'Currency', value: d.currency ?? '', required: true },
      { key: 'schedule', label: 'Schedule', value: d.schedule ?? '', required: true, options: [['full_time', 'Full time'], ['part_time', 'Part time'], ['flexible', 'Flexible']], hiddenWhen: hours },
      { key: 'days_per_week', label: 'Days a week', value: d.days_per_week ?? '', required: true, hiddenWhen: hours },
      { key: 'hours_per_day', label: 'Hours a day', value: d.hours_per_day ?? '', required: true, hiddenWhen: hours },
      { key: 'hours_per_week', label: 'Hours a week', value: perWeek, required: true, hint: 'Days a week times hours a day, unless agreed otherwise', hiddenWhen: hours },
      { key: 'coverage', label: 'Coverage Hours: days and times (Toronto time)', value: d.coverage ?? '', required: true, hiddenWhen: hours },
      { key: 'start', label: 'Start Date', value: day(s.started_on), required: true },
      { key: 'platform', label: 'Hiring platform (payment)', value: d.platform ?? '', required: true },
      { key: 'pay_timing', label: 'Payment timing', value: d.pay_timing ?? '', required: true },
      { key: 'trial_days', label: 'Trial Period (days)', value: d.trial_days ?? '', required: true }
    ];
  }
  return [
    { key: 'address', label: 'Home address', value: s.home_address ?? '', required: true, hint: 'The staff member enters it in their profile; change it here only if it is wrong' },
    { key: 'licence', label: 'Driver\'s licence number', value: '', required: true },
    { key: 'wage', label: 'Hourly Wage (CA$)', value: d.wage ?? '', required: true, hint: 'For example 18.00' },
    { key: 'start', label: 'Start Date', value: day(s.started_on), required: true },
    { key: 'vehicle_types', label: 'Vehicle types authorized', value: d.vehicle_types ?? '', required: true },
    { key: 'pay_dates', label: 'Pay Dates', value: d.pay_dates ?? '', required: true },
    { key: 'licence_years', label: 'Minimum licence period (years)', value: d.licence_years ?? '', required: true }
  ];
}

const signatureLines = (md: string, c: Company, name: string) => md
  .replace(/^By: \[●\], \[●\] \(title\)\. Date: \[●\]$/m, `By: ${c.signing_officer_name ?? ''}, ${c.signing_officer_title ?? ''} (title). Date: ${DATE_SIGNED}. Signature: ${ON_SIGNATURE}.`)
  .replace(/^Name: \[●\]\. Signature: \[●\]\. Date: \[●\]$/m, `Name: ${name}. Signature: ${ON_SIGNATURE}. Date: ${DATE_SIGNED}.`);

export function staffMarkdown(f: StaffFacts, v: Record<string, string>): string {
  const s = f.staff;
  const c = f.company;
  if (s.staff_type === 'va') {
    let md = signatureLines(VA_MD, c, s.full_name);
    md = row(md, 'Contractor', `${s.full_name} (legal name), ${v.country ?? ''} (country), ${s.email ?? ''} (email)`);
    md = row(md, 'Role', VA_ROLE[s.va_function ?? ''] ?? (s.va_function ?? ''));
    md = row(md, 'Pay', payWords(v));
    if (isCommissionOnly(v)) {
      // commission only (0059): no Rate, no schedule, no Coverage Hours (section 3.1 says they do not apply)
      md = dropRow(dropRow(dropRow(md, 'Schedule'), 'Coverage Hours'), 'Rate');
    } else {
      md = row(md, 'Schedule', scheduleWords(v));
      md = row(md, 'Coverage Hours', `${v.coverage ?? ''}, ${v.hours_per_week ?? ''} hours a week`);
      md = row(md, 'Rate', rateWords(v));
    }
    md = row(md, 'Start Date', v.start ?? '');
    md = row(md, 'CarmaCars notice email', c.email ?? '');
    md = row(md, 'Payment Method', `Through ${v.platform ?? ''}`);
    md = row(md, 'Payment timing', v.pay_timing ?? '');
    md = row(md, 'Trial Period', `First ${v.trial_days ?? ''} days`);
    const fin = s.va_function === 'finance';
    md = row(md, 'Single Limit', fin && s.single_limit_cents != null ? `${money(s.single_limit_cents)} per payment` : 'Not applicable');
    md = row(md, 'Dual Approval Threshold', fin && s.dual_approval_threshold_cents != null ? `${money(s.dual_approval_threshold_cents)} per payment` : 'Not applicable');
    md = row(md, 'Approver', c.signing_officer_name ?? '');
    return md;
  }
  let md = signatureLines(FIELD_MD, c, s.full_name);
  md = row(md, 'Employee', `${s.full_name} (legal name), ${v.address ?? ''} (address), ${phone(s.phone)} (phone), ${s.email ?? ''} (email)`);
  md = row(md, 'Driver\'s licence', `Ontario Class G, number ${v.licence ?? ''}`);
  md = row(md, 'Role', FIELD_ROLE[s.field_function ?? ''] ?? (s.field_function ?? 'Driver and detailer'));
  md = row(md, 'Hourly Wage', `$${(v.wage ?? '').replace(/^\$/, '')} an hour`);
  md = row(md, 'Start Date', v.start ?? '');
  md = row(md, 'Vehicle types authorized', v.vehicle_types ?? '');
  md = row(md, 'Referral code', s.referral_code ?? 'Given in the staff portal');
  md = row(md, 'Pay Dates', v.pay_dates ?? '');
  md = row(md, 'Minimum licence period', `Full Class G held for at least ${v.licence_years ?? ''} years`);
  return md;
}

export const staffTitle = (f: StaffFacts) => (f.staff.staff_type === 'va' ? 'Virtual Assistant Contractor Agreement' : 'Field Staff Agreement');
export function staffSummary(f: StaffFacts, v: Record<string, string>): Array<{ label: string; value: string; fix?: string | null }> {
  const s = f.staff;
  const base = s.staff_type === 'va' ? null : '/staff/field/profile'; // the VA portal has no profile page: a wrong value is told to the Admin
  return s.staff_type === 'va'
    ? [{ label: 'Contractor', value: `${s.full_name}, ${v.country ?? ''}, ${s.email ?? ''}`, fix: base }, { label: 'Role', value: VA_ROLE[s.va_function ?? ''] ?? '', fix: null },
       { label: 'Pay', value: payWords(v), fix: null },
       ...(isCommissionOnly(v) ? [] : [{ label: 'Schedule', value: scheduleWords(v), fix: null }, { label: 'Coverage Hours', value: `${v.coverage ?? ''}, ${v.hours_per_week ?? ''} hours a week`, fix: null },
         { label: 'Rate', value: rateWords(v), fix: null }]),
       { label: 'Start Date', value: v.start ?? '', fix: null }, { label: 'Paid through', value: `${v.platform ?? ''}, ${v.pay_timing ?? ''}`, fix: null }]
    : [{ label: 'Employee', value: `${s.full_name}, ${v.address ?? ''}`, fix: base }, { label: 'Driver\'s licence', value: `Ontario Class G, number ${v.licence ?? ''}`, fix: null },
       { label: 'Role', value: FIELD_ROLE[s.field_function ?? ''] ?? '', fix: null }, { label: 'Hourly Wage', value: `$${(v.wage ?? '').replace(/^\$/, '')} an hour`, fix: null },
       { label: 'Start Date', value: v.start ?? '', fix: null }, { label: 'Pay Dates', value: v.pay_dates ?? '', fix: null }];
}

/** Blanks the filled text still has (each shown to the Admin before sending). */
export const blanksIn = (md: string) => (md.match(/\[●\]/g) ?? []).length;
