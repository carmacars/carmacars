import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Careers and hiring (docs/changes/2026-10-26-careers-hiring.md, migration 0173): a candidate applies from an Indeed link and
// passes (the invitation with the booking link), books a call; a Field staff knock-out is offered Sales (in person, with Remote sales
// as the other choice) and applies
// in one click with the details filled in; a remote role's knock-out is declined; the Admin scores the call with the rubric,
// the rank follows, and Hire invites the staff account. At 375 and 1440 with axe. Fictional people only.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
type Sql = ReturnType<typeof db>;

async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function admin(sql: Sql) {
  const id = randomUUID(); const email = `admin.hire.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Casey Hiring')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 120_000 });
}
// an interview day two days ahead for every role, so there are slots whatever the date
async function interviewDay(sql: Sql, adminId: string) {
  await sql`select app.hiring_day_save(${adminId}::uuid, jsonb_build_object('day', app.today() + 2, 'start_time', '09:00', 'end_time', '19:00', 'mode', 'phone', 'note', 'e2e careers'))`;
}
async function contact(page: Page, name: string, email: string) {
  await page.getByTestId('ap-full_name').fill(name);
  await page.getByTestId('ap-email').fill(email);
  await page.getByTestId('ap-phone').fill('416-555-0142');
}
/** Answers a role's questions: a choice (or several) by its words, a text by its value. */
async function answer(page: Page, a: Record<string, string | string[]>) {
  for (const [k, v] of Object.entries(a)) {
    const q = page.getByTestId(`q-${k}`);
    if (Array.isArray(v)) { for (const c of v) await q.getByText(c, { exact: true }).click(); }
    else if (await q.evaluate((el) => el.tagName === 'FIELDSET')) await q.getByText(v, { exact: true }).click();
    else await q.fill(v);
  }
}
const FIELD_PASS = {
  licence: 'Yes, a full G', years: '5 years or more', record: 'None', days: ['Monday', 'Friday', 'Saturday', 'Sunday'], hours: 'Full time (35 or more)', transport: 'My own car',
  experience: ['Delivery driver'], late: 'Message the office at once, keep the renter updated and follow the office\'s instructions',
  dent: 'Stay polite, photograph everything, note it in the app and let the office decide', cash: 'Count it in front of them, record it in the app right away and give them the receipt',
  start: '2026-11-02', pay: '20'
};
const SALES = {
  in_person: 'Yes', years: '3 to 5 years', done: ['Phone sales', 'Used a CRM'], commission: 'I like being paid for results', days: ['Thursday', 'Friday', 'Saturday', 'Sunday'],
  hours: 'Yes, all of them', languages: ['English'], turo: 'Ask what matters most to them, then show what is included (delivery, support, coverage options) and offer only the savings our rate sheet allows',
  discount: 'Explain the options we do have (longer rental rates, the non-refundable saving) and ask which works for them',
  toll: 'Listen, show them the toll record, explain the charge, and pass it to the office if they still dispute it', why_local: 'A person answers and fixes problems the same day.',
  expect: 'twenty', start: '2026-11-02', hours_week: '25'
};

const VA_PASS = {
  schedule: 'Yes, I can work this schedule every week', pay: 'Yes, I accept this pay', internet: 'Fiber or cable, 25 Mbps or faster, plus a backup connection',
  speed: '80 down, 40 up', backup: 'A generator, inverter or power station', english: 'Fluent: I handle calls on my own every day', years: '5 years or more',
  experience: 'Five years billing North American clients at an accounting firm: invoices, statements, reconciliations and payouts every day, in Excel and QuickBooks.',
  tools: ['QuickBooks', 'Stripe'], social: ['Designing posts in Canva'], skills: 'Accuracy to the cent, spreadsheets, clear written English.',
  business: 'Rents cars to customers in Toronto',
  role: 'I will price the charges after each rental, settle deposits, match tolls to bookings, bill the owners on the 15th and build their statements and payouts for the 10th.',
  scenario: 'Change nothing, verify by a phone number we already have and wait for written approval', other_jobs: 'No, this would be my only job', clients: 'No',
  school: 'No', education: 'College degree', career: 'A long-term career, growing with one company', canada: 'Maybe', start: '2026-11-09'
};

test('apply from Indeed and pass, book a call, the Admin scores it, the rank follows, Hire invites the staff account', async ({ page, browser }) => {
  test.setTimeout(600_000);
  const errors = watch(page);
  const sql = db();
  await sql`delete from app.rate_limit_hits where key like 'hire:%'`;
  const a = await admin(sql);
  await interviewDay(sql, a.id);

  // the public pages, at phone and desktop width
  for (const w of [375, 1440]) {
    await page.setViewportSize({ width: w, height: 900 });
    await page.goto('/careers', { waitUntil: 'networkidle' });
    await acceptCookies(page);
    await expect(page.getByTestId('role-field-staff')).toBeVisible();
    await axe(page, `/careers ${w}`);
    await page.goto('/careers/field-staff?src=indeed', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('role-facts')).toContainText('Hourly, discussed at interview');
    const ld = await page.locator('script[type="application/ld+json"]').allTextContents();
    expect(ld.some((s) => s.includes('"JobPosting"'))).toBe(true);
    expect(ld.join('')).not.toContain('"pts"');
    await axe(page, `/careers/field-staff ${w}`);
    await page.getByTestId('role-apply').click();
    await page.waitForURL(/\/careers\/field-staff\/apply\?src=indeed/);
    await expect(page.getByTestId('apply-form')).toBeVisible();
    await axe(page, `/careers/field-staff/apply ${w}`);
  }
  const html = await page.content();
  expect(html).not.toMatch(/"pts"|"ko"/);

  // an empty form shows what is missing; the answers are kept on the device as they are typed
  await page.getByTestId('ap-submit').click();
  await expect(page.getByTestId('apply-error')).toBeVisible();
  const email = `ana.${tag()}@example.test`;
  await contact(page, 'Ana Example', email);
  await answer(page, FIELD_PASS);
  await page.reload({ waitUntil: 'networkidle' });
  await expect(page.getByTestId('ap-email')).toHaveValue(email);
  await expect(page.getByTestId('q-licence').getByLabel('Yes, a full G')).toBeChecked();
  await page.getByTestId('ap-submit').click();
  await expect(page.getByTestId('apply-done')).toHaveAttribute('data-outcome', 'invited', { timeout: 60_000 });
  const [app] = await sql`select id, status, source, score from job_applications where email = ${email}`;
  expect(app?.status).toBe('invited');
  expect(app?.source).toBe('indeed');
  expect(Number(app?.score)).toBeGreaterThanOrEqual(60);
  await expect.poll(async () => { await sql`select app.process_events(1000)`; return (await sql`select count(*)::int n from notification_outbox where code = 'applicant_invited' and to_address = ${email}`)[0]!.n; }, { timeout: 30_000 }).toBe(1);

  // book a call from the confirmation (the same page as the email's link)
  await page.getByTestId('apply-book').click();
  await page.waitForURL(/\/careers\/book\//);
  await expect(page.getByTestId('booking')).toBeVisible();
  await axe(page, 'booking page');
  await page.getByTestId('book-slot').first().check({ force: true });
  await page.getByTestId('book-confirm').click();
  await expect(page.getByTestId('book-booked')).toBeVisible({ timeout: 60_000 });
  await expect.poll(async () => (await sql`select status from job_applications where id = ${app!.id}`)[0]?.status, { timeout: 30_000 }).toBe('booked');
  await expect.poll(async () => { await sql`select app.process_events(1000)`; return (await sql`select count(*)::int n from notification_outbox where code = 'applicant_booked' and to_address = ${email}`)[0]!.n; }, { timeout: 30_000 }).toBe(1);

  // the Admin: the calls of the day, Start, the rubric beside the call guide
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const ad = await ctx.newPage();
  await signIn(ad, a.email, '/admin/hiring?tab=calls');
  await expect(ad.getByTestId('hiring-calls')).toBeVisible({ timeout: 60_000 });
  await ad.goto(`/admin/hiring/${app!.id}#rubric`, { waitUntil: 'networkidle' });
  await expect(ad.getByTestId('cand-guide')).toContainText('0:00 to 1:00');
  await expect(ad.getByTestId('cand-breakdown')).toContainText('Yes, a full G');
  for (const [k, n] of Object.entries({ communication: 5, reliability: 4, role_skills: 4, customer: 3, judgement: 5, attitude: 5 })) await ad.getByTestId(`crit-${k}-${n}`).check({ force: true });
  await ad.getByTestId('decision-hire').check({ force: true });
  await expect(ad.getByTestId('rubric-totals')).toContainText('Interview 86');
  await ad.getByTestId('rubric-save').click();
  await expect(ad.getByTestId('rubric-msg')).toContainText('Rank', { timeout: 60_000 });
  const rankBefore = Number(/Rank (\d+)/.exec((await ad.getByTestId('rubric-msg').textContent()) ?? '')?.[1]);
  const [sc] = await sql`select interview_score, final_score from interview_scores where application_id = ${app!.id}`;
  expect(sc?.interview_score).toBe(86);
  await axe(ad, 'admin candidate');

  // another candidate scores higher: the first one moves down one place
  const other = `ben.${tag()}@example.test`;
  const r2 = (await sql`select public.server_hiring_apply(jsonb_build_object('role', 'field-staff', 'full_name', 'Ben Example', 'email', ${other}::text, 'phone', '4165550143',
    'answers', ${sql.json(FIELD_PASS as never)}::jsonb), null) as r`)[0]!.r as { token: string };
  await sql`select public.server_hiring_book(${r2.token}, (select s.id from interview_slots s join interview_days d on d.id = s.day_id where d.note = 'e2e careers' and s.starts_at > now()
    and not exists (select 1 from job_applications x where x.slot_id = s.id and x.status = 'booked') order by s.starts_at limit 1))`;
  const otherId = (await sql`select id from job_applications where email = ${other}`)[0]!.id as string;
  await sql`select app.hiring_score_save(${a.id}::uuid, jsonb_build_object('id', ${otherId}::uuid, 'scores', '{"communication":5,"reliability":5,"role_skills":5,"customer":5,"judgement":5,"attitude":5}'::jsonb, 'decision', 'hire'))`;
  await ad.reload({ waitUntil: 'networkidle' });
  // (another run may score candidates at the same time: the rank only has to move down, at least one place)
  const rankAfter = Number(/Rank (\d+) in Field staff/.exec((await ad.getByTestId('cand-status').textContent()) ?? '')?.[1]);
  expect(rankAfter).toBeGreaterThan(rankBefore);

  // Hire: the staff invitation into the field staff portal, then the staff agreement to send
  ad.once('dialog', (d) => void d.accept());
  await ad.getByTestId('hire').click();
  await expect(ad.getByTestId('hire-done')).toBeVisible({ timeout: 60_000 });
  await expect(ad.getByTestId('send-generated')).toBeVisible();
  const [hired] = await sql`select a.status, u.email, r.role from job_applications a join users u on u.id = a.hired_user_id join user_roles r on r.user_id = u.id where a.id = ${app!.id}`;
  expect(hired?.status).toBe('hired');
  expect(hired?.email).toBe(email);
  expect(hired?.role).toBe('field');

  // the Indeed link and message to paste
  await ad.goto('/admin/hiring?tab=roles', { waitUntil: 'networkidle' });
  await expect(ad.getByTestId('link-field-staff')).toHaveValue(/\/careers\/field-staff\/apply\?src=indeed$/);
  await expect(ad.getByTestId('msg-sales-in-person')).toHaveValue(/\/careers\/sales-in-person\/apply\?src=indeed/);
  await axe(ad, 'admin hiring roles');
  await ctx.close();

  expect(errors.filter((e) => !/favicon|Failed to load resource/i.test(e))).toEqual([]);
  await sql.end();
});

test('a Field staff knock-out is offered Sales with the details filled in; a remote role knock-out is declined', async ({ page }) => {
  test.setTimeout(400_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits where key like 'hire:%'`;
  const email = `cy.${tag()}@example.test`;
  await page.goto('/careers/field-staff/apply?src=indeed', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await contact(page, 'Cy Example', email);
  await answer(page, { ...FIELD_PASS, licence: 'G2' });
  await page.getByTestId('ap-submit').click();
  await expect(page.getByTestId('apply-done')).toHaveAttribute('data-outcome', 'referred', { timeout: 60_000 });
  const [f] = await sql`select a.id, a.status, a.token, r.slug from job_applications a join hiring_roles r on r.id = a.referred_role_id where a.email = ${email}`;
  expect(f?.status).toBe('referred');
  expect(f?.slug).toBe('sales-in-person');
  await expect.poll(async () => { await sql`select app.process_events(1000)`; return (await sql`select payload ->> 'apply_url' u from notification_outbox where code = 'applicant_referred' and to_address = ${email}`)[0]?.u as string | undefined; }, { timeout: 30_000 })
    .toContain(`/careers/sales-in-person/apply?ref=${f!.token as string}&src=referral`);
  expect((await sql`select count(*)::int n from notification_outbox where code = 'applicant_declined' and to_address = ${email}`)[0]!.n).toBe(0);
  expect((await sql`select payload ->> 'alt_apply_url' u from notification_outbox where code = 'applicant_referred' and to_address = ${email}`)[0]?.u).toContain('/careers/sales-remote/apply');

  // the one-click link: the Sales form with the name, email and phone filled in, linked to the Field application
  await page.goto(`/careers/sales-in-person/apply?ref=${f!.token as string}&src=referral`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('apply-prefilled')).toBeVisible();
  await expect(page.getByTestId('ap-email')).toHaveValue(email);
  await axe(page, 'sales apply prefilled');
  await answer(page, SALES);
  await page.getByTestId('ap-submit').click();
  await expect(page.getByTestId('apply-done')).toBeVisible({ timeout: 60_000 });
  const [s] = await sql`select source, referred_from from job_applications where email = ${email} and role_id = (select id from hiring_roles where slug = 'sales-in-person')`;
  expect(s?.source).toBe('referral');
  expect(s?.referred_from).toBe(f!.id);

  // a remote assistant role (opened for the test): refusing the schedule is a knock-out, and every VA who does not pass is
  // referred to Sales (remote) (0179)
  await sql`update hiring_roles set active = true where slug = 'va-finance-billing'`;
  try {
    const fin = `dee.${tag()}@example.test`;
    await page.goto('/careers/va-finance-billing/apply?src=onlinejobs', { waitUntil: 'networkidle' });
    await contact(page, 'Dee Example', fin);
    await answer(page, { ...VA_PASS, schedule: 'No' });
    await page.getByTestId('ap-submit').click();
    await expect(page.getByTestId('apply-done')).toHaveAttribute('data-outcome', 'referred', { timeout: 60_000 });
    const [d] = await sql`select a.status, a.source, r.slug from job_applications a join hiring_roles r on r.id = a.referred_role_id where a.email = ${fin}`;
    expect(`${d?.status}/${d?.source}/${d?.slug}`).toBe('referred/onlinejobs/sales-remote');
  } finally {
    await sql`update hiring_roles set active = false where slug = 'va-finance-billing'`;
  }
  await sql.end();
});
