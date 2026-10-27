// Careers and hiring (migration 0173): where an applicant came from, the times on the booking page, the rubric's live
// figures (the database computes the same), the role page's title and description, and the JobPosting structured data.
// npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applyPath, employmentWords, finalScore, fmtSlot, interviewScore, inviteMessage, jobPostingLd, MANILA, sourceOf, torontoDay, utmOf, type Criterion, type RolePublic } from './model.ts';
import { roleDescription, roleTitle } from './seo.ts';

const CRIT: Criterion[] = [
  { key: 'communication', label: 'Communication', weight: 20, hint: '' }, { key: 'reliability', label: 'Reliability and availability', weight: 20, hint: '' },
  { key: 'role_skills', label: 'Role skills', weight: 20, hint: '' }, { key: 'customer', label: 'Customer or sales instinct', weight: 15, hint: '' },
  { key: 'judgement', label: 'Judgement on the scenarios', weight: 15, hint: '' }, { key: 'attitude', label: 'Attitude', weight: 10, hint: '' }];

test('source: indeed, onlinejobs, referral; nothing is the website; anything else is other', () => {
  assert.equal(sourceOf('Indeed'), 'indeed');
  assert.equal(sourceOf('onlinejobs.ph'), 'onlinejobs');
  assert.equal(sourceOf('referral'), 'referral');
  assert.equal(sourceOf(''), 'direct');
  assert.equal(sourceOf(null), 'direct');
  assert.equal(sourceOf('facebook'), 'other');
  assert.deepEqual(utmOf({ utm_source: 'indeed', utm_campaign: ['oct', 'x'], other: 'y' }), { utm_source: 'indeed', utm_campaign: 'oct' });
  assert.equal(applyPath('field-staff', 'indeed'), '/careers/field-staff/apply?src=indeed');
  assert.match(inviteMessage('Field Staff: Driver and Detailer', 'https://carmacars.ca/careers/field-staff/apply?src=indeed'), /field-staff\/apply\?src=indeed/);
});

test('times: Toronto by default, Manila beside it for a remote role', () => {
  const at = '2026-10-29T13:00:00Z'; // 9:00 am in Toronto (EDT), 9:00 pm in Manila
  assert.equal(fmtSlot(at), 'Thursday, October 29 at 9:00 am');
  assert.equal(fmtSlot(at, MANILA, false), '9:00 pm');
  assert.equal(torontoDay('2026-10-30T02:30:00Z'), '2026-10-29');
});

test('rubric: the interview score of 100 from the weights, the final score 40% screening and 60% interview', () => {
  const s = { communication: 5, reliability: 4, role_skills: 4, customer: 3, judgement: 5, attitude: 5 };
  assert.equal(interviewScore(CRIT, s), 86);
  assert.equal(finalScore(96, 86), 90);
  assert.equal(finalScore(95, 86), 89.6);
  assert.equal(interviewScore(CRIT, {}), null);
  assert.equal(finalScore(80, null), null);
  assert.equal(interviewScore(CRIT, Object.fromEntries(CRIT.map((c) => [c.key, 5]))), 100);
});

const ROLE: RolePublic = { slug: 'va-customer-service', title: 'Customer Service and Growth Coordinator (Remote)', short_title: 'Customer service (VA)',
  summary: 'Answer calls, email and WhatsApp within 15 minutes, quote from our rate sheet, send agreements and payment links, and grow our listings and owner network. Remote, 40 hours a week.',
  details: { about: 'About <us>', duties: ['Answer'], requirements: ['Two years'], hours: 'Wed to Sun' }, location: 'Remote', remote: true, applicant_countries: ['Philippines'],
  employment_types: ['CONTRACTOR'], pay_text: 'US$5.00 to $6.50 an hour', pay_currency: 'USD', pay_min_cents: 500, pay_max_cents: 650, pay_unit: 'HOUR', posted_on: '2026-10-26', updated_at: '2026-10-26T00:00:00Z', questions: [] };

test('role page: title within 70 characters, description within 70 to 170', () => {
  assert.ok(roleTitle(ROLE.title).length <= 70);
  assert.equal(roleTitle('Field Staff: Driver and Detailer'), 'Field Staff: Driver and Detailer | Careers at CarmaCars');
  const dsc = roleDescription(ROLE);
  assert.ok(dsc.length >= 70 && dsc.length <= 170, `${dsc.length}`);
  assert.ok(roleDescription({ summary: 'Short.', location: 'Toronto', pay_text: 'Hourly, discussed at interview' }).length >= 30);
});

test('JobPosting: a remote role has the countries and the pay; an on-site role has the address and no pay when unknown', () => {
  const j = jobPostingLd(ROLE, 'https://carmacars.ca', { name: 'CarmaCars' }) as Record<string, unknown>;
  assert.equal(j['@type'], 'JobPosting');
  assert.equal(j.jobLocationType, 'TELECOMMUTE');
  assert.equal(j.jobLocation, undefined);
  assert.deepEqual(j.applicantLocationRequirements, [{ '@type': 'Country', name: 'Philippines' }]);
  assert.deepEqual((j.baseSalary as { value: unknown }).value, { '@type': 'QuantitativeValue', minValue: 5, maxValue: 6.5, unitText: 'HOUR' });
  assert.equal(j.validThrough, '2026-12-25');
  assert.match(String(j.description), /About &lt;us&gt;/);
  const field = jobPostingLd({ ...ROLE, slug: 'field-staff', location: 'Toronto and the GTA (on site)', remote: false, applicant_countries: [], employment_types: ['FULL_TIME', 'PART_TIME'],
    pay_currency: null, pay_min_cents: null, pay_max_cents: null, pay_unit: null }, 'https://carmacars.ca', { name: 'CarmaCars', city: 'Toronto', region: 'ON' }) as Record<string, unknown>;
  assert.equal(field.baseSalary, undefined);
  assert.equal(field.jobLocationType, undefined);
  assert.deepEqual(field.employmentType, ['FULL_TIME', 'PART_TIME']);
  assert.equal(((field.jobLocation as { address: Record<string, string> }).address).addressCountry, 'CA');
  assert.equal(employmentWords(['FULL_TIME', 'PART_TIME']), 'Full time, part time');
});
