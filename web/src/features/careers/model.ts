// Careers and hiring (migration 0173): what the public pages, the booking page and Admin > People > Hiring share. The points,
// knock-outs and pass marks stay in the database (app.hiring_score); nothing here scores an application.

export type QuestionType = 'single' | 'multi' | 'text' | 'para' | 'date';
export interface Question { key: string; label: string; type: QuestionType; hint?: string; placeholder?: string; required: boolean; choices?: string[] }
export interface RoleDetails { about?: string; duties?: string[]; requirements?: string[]; hours?: string; pay_detail?: string[]; test_task?: string | null }
export interface RolePublic {
  slug: string; title: string; short_title: string; summary: string; details: RoleDetails; location: string; remote: boolean; applicant_countries: string[];
  employment_types: string[]; pay_text: string; pay_currency: string | null; pay_min_cents: number | null; pay_max_cents: number | null; pay_unit: 'HOUR' | 'MONTH' | null;
  posted_on: string | null; updated_at: string; questions: Question[];
}
export interface RoleCard { slug: string; title: string; short_title: string; summary: string; location: string; remote: boolean; pay_text: string; employment_types: string[]; posted_on: string | null }

export const SOURCES = ['direct', 'indeed', 'onlinejobs', 'referral', 'admin', 'other'] as const;
export type Source = (typeof SOURCES)[number];
export const SOURCE_WORDS: Record<string, string> = { direct: 'Website', indeed: 'Indeed', onlinejobs: 'OnlineJobs.ph', referral: 'Referred from another role', admin: 'Added by an Admin', other: 'Other' };

/** ?src= of an apply link: indeed, onlinejobs (also onlinejobs.ph, ojph), referral; anything else is "other", nothing is "direct". */
export function sourceOf(src: string | null | undefined): Source {
  const s = (src ?? '').trim().toLowerCase();
  if (!s) return 'direct';
  if (s === 'indeed') return 'indeed';
  if (s === 'onlinejobs' || s === 'onlinejobs.ph' || s === 'ojph') return 'onlinejobs';
  if (s === 'referral') return 'referral';
  return 'other';
}
export const UTM_KEYS = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term'] as const;
export function utmOf(sp: Record<string, string | string[] | undefined>): Record<string, string> {
  const o: Record<string, string> = {};
  for (const k of UTM_KEYS) { const v = sp[k]; const s = Array.isArray(v) ? v[0] : v; if (s) o[k] = s.slice(0, 100); }
  return o;
}

export const STATUS_WORDS: Record<string, string> = {
  new: 'New', declined: 'Declined', below_bar: 'Below the bar: review', invited: 'Invited to book', referred: 'Referred to another role', booked: 'Call booked',
  interviewed: 'Interviewed', hired: 'Hired', rejected: 'Not hired', no_show: 'No show', withdrawn: 'Withdrawn'
};
export const STATUS_FILTERS: Array<[string, string]> = [['', 'All'], ['open', 'Open (to act on)'], ['below_bar', 'Below the bar'], ['invited', 'Invited'], ['booked', 'Booked'],
  ['interviewed', 'Interviewed'], ['referred', 'Referred'], ['declined', 'Declined'], ['hired', 'Hired'], ['rejected', 'Not hired'], ['no_show', 'No show'], ['withdrawn', 'Withdrawn']];
export const DECISIONS: Array<[string, string]> = [['hire', 'Hire'], ['maybe', 'Maybe'], ['no', 'No'], ['no_show', 'No show']];
export const OUTCOME_WORDS: Record<string, { h: string; p: string }> = {
  invited: { h: 'Thank you. We would like to talk.', p: 'Your answers fit what this role needs. Book a short call now, or use the link we just emailed you.' },
  received: { h: 'Thank you. We have your application.', p: 'A person at CarmaCars reads every application. If your experience fits what we need, we will write to you with a time to talk.' },
  declined: { h: 'Thank you for applying.', p: 'This role has requirements your answers do not meet, so we cannot move forward this time. We have emailed you the details.' },
  referred: { h: 'Thank you for applying.', p: 'This role is not the right fit, but another one may be. We have emailed you a one-click link to apply.' }
};

export const applyPath = (slug: string, src?: string) => `/careers/${slug}/apply${src ? `?src=${encodeURIComponent(src)}` : ''}`;
/** The text an Admin pastes into an Indeed (or OnlineJobs.ph) message to a candidate. */
export function inviteMessage(roleTitle: string, link: string, minutes = 5): string {
  return `Hi, thank you for applying for ${roleTitle} at CarmaCars. The next step is a short application with a few questions about the role (about ${minutes} minutes): ${link} . If your answers fit, you can book a 15-minute call right away.`;
}

// ---------------------------------------------------------------- times (Toronto; Manila for the remote roles)
export const TORONTO = 'America/Toronto';
export const MANILA = 'Asia/Manila';
export function fmtSlot(iso: string, zone: string = TORONTO, withDay = true): string {
  const d = new Date(iso);
  const time = new Intl.DateTimeFormat('en-CA', { timeZone: zone, hour: 'numeric', minute: '2-digit', hour12: true }).format(d).replace(/\./g, '').replace(/\s+/g, ' ');
  if (!withDay) return time;
  const day = new Intl.DateTimeFormat('en-CA', { timeZone: zone, weekday: 'long', month: 'long', day: 'numeric' }).format(d);
  return `${day} at ${time}`;
}
/** The Toronto day of an instant (YYYY-MM-DD), to group the slots. */
export function torontoDay(iso: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TORONTO, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(iso));
}
export function fmtDay(ymd: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', weekday: 'long', month: 'long', day: 'numeric' }).format(new Date(`${ymd}T12:00:00Z`));
}

// ---------------------------------------------------------------- the rubric (the database computes the same; shown live while scoring)
export interface Criterion { key: string; label: string; weight: number; hint: string }
export function interviewScore(criteria: Criterion[], scores: Record<string, number | undefined>): number | null {
  const given = criteria.filter((c) => typeof scores[c.key] === 'number');
  if (!given.length) return null;
  return Math.round(criteria.reduce((s, c) => s + (scores[c.key] ?? 0) * c.weight, 0) / 5);
}
export function finalScore(screening: number | null, interview: number | null): number | null {
  if (interview === null) return null;
  return Math.round(((screening ?? 0) * 0.4 + interview * 0.6) * 10) / 10;
}

// ---------------------------------------------------------------- JobPosting structured data (developers.google.com/search/docs/appearance/structured-data/job-posting)
export function jobPostingLd(r: RolePublic, base: string, org: { name: string; logo?: string | null; street?: string | null; city?: string | null; region?: string | null; postal?: string | null }) {
  const html = [
    r.details.about ? `<p>${esc(r.details.about)}</p>` : '',
    `<p>${esc(r.summary)}</p>`,
    r.details.duties?.length ? `<p><strong>What you do</strong></p><ul>${r.details.duties.map((d) => `<li>${esc(d)}</li>`).join('')}</ul>` : '',
    r.details.requirements?.length ? `<p><strong>What you need</strong></p><ul>${r.details.requirements.map((d) => `<li>${esc(d)}</li>`).join('')}</ul>` : '',
    r.details.hours ? `<p><strong>Hours</strong>: ${esc(r.details.hours)}</p>` : '',
    `<p><strong>Pay</strong>: ${esc(r.pay_text)}</p>`,
    r.details.pay_detail?.length ? `<ul>${r.details.pay_detail.map((d) => `<li>${esc(d)}</li>`).join('')}</ul>` : ''
  ].join('');
  const posted = r.posted_on ?? r.updated_at.slice(0, 10);
  const valid = new Date(`${posted}T12:00:00Z`); valid.setUTCDate(valid.getUTCDate() + 60);
  const fullyRemote = r.remote && /^remote$/i.test(r.location.trim());
  const node: Record<string, unknown> = {
    '@type': 'JobPosting', title: r.title, description: html, datePosted: posted, validThrough: valid.toISOString().slice(0, 10),
    employmentType: r.employment_types.length === 1 ? r.employment_types[0] : r.employment_types,
    identifier: { '@type': 'PropertyValue', name: org.name, value: r.slug }, directApply: true,
    hiringOrganization: { '@type': 'Organization', name: org.name, sameAs: `${base}/`, ...(org.logo ? { logo: org.logo } : {}) },
    url: `${base}/careers/${r.slug}`
  };
  if (!fullyRemote) {
    node.jobLocation = { '@type': 'Place', address: { '@type': 'PostalAddress', ...(org.street ? { streetAddress: org.street } : {}), addressLocality: org.city || 'Toronto',
      addressRegion: org.region || 'ON', ...(org.postal ? { postalCode: org.postal } : {}), addressCountry: 'CA' } };
  }
  if (r.remote) {
    node.jobLocationType = 'TELECOMMUTE';
    if (r.applicant_countries.length) node.applicantLocationRequirements = r.applicant_countries.map((c) => ({ '@type': 'Country', name: c }));
  }
  if (r.pay_currency && r.pay_min_cents !== null && r.pay_unit) {
    node.baseSalary = { '@type': 'MonetaryAmount', currency: r.pay_currency, value: { '@type': 'QuantitativeValue', minValue: r.pay_min_cents / 100,
      ...(r.pay_max_cents !== null ? { maxValue: r.pay_max_cents / 100 } : {}), unitText: r.pay_unit } };
  }
  return node;
}
const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** "Full time, part time" from the schema.org employment types. */
export function employmentWords(types: string[]): string {
  const W: Record<string, string> = { FULL_TIME: 'full time', PART_TIME: 'part time', CONTRACTOR: 'contractor', TEMPORARY: 'temporary' };
  const s = types.map((t) => W[t] ?? t.toLowerCase()).join(', ');
  return s.charAt(0).toUpperCase() + s.slice(1);
}
