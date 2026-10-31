import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Release 21b end to end, at both widths: the "i" (InfoTip: opens on a click or a tap, Escape closes it and gives the focus
// back), the address lookup of the referral partner sign-up, and the academy (a lesson played with captions only, a quiz
// failed then passed, the next section opened; Admin's progress, Open early and the editor).
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text.match(/[–—]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(text, `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function mkUser(sql: Sql, role: 'admin' | 'va', va?: string) {
  const id = randomUUID(); const email = `r21b.${role}.${Date.now()}.${tag()}@example.test`; const name = role === 'admin' ? 'Ada Admin' : `Casey Trainee ${tag()}`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${va!}, 50000)`;
  return { id, email, name };
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
const quiet = (errors: string[]) => errors.filter((x) => !/favicon|Failed to load resource|net::ERR/.test(x));

test('the academy: a lesson with captions, a quiz failed then passed, the next section; Admin progress, Open early, the editor; the "i"', async ({ browser }, info) => {
  test.setTimeout(300_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const cs = await mkUser(sql, 'va', 'cs');
  const answers = await sql`select q.sort, q.answer, jsonb_array_length(q.options) n from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'prices-and-deposits' order by q.sort`;

  // ---- the staff member
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, cs.email, '/staff');
  await page.goto('/staff/academy', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('path-cs')).toBeVisible();
  await expect(page.getByTestId('section-coverage-and-drivers')).toContainText('Pass the one before');
  await check(page, 'academy home');
  await page.getByTestId('section-prices-and-deposits').getByRole('link').click();
  await page.waitForURL(/\/staff\/academy\/cs\/prices-and-deposits$/);
  // a lesson: play (captions only in the test browser), step through every scene, watched
  const player = page.getByTestId('player-0');
  await player.getByTestId('player-0-play').click();
  await expect(player.getByTestId('player-0-caption')).not.toContainText('Press Play');
  await expect(player.getByTestId('player-0-scene')).toContainText('Scene 1 of');
  await player.getByTestId('player-0-speed').selectOption('1.5');
  await expect(player.getByTestId('player-0-play')).toHaveText('Pause');
  await player.getByTestId('player-0-play').click(); // pause
  await expect(player.getByTestId('player-0-play')).toHaveText('Resume');
  const n = Number((await player.getByTestId('player-0-scene').innerText()).match(/of (\d+)/)![1]);
  for (let i = 0; i < n; i++) await player.getByTestId('player-0-next').click();
  await expect(page.getByTestId('lesson-0')).toContainText('Watched');
  await expect(player.getByTestId('player-0-progress')).toHaveAttribute('aria-valuenow', '100');
  await check(page, 'section');
  // the quiz: all wrong, then right
  for (const a of answers) await page.getByTestId(`q-${Number(a.sort) - 1}-${(Number(a.answer) + 1) % Number(a.n)}`).check();
  await page.getByTestId('quiz-submit').click();
  await expect(page.getByTestId('quiz-result')).toContainText('Not passed yet');
  await page.getByTestId('quiz-retry').click();
  for (const a of answers) await page.getByTestId(`q-${Number(a.sort) - 1}-${a.answer}`).check();
  await page.getByTestId('quiz-submit').click();
  await expect(page.getByTestId('quiz-result')).toContainText('Passed');
  await page.getByTestId('quiz-next').click();
  await page.waitForURL(/\/staff\/academy\/cs\/coverage-and-drivers$/);
  await expect(page.getByTestId('quiz')).toBeVisible();
  expect(quiet(errors)).toEqual([]);

  // ---- Admin: progress, Open early, the editor, and the "i"
  const ap = await ctx(browser, phone);
  const aerr = watch(ap);
  await signIn(ap, admin.email, '/admin');
  await ap.goto('/admin/academy', { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('academy-staff').locator('tr', { hasText: cs.name })).toContainText('1 of 6');
  // the "i": a button with its name; a click or a tap opens it, Escape closes it and gives the focus back
  const tip = ap.getByRole('button', { name: 'About the academy gate' });
  await (phone ? tip.tap() : tip.click());
  await expect(ap.getByRole('tooltip')).toContainText('Off (the default)');
  await check(ap, 'admin academy');
  await ap.keyboard.press('Escape');
  await expect(ap.getByRole('tooltip')).toHaveCount(0);
  await expect(tip).toBeFocused();
  await ap.goto(`/admin/academy/staff/${cs.id}`, { waitUntil: 'networkidle' });
  await ap.getByTestId('unlock-cs-requests').click();
  await ap.getByRole('dialog').getByLabel('Reason').fill('Two years of rental desk work');
  await ap.getByTestId('unlock-cs-requests-submit').click();
  await expect(ap.getByTestId('ap-cs')).toContainText('Opened early');
  await check(ap, 'admin academy person');
  const [sec] = await sql`select id from academy_sections where slug = 'commission'`;
  await ap.goto(`/admin/academy/sections/${sec!.id}`, { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('qe-1')).toContainText('(right answer)');
  await check(ap, 'academy editor');
  expect(quiet(aerr)).toEqual([]);

  // the early opening reaches the staff member
  await page.goto('/staff/academy', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('section-cs-requests')).toContainText('Opened by an Admin');
  await page.context().close(); await ap.context().close();
  await sql.end();
});

test('the referral partner sign-up: the address lookup fills the street, the city and the postal code', async ({ browser }, info) => {
  const phone = info.project.name.startsWith('phone');
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await page.goto('/partners/body-shops', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  const look = page.getByTestId('ps-lookup');
  await look.scrollIntoViewIfNeeded();
  await look.pressSequentially('100 Queen', { delay: 40 });
  const opt = page.getByRole('option').first();
  await expect(opt).toBeVisible({ timeout: 15_000 });
  await opt.click();
  await expect(page.getByTestId('ps-address_line1')).not.toHaveValue('', { timeout: 15_000 });
  await expect(page.getByTestId('ps-city')).not.toHaveValue('');
  await check(page, 'partner sign-up');
  expect(quiet(errors)).toEqual([]);
  await page.context().close();
});

test('Add an investor: the record and the invitation in one step; the investor chooses a password and the sign-in is linked to the record', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const email = `iris.${Date.now()}.${tag()}@example.test`;
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, admin.email, '/admin');
  await page.goto('/admin/investors', { waitUntil: 'networkidle' });
  await page.getByTestId('add-investor').click();
  const f = page.getByTestId('add-investor-form');
  await f.getByTestId('ai-name').fill('Iris Investor');
  await f.getByTestId('ai-type').selectOption('corporation');
  await f.getByTestId('ai-sign').fill('Iris Officer');
  await f.getByTestId('ai-email').fill(email);
  await f.getByTestId('ai-phone').fill('416-555-0100');
  await f.getByTestId('ai-address').pressSequentially('100 Queen', { delay: 40 });
  await page.getByRole('listbox', { name: 'Address suggestions' }).getByRole('option').first().click();
  await expect(f.getByTestId('ai-roi')).toHaveValue('30');
  await f.getByTestId('info-ai-roi').click();
  await expect(page.getByRole('tooltip')).toContainText('investment agreement sets');
  await check(page, 'add an investor');
  await page.keyboard.press('Escape');
  await f.getByTestId('ai-committed').fill('50,000');
  await expect(f.getByTestId('ai-invite')).toBeChecked();
  await f.getByTestId('ai-submit').click();
  await expect(f.getByTestId('ai-msg')).toContainText(`Added and invited: the invitation went to ${email}`);
  const [rec] = await sql`select investor_type, signatory_name, committed_amount_cents::int c, offered_yearly_bps b, user_id from investors where email = ${email}`;
  expect(rec).toMatchObject({ investor_type: 'corporation', signatory_name: 'Iris Officer', c: 5_000_000, b: 3000 });
  expect(rec!.user_id).not.toBeNull();
  expect(quiet(errors)).toEqual([]);
  await page.context().close();
  // the invitation: choose a password, land in the investor portal
  const m = await sql`select link from local_auth.mailbox where to_email = ${email} order by id desc limit 1`;
  expect(m[0]?.link).toContain('/update-password?token=');
  const p = await ctx(browser, phone);
  const u = new URL(m[0]!.link as string);
  await p.goto(u.pathname + u.search);
  await p.locator('#np-pass').fill('a brand new password');
  await p.getByRole('button', { name: 'Save the new password' }).click();
  // signed in; a prospect has no investor portal until the agreement makes them active (my_roles: active or exited)
  await p.waitForURL((x) => !x.pathname.startsWith('/update-password'), { timeout: 30_000 });
  await expect(p.locator('h1').first()).toBeVisible();
  const [linked] = await sql`select i.status, u.email from investors i join users u on u.id = i.user_id where i.email = ${email}`;
  expect(linked).toMatchObject({ status: 'prospect', email });
  await p.context().close();
  await sql.end();
});

// 0211: no invitation without an open call time (production, October 30, 2026)
const FIELD_PASS = {
  licence: 'Yes, a full G', years: '5 years or more', record: 'None', days: ['Monday', 'Friday', 'Saturday', 'Sunday'], hours: 'Full time (35 or more)', transport: 'My own car',
  experience: ['Delivery driver'], late: 'Message the office at once, keep the renter updated and follow the office\'s instructions',
  dent: 'Stay polite, photograph everything, note it in the app and let the office decide', cash: 'Count it in front of them, record it in the app right away and give them the receipt',
  start: '2026-11-02', pay: '20'
};
test('hiring: a pass with no open interview day waits; the link says so; Admin is warned; a day added sends the invitation', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  // no open day for Field staff during the test (put back at the end)
  const open = (await sql`select id from interview_days where active and (role_ids is null or (select id from hiring_roles where slug = 'field-staff') = any (role_ids))`).map((r) => r.id as string);
  if (open.length) await sql`update interview_days set active = false where id = any (${open}::uuid[])`;
  try {
    const email = `hwd.${Date.now()}.${tag()}@example.test`;
    const [r] = await sql`select public.server_hiring_apply(jsonb_build_object('role', 'field-staff', 'full_name', 'Wendy Waiting', 'email', ${email}::text, 'phone', '4165550144',
      'answers', ${sql.json(FIELD_PASS as never)}::jsonb), null) as r`;
    const token = (r!.r as { token: string }).token;
    await sql`select app.process_events()`;
    expect((await sql`select waiting_for_day from job_applications where email = ${email}`)[0]!.waiting_for_day).toBe(true);
    expect((await sql`select count(*)::int n from notification_outbox where code = 'applicant_invited' and to_address = ${email}`)[0]!.n).toBe(0);

    const c = await ctx(browser, phone);
    await c.goto(`/careers/book/${token}`, { waitUntil: 'networkidle' });
    await acceptCookies(c);
    await expect(c.getByTestId('book-none')).toContainText('No call times are open right now. We\'ll email you as soon as new times open.');
    await check(c, 'booking with no time');
    expect((await sql`select no_slots_seen_at is not null v from job_applications where email = ${email}`)[0]!.v).toBe(true);

    const ap = await ctx(browser, phone);
    const errors = watch(ap);
    await signIn(ap, admin.email, '/admin');
    await ap.goto('/admin/hiring', { waitUntil: 'networkidle' });
    const warn = ap.getByTestId('hiring-no-day-field-staff');
    await expect(warn).toContainText('invited but no interview day is open for');
    await check(ap, 'hiring warning');
    await warn.getByRole('link', { name: 'Add an interview day' }).click();
    await ap.waitForURL(/tab=days/);
    await ap.getByTestId('day-add').click();
    const dlg = ap.getByRole('dialog');
    const day = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto' }).format(new Date(Date.now() + 5 * 86_400_000));
    await dlg.getByLabel('Day', { exact: true }).fill(day);
    await dlg.getByLabel(/^Roles/).fill('field-staff');
    await ap.getByTestId('day-add-submit').click();
    await expect(ap.getByTestId('hiring-no-day-field-staff')).toHaveCount(0, { timeout: 15_000 });
    await sql`select app.process_events()`;
    expect((await sql`select status from notification_outbox where code = 'applicant_invited' and to_address = ${email} order by created_at desc limit 1`)[0]?.status).toBe('queued');
    expect(quiet(errors)).toEqual([]);
    await c.reload({ waitUntil: 'networkidle' });
    await expect(c.getByTestId('book-none')).toHaveCount(0);
    await c.context().close(); await ap.context().close();
  } finally {
    if (open.length) await sql`update interview_days set active = true where id = any (${open}::uuid[])`;
    await sql.end();
  }
});

// 2026-10-30: a device with "After tax" saved sent every fee and the coverage of a reviewed request about 11.5% low
test('After tax saved on this device: a request\'s review changes nothing, and the offer keeps every fee and the coverage', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  const ahead = 400 + Math.floor(Math.random() * 200);
  const from = ymd(new Date(Date.now() + ahead * 86_400_000)); const to = ymd(new Date(Date.now() + (ahead + 3) * 86_400_000));
  const [car] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable)
      and app.vehicle_is_available(v.id, ${`${from}T10:00:00-04:00`}::timestamptz - interval '1 day', ${`${to}T10:00:00-04:00`}::timestamptz + interval '1 day', null)
    order by random() limit 1`;
  expect(car, 'a free car').toBeTruthy();
  const req = {
    request_key: randomUUID(), vehicle_id: car!.id, pickup_at: `${from}T10:00:00-04:00`, return_at: `${to}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' }, coverage_option: 3, extras: {},
    renter: { email: `tax.${tag()}@example.test`, full_name: 'Tess Taxmode', mobile: '+16475550123', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req as never)}, '203.0.113.9', 'e2e', null) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  const lines = () => sql`select charge_type, amount_cents, hst_cents from booking_line_items where booking_id = ${v.booking_id} and stage = 'booking' and voided_at is null order by charge_type, amount_cents`;
  const linesBefore = await lines();
  const [stored] = await sql`select total_due_at_booking_cents t from bookings where id = ${v.booking_id}`;

  const page = await ctx(browser, phone);
  await page.context().addInitScript(() => { try { localStorage.setItem('cc-amounts-typed', 'after'); } catch { /* none */ } });
  const errors = watch(page);
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/bookings/${v.booking_number}`, { waitUntil: 'networkidle' });
  const review = page.getByTestId('booking-review');
  await expect(review).toBeVisible();
  await expect(page.getByTestId('rv-tax-mode')).toHaveAttribute('data-mode', 'after');
  // the boxes now show the amounts with HST, and nothing counts as changed
  await expect(review.locator('.ad-diff')).toHaveCount(0);
  await expect(page.getByTestId('review-send')).toHaveText('Send the offer');
  const total = Number((await page.getByTestId('review-total').innerText()).replace(/[^\d.]/g, '').match(/^\d+(\.\d{1,2})?/)![0]);
  expect(Math.round(total * 100)).toBe(Number(stored!.t));
  await check(page, 'review after tax');
  if (await page.getByTestId('choice-for_carmacars').count()) await page.getByTestId('choice-for_carmacars').check();
  await page.getByTestId('review-send').click();
  await expect(page.getByRole('status').filter({ hasText: 'Offer sent' })).toBeVisible({ timeout: 15_000 });
  expect((await sql`select status::text s from bookings where id = ${v.booking_id}`)[0]!.s).toBe('offered');
  expect(await lines()).toEqual(linesBefore);
  expect(quiet(errors)).toEqual([]);
  await page.context().close();
  await sql.end();
});

// 0212: the email limit reached: Text it instead, and sign-in opens on the phone option
test('email limit: an Admin texts a held email instead; sign-in opens on the phone while email is held', async ({ browser }, info) => {
  test.setTimeout(120_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const k = tag();
  const [rn] = await sql`insert into renters (legal_name, email, mobile) values ('Lima Limit', ${`lim.${k}@example.test`}, '416-555-0190') returning id`;
  const [o] = await sql`insert into notification_outbox (code, category, priority, audience, to_address, renter_id, payload, dedupe_key, status, status_reason, send_after)
    values ('renter_payment_receipt', 'transactional', 1, 'renter', ${`lim.${k}@example.test`}, ${rn!.id}, ${sql.json({ booking_number: `CC-L${k}` } as never)}, ${`e2e-limit:${k}`}, 'delayed', 'daily email limit', now() + interval '6 hours')
    returning id`;
  try {
    const page = await ctx(browser, phone);
    const errors = watch(page);
    await signIn(page, admin.email, '/admin');
    await page.goto(`/admin/messages?status=delayed&q=${encodeURIComponent(`lim.${k}`)}`, { waitUntil: 'networkidle' });
    await page.getByTestId(`outbox-text-${o!.id}`).click();
    await page.getByTestId(`outbox-text-${o!.id}-submit`).click();
    await expect(page.getByTestId(`outbox-texted-${o!.id}`)).toBeVisible({ timeout: 15_000 });
    const [p] = await sql`select p.to_number, p.status, n.status n from notification_outbox n join phone_outbox p on p.id = n.limit_text_id where n.id = ${o!.id}`;
    expect(p).toMatchObject({ to_number: '+14165550190', n: 'delayed' });
    expect(['queued', 'sending', 'sent']).toContain(p!.status);
    await check(page, 'email text it instead');
    expect(quiet(errors)).toEqual([]);
    await page.context().close();

    // sign-in while email is held (the answer of /api/email-status, so the other tests' sign-ins are not touched)
    const s = await ctx(browser, phone);
    await s.route('**/api/email-status', (r) => r.fulfill({ contentType: 'application/json', body: JSON.stringify({ capped: true, phone_signin: true }) }));
    await s.goto('/sign-in', { waitUntil: 'networkidle' });
    await acceptCookies(s);
    await expect(s.getByTestId('signin-email-held')).toContainText('sign in with the code we text you');
    await expect(s.locator('input[type="tel"]').first()).toBeVisible();
    await check(s, 'sign-in email held');
    await s.context().close();
    const n = await ctx(browser, phone);
    await n.route('**/api/email-status', (r) => r.fulfill({ contentType: 'application/json', body: JSON.stringify({ capped: false, phone_signin: true }) }));
    await n.goto('/sign-in', { waitUntil: 'networkidle' });
    await expect(n.locator('input[type="email"]')).toBeVisible();
    await expect(n.getByTestId('signin-email-held')).toHaveCount(0);
    await n.context().close();
    const live = await (await fetch(`${test.info().project.use.baseURL ?? 'http://localhost:3000'}/api/email-status`)).json() as { capped: boolean; phone_signin: boolean };
    expect(typeof live.capped).toBe('boolean');
  } finally {
    await sql`delete from phone_outbox where notification_id = ${o!.id}`;
    await sql`delete from notification_outbox where id = ${o!.id}`;
    await sql.end();
  }
});

// 0213: the deposit hold link texted before pickup by the deposit job, on the Money tab, texted and opened
test('deposit link by text: the job texts the hold link before pickup; the Money tab says texted, then opened; a prepaid card is refused', async ({ browser }, info) => {
  test.setTimeout(150_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  const from = ymd(new Date(Date.now() + 2 * 86_400_000)); const to = ymd(new Date(Date.now() + 5 * 86_400_000));
  const [car] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable)
      and app.vehicle_is_available(v.id, ${`${from}T10:00:00-04:00`}::timestamptz - interval '1 day', ${`${to}T10:00:00-04:00`}::timestamptz + interval '1 day', null)
    order by random() limit 1`;
  test.skip(!car, 'no free car in two days');
  const req = {
    request_key: randomUUID(), vehicle_id: car!.id, pickup_at: `${from}T10:00:00-04:00`, return_at: `${to}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' }, coverage_option: 3, extras: {},
    renter: { email: `dep.${tag()}@example.test`, full_name: 'Dana Deposit', mobile: '+16475550124', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req as never)}, '203.0.113.9', 'e2e', null) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  // confirmed as an approved and paid offer would leave it (the status path itself is tested elsewhere)
  await sql.begin(async (t) => {
    await t`set local session_replication_role = replica`;
    await t`update bookings set status = 'confirmed', deposit_pay_method = 'card', deposit_cents = greatest(deposit_cents, 25000) where id = ${v.booking_id}`;
  });
  const [hrs] = await sql`select deposit_link_hours h from site_settings where singleton`;
  await sql`update site_settings set deposit_link_hours = 72 where singleton`;
  try {
    const env = readFileSync(path.join(process.cwd(), '.env.local'), 'utf8');
    const token = createHmac('sha256', /^LINK_SIGNING_KEY=(.*)$/m.exec(env)![1]!.trim()).update('carmacars-listing-worker-v1').digest('hex');
    const page = await ctx(browser, phone);
    const res = await page.request.post('/api/jobs/deposits', { headers: { authorization: `Bearer ${token}` } });
    expect(res.ok()).toBe(true);
    const [q] = await sql`select q.texted_at, q.auto, p.body, p.to_number from payment_requests q join phone_outbox p on p.id = q.text_id
      where q.booking_id = ${v.booking_id} and q.kind = 'hold' and q.status = 'open'`;
    expect(q).toMatchObject({ auto: true, to_number: '+16475550124' });
    expect(q!.texted_at).toBeTruthy();
    expect(String(q!.body)).toContain(`booking ${v.booking_number}`);
    const link = /https?:\/\/\S+\/pay\/[A-Za-z0-9_-]{20,}/.exec(String(q!.body))![0];
    // a second run sends nothing more
    await page.request.post('/api/jobs/deposits', { headers: { authorization: `Bearer ${token}` } });
    expect((await sql`select count(*)::int n from payment_requests where booking_id = ${v.booking_id} and kind = 'hold'`)[0]!.n).toBe(1);

    const errors = watch(page);
    await signIn(page, admin.email, '/admin');
    await page.goto(`/admin/bookings/${v.booking_number}?tab=money`, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('bm-deposit-link')).toContainText('Deposit link texted');
    await expect(page.getByTestId('bm-deposit-link')).toContainText('not opened yet');
    await check(page, 'money deposit link');
    const renter = await ctx(browser, phone);
    await renter.goto(new URL(link).pathname, { waitUntil: 'networkidle' });
    await renter.context().close();
    await page.reload({ waitUntil: 'networkidle' });
    await expect(page.getByTestId('bm-deposit-link')).toContainText('opened');
    await expect(page.getByTestId('bm-deposit-link')).not.toContainText('not opened');
    // the staff link takes the same cards as the booking's pay page: a prepaid card is refused, nothing held; a credit card places the hold
    const rp = await ctx(browser, phone);
    await rp.goto(new URL(link).pathname, { waitUntil: 'networkidle' });
    const pay = async (number: string) => {
      await rp.locator('#pl-name').fill('Dana Deposit');
      await rp.locator('#pl-num').fill(number);
      await rp.locator('#pl-exp').fill('12 / 30');
      await rp.locator('#pl-cvc').fill('123');
      await rp.getByTestId('paylink-submit').click();
    };
    await pay('5105105105105100');
    await expect(rp.getByTestId('paylink-message')).toContainText('Please use a credit card. Debit and prepaid cards cannot be used for a rental.');
    expect((await sql`select count(*)::int n from deposits where booking_id = ${v.booking_id} and status = 'held'`)[0]!.n).toBe(0);
    expect((await sql`select status, last_error from payment_requests where booking_id = ${v.booking_id} and kind = 'hold' order by created_at desc limit 1`)[0]).toMatchObject({ status: 'open' });
    await check(rp, 'pay link prepaid refused');
    await expect(rp.getByTestId('paylink-submit')).toBeEnabled({ timeout: 15_000 });
    await pay('4242424242424242');
    await expect(rp.getByTestId('paylink-done')).toBeVisible({ timeout: 20_000 });
    expect((await sql`select count(*)::int n from deposits where booking_id = ${v.booking_id} and status = 'held'`)[0]!.n).toBe(1);
    await rp.context().close();
    expect(quiet(errors)).toEqual([]);
    await page.context().close();
  } finally {
    await sql`update site_settings set deposit_link_hours = ${Number(hrs!.h)} where singleton`;
    await sql`update payment_requests set status = 'cancelled' where booking_id = ${v.booking_id} and status = 'open'`;
    await sql.end();
  }
});
