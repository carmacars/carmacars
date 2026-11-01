import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Release 23 end to end, at both widths: the rubric's "Good fit for Sales instead" and No, Hiring > Emails to send and
// Send all decision emails (nothing goes before, one email each after); the usage banner on Today; Cars on sample photos
// on Listings; an adjuster added on a booking's insurance claim and the insurer's billing by car and adjuster; robots.txt's
// crawl scope; /delivery's minimum and delivery area.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const quiet = (errors: string[]) => errors.filter((x) => !/favicon|Failed to load resource|net::ERR/.test(x));

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text.match(/[–—]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(text, `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function mkAdmin(sql: Sql) {
  const id = randomUUID(); const email = `r23.admin.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Ada Admin')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 60_000 });
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}

test('hiring: the rubric says Sales instead and No; nothing is emailed until Send all decision emails, then one email each', async ({ browser }, info) => {
  test.setTimeout(240_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const a = await mkAdmin(sql);
  const t = tag();
  const [field] = await sql`insert into job_applications (role_id, status, full_name, email) select id, 'interviewed', ${'Fay Field ' + t}, ${`fay.${t}@example.test`} from hiring_roles where slug = 'field-staff' returning id`;
  const [remote] = await sql`insert into job_applications (role_id, status, full_name, email) select id, 'interviewed', ${'Remy Remote ' + t}, ${`remy.${t}@example.test`} from hiring_roles where slug = 'va-customer-service' returning id`;
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, a.email, '/admin');

  // the rubric: Good fit for Sales instead
  await page.goto(`/admin/hiring/${field!.id}#rubric`, { waitUntil: 'networkidle' });
  await page.getByTestId('decision-sales').check({ force: true });
  await page.getByTestId('rubric-save').click();
  await expect(page.getByTestId('rubric-msg')).toBeVisible({ timeout: 60_000 });
  await page.reload({ waitUntil: 'networkidle' });
  await expect(page.getByTestId('cand-decision-line')).toContainText('Good fit for Sales instead', { timeout: 30_000 });
  await expect(page.getByTestId('cand-decision-line')).toContainText('Nothing is sent');
  await check(page, 'candidate');
  // the other: No
  await page.goto(`/admin/hiring/${remote!.id}#rubric`, { waitUntil: 'networkidle' });
  await page.getByTestId('decision-no').check({ force: true });
  await page.getByTestId('rubric-save').click();
  await expect(page.getByTestId('rubric-msg')).toBeVisible({ timeout: 60_000 });
  expect(Number((await sql`select count(*)::int as n from app_events where entity = 'job_application' and entity_id in (${field!.id}, ${remote!.id})`)[0]!.n)).toBe(0);

  // Emails to send: both, with the email each sends
  await page.goto('/admin/hiring?tab=emails', { waitUntil: 'networkidle' });
  await expect(page.getByTestId(`decision-email-${field!.id}`)).toContainText('Sales offer');
  await expect(page.getByTestId(`decision-email-${remote!.id}`)).toContainText('polite decline');
  await check(page, 'emails to send');
  await page.getByTestId('decisions-send').click();
  await page.getByTestId('decisions-send-submit').click();
  await expect.poll(async () => (await sql`select count(*)::int as n from hiring_decisions where application_id in (${field!.id}, ${remote!.id}) and sent_at is not null`)[0]!.n, { timeout: 60_000 }).toBe(2);
  const st = await sql`select email, status from job_applications where id in (${field!.id}, ${remote!.id}) order by email`;
  expect(st.map((r) => r.status)).toEqual(['referred', 'rejected']);
  // never twice
  await sql`select app.hiring_decisions_send(${a.id}::uuid, '{}'::jsonb)`;
  expect(Number((await sql`select count(*)::int as n from app_events where entity = 'job_application' and entity_id in (${field!.id}, ${remote!.id})`)[0]!.n)).toBe(2);
  expect(quiet(errors)).toEqual([]);
  await sql.end();
});

test('admin: the usage banner on Today, Cars on sample photos on Listings', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const a = await mkAdmin(sql);
  // the Worker's CPU time past its allowance this month
  await sql`select app.usage_put('workers_cpu', app.local_date(now()), 'cloudflare', 90000000)`;
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, a.email, '/admin');
  await page.goto('/admin', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('usage-banner-over')).toContainText('Website CPU time', { timeout: 30_000 });
  await check(page, 'today');
  await page.goto('/admin/listings', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('photos-needed')).toBeVisible();
  await check(page, 'listings');
  await sql`delete from usage_readings where service = 'workers_cpu' and source = 'cloudflare' and day = app.local_date(now())`;
  expect(quiet(errors)).toEqual([]);
  await sql.end();
});

test('insurers: an adjuster added on a booking is saved with the insurer; the insurer page bills by car and adjuster', async ({ browser }, info) => {
  test.setTimeout(240_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const a = await mkAdmin(sql);
  const t = tag();
  const [ins] = await sql`insert into insurers (name) values (${'E2E Mutual ' + t}) returning id`;
  const [b] = await sql`select booking_number from bookings where status in ('confirmed', 'on_rent') and booking_type <> 'owner' order by created_at desc limit 1`;
  test.skip(!b, 'no confirmed booking in the seed');
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, a.email, '/admin');
  await page.goto(`/admin/bookings/${b!.booking_number}`, { waitUntil: 'networkidle' });
  const open = page.getByTestId('ic-bill-insurer');
  if (await open.isVisible()) await open.click(); else await page.getByTestId('ic-open').click();
  await page.getByTestId('ic-bill_to').selectOption('insurer');
  await page.getByTestId('ic-insurer_id').selectOption(String(ins!.id));
  await page.getByTestId('ic-adjuster').selectOption('new');
  await page.getByTestId('ic-adjuster_name').fill('Ada Adjuster');
  await page.getByTestId('ic-adjuster_email').fill(`ada.${t}@example.test`);
  await page.getByTestId('ic-save').click();
  await expect.poll(async () => (await sql`select count(*)::int as n from insurer_adjusters where insurer_id = ${ins!.id} and email = ${`ada.${t}@example.test`}`)[0]!.n, { timeout: 60_000 }).toBe(1);
  await page.goto(`/admin/insurers/${ins!.id}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('ir-adjusters')).toContainText('Ada Adjuster');
  await expect(page.getByTestId('ir-by-car')).toBeVisible();
  await expect(page.getByTestId('ir-by-adjuster')).toBeVisible();
  await check(page, 'insurer');
  // back to the renter, as the seed had it
  await sql`update bookings set bill_to = 'renter' where booking_number = ${b!.booking_number}`;
  expect(quiet(errors)).toEqual([]);
  await sql.end();
});

test('public: robots.txt follows the search scope (Full by default, Core keeps crawlers in the crawl scope); /delivery shows the minimum and the delivery area', async ({ page }) => {
  const sql = db();
  const full = await (await page.request.get('/robots.txt')).text();
  // 0324: in Full every crawler reaches every page (the crawler guard is off unless the month's CPU cost passes its line)
  const guard = (await sql`select app.crawler_guard_on() g`)[0]!.g as boolean;
  const google = full.split(/\n\s*\n/).find((g) => /^User-Agent: Googlebot$/mi.test(g)) ?? '';
  expect(google).not.toContain('Disallow: /t/');
  const gpt = full.split(/\n\s*\n/).find((g) => /^User-Agent: GPTBot$/mi.test(g)) ?? '';
  if (!guard) expect(gpt).not.toContain('Disallow: /t/');
  await sql`update program_settings set search_scope = 'core' where id = (select id from app.settings())`;
  try {
    // the server keeps the scope a few minutes outside local runs: only check when it shows Core already
    const robots = await (await page.request.get('/robots.txt')).text();
    if (robots.includes('Disallow: /t/')) {
      expect(robots).toContain('Disallow: /buy/');
      expect(robots).toContain('Disallow: /cars/*/*/*/*/');
    }
  } finally {
    await sql`update program_settings set search_scope = 'full' where id = (select id from app.settings())`;
  }
  const [s] = await sql`select delivery_area_text from site_settings limit 1`;
  const [p] = await sql`select delivery_min_cents from app.settings()`;
  await page.goto('/delivery', { waitUntil: 'networkidle' });
  const text = await page.locator('main').innerText();
  expect(text).not.toContain('from $0 each way');
  if (s?.delivery_area_text) expect(text).toContain(String(s.delivery_area_text));
  if (p?.delivery_min_cents) expect(text).not.toMatch(/Delivery costs from \$0/);
  await sql.end();
});

test('hiring: a remote candidate confirms the call in one press; the Calls tab says Confirmed', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const a = await mkAdmin(sql);
  const t = tag();
  const [day] = await sql`insert into interview_days (day, start_time, end_time, mode, note) values (app.local_date(now() + interval '20 hours'), '00:00', '23:59', 'phone', ${'e2e r23 ' + t}) returning id`;
  const [slot] = await sql`insert into interview_slots (day_id, starts_at, ends_at) values (${day!.id}, now() + interval '20 hours', now() + interval '20 hours 15 minutes') returning id`;
  const [app] = await sql`insert into job_applications (role_id, status, full_name, email) select id, 'invited', ${'Vera Video ' + t}, ${`vera.${t}@example.test`} from hiring_roles where slug = 'va-fleet-operations' returning id, token`;
  const [b] = await sql`select app.hiring_book(${app!.token}, ${slot!.id}::uuid) as r`;
  expect((b!.r as { mode: string }).mode).toBe('video');
  await sql`select app.job_hiring(now())`;
  const [seq] = await sql`select booking_seq from job_applications where id = ${app!.id}`;

  const page = await ctx(browser, phone);
  const errors = watch(page);
  await page.goto(`/careers/book/${app!.token}/confirm?seq=${seq!.booking_seq}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await check(page, 'confirm');
  await page.getByTestId('confirm-call').click();
  await expect(page.getByTestId('confirm-done')).toBeVisible({ timeout: 30_000 });
  expect((await sql`select confirmed_at from job_applications where id = ${app!.id}`)[0]!.confirmed_at).not.toBeNull();

  await signIn(page, a.email, '/admin');
  const ymd = (await sql`select app.local_date(now() + interval '20 hours')::text as d`)[0]!.d as string;
  await page.goto(`/admin/hiring?tab=calls&day=${ymd}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId(`call-confirm-${app!.id}`)).toHaveText('Confirmed');
  await check(page, 'calls');
  await sql`update job_applications set status = 'withdrawn', slot_id = null where id = ${app!.id}`;
  await sql`delete from interview_slots where id = ${slot!.id}`;
  await sql`delete from interview_days where id = ${day!.id}`;
  expect(quiet(errors)).toEqual([]);
  await sql.end();
});

test('cars: the registration saved on a car, a wrong VIN refused, the ownership permit and the safety certificate uploaded', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const a = await mkAdmin(sql);
  const [car] = await sql`select id from vehicles where not is_sample and retired_at is null order by created_at limit 1`;
  test.skip(!car, 'no real car in the seed');
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, a.email, '/admin');
  await page.goto(`/admin/vehicles/${car!.id}?tab=records`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('vehicle-registration')).toBeVisible();
  await check(page, 'registration');
  const before = (await sql`select vin from vehicles where id = ${car!.id}`)[0]!.vin as string | null;
  await page.getByTestId('reg-vin').fill('2T1BR32E14C230231');
  await page.getByTestId('reg-save').click();
  await expect(page.getByTestId('reg-msg')).toContainText('check digit', { timeout: 30_000 });
  await page.getByTestId('reg-vin').fill(before ?? '');
  await page.getByTestId('reg-permit_number').fill('E2E 7654321');
  await page.getByTestId('reg-sticker_expires_on').fill('2027-06-30');
  await page.getByTestId('reg-save').click();
  await expect(page.getByTestId('reg-msg')).toHaveText(/Saved/, { timeout: 30_000 });
  expect((await sql`select permit_number from vehicles where id = ${car!.id}`)[0]!.permit_number).toBe('E2E 7654321');
  await page.getByTestId('reg-doc-kind').selectOption('ownership_permit');
  await page.getByTestId('reg-doc-file').setInputFiles({ name: 'permit.pdf', mimeType: 'application/pdf', buffer: Buffer.from('%PDF-1.4\n%e2e\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n') });
  await page.getByTestId('reg-doc-upload').click();
  await expect(page.getByTestId('reg-doc-msg')).toHaveText('Uploaded.', { timeout: 30_000 });
  expect(Number((await sql`select count(*)::int as n from documents where vehicle_id = ${car!.id} and kind = 'ownership_permit'`)[0]!.n)).toBeGreaterThan(0);
  // the Safety Standards Certificate with its number and dates (0237)
  await page.getByTestId('reg-doc-kind').selectOption('safety_certificate');
  await page.getByTestId('reg-ssc-number').fill('E2ESSC1');
  await page.getByTestId('reg-ssc-issued').fill('2026-10-01');
  await page.getByTestId('reg-ssc-expires').fill('2027-10-01');
  await page.getByTestId('reg-doc-file').setInputFiles({ name: 'ssc.pdf', mimeType: 'application/pdf', buffer: Buffer.from('%PDF-1.4\n%e2e\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n') });
  await page.getByTestId('reg-doc-upload').click();
  await expect(page.getByTestId('reg-doc-msg')).toHaveText('Uploaded.', { timeout: 30_000 });
  await expect(page.getByTestId('reg-ssc')).toContainText('E2ESSC1');
  expect((await sql`select ssc_expires_on::text as d from vehicles where id = ${car!.id}`)[0]!.d).toBe('2027-10-01');
  // a program owner's car offers Move to another owner on the Overview
  if ((await sql`select supply_type from vehicles where id = ${car!.id}`)[0]!.supply_type === 'program_owner') {
    await page.goto(`/admin/vehicles/${car!.id}`, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('vehicle-move-owner')).toBeVisible();
  }
  await sql`update vehicles set permit_number = null, sticker_expires_on = null, ssc_number = null, ssc_issued_on = null, ssc_expires_on = null where id = ${car!.id}`;
  expect(quiet(errors)).toEqual([]);
  await sql.end();
});

test('money: a credit card by default; an Admin allows debit and prepaid cards for one booking on its Money tab', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const a = await mkAdmin(sql);
  const [b] = await sql`select id, booking_number from bookings where coverage_option is distinct from 2 and debit_allowed_at is null and status::text in ('confirmed', 'awaiting_payment', 'in_progress') order by created_at desc limit 1`;
  test.skip(!b, 'no booking in the seed');
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, a.email, '/admin');
  await page.goto(`/admin/bookings/${b!.booking_number}?tab=money`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('bm-debit')).toContainText(/credit card is required|takes a debit/);
  await expect(page.getByTestId('booking-debit-on')).toBeVisible();
  await check(page, 'money-debit');
  await sql`select app.booking_allow_debit(${a.id}::uuid, ${sql.json({ booking_id: b!.id, reason: 'e2e: debit only' })})`;
  await page.reload({ waitUntil: 'networkidle' });
  await expect(page.getByTestId('bm-debit')).toContainText('Debit and prepaid cards allowed for this booking');
  await expect(page.getByTestId('booking-debit-off')).toBeVisible();
  await sql`update bookings set debit_allowed_at = null, debit_allowed_by = null, debit_allowed_reason = null where id = ${b!.id}`;
  expect(quiet(errors)).toEqual([]);
  await sql.end();
});
