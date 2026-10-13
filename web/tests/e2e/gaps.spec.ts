import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// The gaps of 0031 and 0032 closed (migration 0033), end to end at 375 and 1440: renter and customer service
// messages both ways with the email, Finance's reconciliation and Turo trips, the Fleet daily check, the photo
// review with a re-shoot done on a phone, the late-return panel, find a renter, a Sales quote, the function
// switcher, the scorecard, the field checklists, report, referrals, profile and web app manifest, and an
// investor's yearly download. Every page is checked with axe, for overflow and with the copy rules.
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/18122211|Canada Inc\b/i, 'numbered company name'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
const STORE = process.env.LOCAL_STORAGE_DIR ?? path.join(process.cwd(), '.local-storage');

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const vp = (phone: boolean) => (phone ? { width: 375, height: 812 } : { width: 1440, height: 900 });
const clean = (e: string[]) => e.filter((x) => !/favicon|Failed to load resource|net::ERR/.test(x));

async function mkUser(sql: Sql, tag: string, role: 'admin' | 'va' | 'field' | 'renter', extra: { va?: string; cover?: string[] } = {}) {
  const id = randomUUID(); const email = `${role}.${tag}.${Date.now()}.${Math.floor(Math.random() * 1e4)}@example.test`;
  const name = { admin: 'Ada Admin', va: 'Val Assistant', field: 'Finn Field', renter: 'Riley Renter' }[role];
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, ${name}, null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, staff_type, va_function, cover_functions) values (${id}, 'va', ${extra.va!}, ${extra.cover ?? []}::va_function[])`;
  if (role === 'field') await sql`insert into staff_profiles (user_id, staff_type, field_function) values (${id}, 'field', 'driver')`;
  return { id, email };
}
async function freeCar(sql: Sql, start: number, days: number) {
  const from = new Date(Date.now() + start * 86_400_000); const to = new Date(from.getTime() + days * 86_400_000);
  const rows = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id)
      and not exists (select 1 from bookings b where b.vehicle_id = v.id and b.status in ('requested','offered','pending_payment','confirmed','on_rent','returned','closed')
                        and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${from.toISOString()}::timestamptz, ${to.toISOString()}::timestamptz))
      and not exists (select 1 from vehicle_calendar_blocks k where k.vehicle_id = v.id and k.removed_at is null and k.starts_at < ${to.toISOString()}::timestamptz and (k.ends_at is null or k.ends_at > ${from.toISOString()}::timestamptz))
      and not exists (select 1 from field_jobs j where j.vehicle_id = v.id and j.status not in ('cancelled', 'done') and j.scheduled_at between ${from.toISOString()}::timestamptz - interval '3 days' and ${to.toISOString()}::timestamptz)
    order by random() limit 1`;
  if (!rows[0]) throw new Error('no free car');
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  return { id: rows[0].id as string, from: ymd(from), to: ymd(to) };
}
async function seedRequest(sql: Sql, renter: { id: string; email: string }, vehicle: string, from: string, to: string) {
  const req = {
    request_key: randomUUID(), vehicle_id: vehicle, pickup_at: `${from}T10:00:00-04:00`, return_at: `${to}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' },
    coverage_option: 2, extras: { winter_tire: false, baby_seats: 0 },
    renter: { email: renter.email, full_name: 'Riley Renter', mobile: '+16475550123', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${renter.id}) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  return v;
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: vp(phone), hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
/** Fills and submits the dialog of an Act button. */
async function act(page: Page, testId: string, fill: (d: ReturnType<Page['locator']>) => Promise<void> = async () => {}) {
  await page.getByTestId(testId).click();
  const dlg = page.locator('dialog[open]');
  await fill(dlg);
  await dlg.getByTestId(`${testId}-submit`).click();
}

test('gaps: customer service and the renter write to each other on the booking, with the email', async ({ browser }, info) => {
  test.setTimeout(150_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const cs = await mkUser(sql, 'msg', 'va', { va: 'cs' });
  const renter = await mkUser(sql, 'rmsg', 'renter');
  const car = await freeCar(sql, 120 + (phone ? 0 : 10), 3);
  const req = await seedRequest(sql, renter, car.id, car.from, car.to);
  const va = await ctx(browser, phone);
  const errors = watch(va);
  await signIn(va, cs.email, '/va');
  await va.goto(`/va/bookings/${req.booking_number}?tab=messages`);
  await va.locator('#qr-body').fill('Hello Riley, we can have the car ready at 9:00. Does that work?');
  await va.getByTestId('quick-reply-send').click();
  await expect(va.getByTestId('messages')).toContainText('ready at 9:00', { timeout: 15_000 });
  await check(va, 'va booking messages');
  await expect.poll(async () => { await sql`select app.process_events(1000)`; return (await sql`select count(*)::int n from notification_outbox where code = 'renter_staff_message' and booking_id = ${req.booking_id} and payload ->> 'message_body' like '%ready at 9:00%'`)[0]!.n; }, { timeout: 15_000 }).toBe(1);
  const rp = await ctx(browser, phone);
  await signIn(rp, renter.email, '/account');
  await rp.goto(`/account/bookings/${req.booking_number}#messages`);
  await expect(rp.getByTestId('booking-messages')).toContainText('ready at 9:00');
  await rp.locator('#pt-msg-body').fill('Yes, 9:00 works, thank you.');
  await rp.getByTestId('booking-message-send').click();
  await expect(rp.getByTestId('booking-messages')).toContainText('9:00 works', { timeout: 15_000 });
  await check(rp, 'renter booking messages');
  const [t] = await sql`select queue, status from tasks where task_type = 'renter_message' and booking_id = ${req.booking_id}`;
  expect(t).toMatchObject({ queue: 'cs', status: 'open' });
  await va.goto('/va');
  await expect(va.locator('body')).toContainText(`Booking ${req.booking_number}: the renter replied`);
  expect(clean(errors)).toEqual([]);
  await sql.end();
});

test('gaps: Finance records Turo trips and a processor payout; the scorecard', async ({ browser }, info) => {
  test.setTimeout(150_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const fin = await mkUser(sql, 'turo', 'va', { va: 'finance' });
  const [car] = await sql`select v.id, v.plate from vehicles v where v.plate is not null and (app.vehicle_terms(v.id, current_date)).revenue_share_bps is not null order by v.created_at limit 1`;
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, fin.email, '/va');
  await page.goto('/va/turo'); await check(page, 'va turo');
  const ref = `E2E-${Date.now()}-${phone ? 'p' : 'd'}`;
  await act(page, 'turo-add', async (d) => {
    await d.getByLabel('Car', { exact: true }).selectOption(car!.id as string);
    await d.getByLabel('Trip reference').fill(ref);
    await d.getByLabel('Start').fill('2026-09-02T14:00'); await d.getByLabel('End').fill('2026-09-05T14:00');
    await d.getByLabel('Gross (trip price and distance fees) ($)').fill('400'); await d.getByLabel('Turo fees ($)').fill('100');
  });
  await expect(page.getByTestId('turo-trips')).toContainText(ref, { timeout: 15_000 });
  await page.locator('#turo-csv').fill(`trip_ref,plate,start,end,gross,turo_fees,extras,damage\n${ref}-2,${car!.plate as string},2026-09-10 10:00,2026-09-12 10:00,200,50,0,0\n${ref}-3,NOPLATE,2026-09-10 10:00,2026-09-12 10:00,200,50,0,0`);
  await page.getByRole('button', { name: 'Import' }).click();
  await expect(page.getByTestId('turo-import')).toContainText('1 saved. Not saved: row 2', { timeout: 15_000 });
  await expect(page.getByTestId('turo-trips')).toContainText(`${ref}-2`);
  await check(page, 'va turo after');
  await page.goto('/va/reconciliation'); await check(page, 'va reconciliation');
  await act(page, 'reconcile-record', async (d) => { await d.getByLabel('Payout reference').fill(`po_${ref}`); await d.getByLabel('Paid on').fill('2026-10-01'); await d.getByLabel('Amount ($)').fill('123.45'); });
  await expect(page.locator('body')).toContainText(`po_${ref}`, { timeout: 15_000 });
  await page.goto('/va/scorecard'); await expect(page.getByTestId('scorecard')).toContainText('Refunds paid'); await check(page, 'va scorecard');
  expect(clean(errors)).toEqual([]);
  await sql.end();
});

test('gaps: Fleet daily check, photo review with a re-shoot done on a phone, and the late-return panel', async ({ browser }, info) => {
  test.setTimeout(240_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const fleet = await mkUser(sql, 'rev', 'va', { va: 'fleet' });
  const field = await mkUser(sql, 'rev', 'field');
  const renter = await mkUser(sql, 'rrev', 'renter');
  const late = await mkUser(sql, 'rlate', 'renter');
  // a returned booking with both photo sets (two shots missing from the return), and one out past its time
  // cars with nothing booked in the days the bookings are moved back to; the requests are made far ahead first
  const car = await freeCar(sql, -7, 7);
  const ahead = await freeCar(sql, 250 + (phone ? 0 : 10), 3);
  const req = await seedRequest(sql, renter, car.id, ahead.from, ahead.to);
  let car2 = await freeCar(sql, -4, 5);
  for (let i = 0; i < 5 && car2.id === car.id; i++) car2 = await freeCar(sql, -4, 5);
  const lreq = await seedRequest(sql, late, car2.id, ahead.from, ahead.to);
  await sql`set session_replication_role = replica`;
  // the same length of rental, moved into the past (the billable days worked out again for the new dates)
  await sql`update bookings b set status = 'returned', return_at = x.r, pickup_at = x.p, handed_over_at = x.p, checked_in_at = x.r,
              billable_days = public.calc_billable_days(x.p, x.r), km_allowance_total = b.km_allowance_per_day * public.calc_billable_days(x.p, x.r)
              from (select id, now() - interval '1 day' r, now() - interval '1 day' - (return_at - pickup_at) p from bookings where id = ${req.booking_id}) x where b.id = x.id`;
  await sql`update bookings b set status = 'on_rent', return_at = x.r, pickup_at = x.p, handed_over_at = x.p,
              billable_days = public.calc_billable_days(x.p, x.r), km_allowance_total = b.km_allowance_per_day * public.calc_billable_days(x.p, x.r)
              from (select id, now() - interval '50 minutes' r, now() - interval '50 minutes' - (return_at - pickup_at) p from bookings where id = ${lreq.booking_id}) x where b.id = x.id`;
  const rp = randomUUID(); const rr = randomUUID();
  await sql`insert into condition_reports (id, vehicle_id, booking_id, kind, performed_by, performed_by_role, completed_at, odometer_km, fuel_pct, keys_count)
            values (${rp}, ${car.id}, ${req.booking_id}, 'pickup', ${field.id}, 'field', now() - interval '5 days', 10000, 100, 2), (${rr}, ${car.id}, ${req.booking_id}, 'return', ${field.id}, 'field', now() - interval '1 day', 10700, 90, 2)`;
  const shots = await sql`select seq, shot from app.required_shots_for('pickup', (select class from vehicles where id = ${car.id}))`;
  for (const [r, k] of [[rp, 'pickup'], [rr, 'return']] as const) {
    for (const s of shots) {
      if (k === 'return' && ['roof', 'instrument_cluster'].includes(s.shot as string)) continue;
      const key = `bookings/${req.booking_id}/${k}/${s.seq}-${s.shot}.png`;
      mkdirSync(path.dirname(path.join(STORE, 'condition-photos', key)), { recursive: true });
      writeFileSync(path.join(STORE, 'condition-photos', key), PNG);
      await sql`insert into condition_report_photos (condition_report_id, seq, shot, storage_path) values (${r}, ${s.seq as number}, ${s.shot as string}, ${key})`;
    }
  }
  await sql`set session_replication_role = origin`;
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, fleet.email, '/va');
  // the opening check: everything the system knows is pre-answered
  await page.goto('/va/checks'); await check(page, 'va checks');
  for (const n of [1, 2, 3, 4, 5]) {
    const line = page.locator('fieldset.ad-check__line').nth(n - 1);
    await line.getByLabel('OK', { exact: true }).check();
  }
  await page.getByTestId('check-save-opening').click();
  await expect(page.getByTestId('check-opening')).toContainText('Saved', { timeout: 15_000 });
  // the photo review side by side, and the re-shoot
  await page.goto(`/va/review/${req.booking_number}`);
  await expect(page.getByTestId('missing-return')).toContainText('roof, instrument cluster');
  await expect(page.getByTestId('photo-review').locator('img').first()).toBeVisible();
  await check(page, 'va photo review');
  await page.getByTestId('reshoot-send').click();
  await expect(page.getByTestId('reshoot')).toContainText('Re-shoot asked for', { timeout: 15_000 });
  const [job] = await sql`select id, assigned_to from field_jobs where reshoot_report_id = ${rr}`;
  expect(job!.assigned_to).toBe(field.id);
  // the late-return panel
  await page.goto(`/va/bookings/${lreq.booking_number}`);
  await expect(page.getByTestId('late-panel')).toContainText('Late return');
  await check(page, 'va late panel');
  await act(page, 'late-call', async (d) => { await d.getByLabel('What happened').fill('No answer; left a voicemail'); });
  await expect(page.getByTestId('late-panel')).toContainText('left a voicemail', { timeout: 15_000 });
  await page.getByTestId('late-t13').click();
  await expect.poll(async () => (await sql`select count(*)::int n from app_events where code = 'renter_late_return_first' and entity_id = ${lreq.booking_id}`)[0]!.n, { timeout: 15_000 }).toBe(1);
  expect(clean(errors)).toEqual([]);
  // the field staff member takes the two shots again on a phone
  const fp = await ctx(browser, true);
  const ferr = watch(fp);
  await signIn(fp, field.email, '/field');
  await fp.goto(`/field/jobs/${job!.id}`);
  await fp.getByTestId('acknowledge').click(); await fp.getByTestId('start').click({ timeout: 15_000 });
  await expect(fp.getByTestId('job-checklist')).toBeVisible({ timeout: 15_000 });
  await check(fp, 'field reshoot');
  for (const s of ['roof', 'instrument_cluster']) {
    await fp.getByTestId(`ck-reshoot-${s}`).setInputFiles({ name: `${s}.png`, mimeType: 'image/png', buffer: PNG });
    await expect(fp.getByTestId('job-checklist')).toContainText(`✓ ${s.replace('_', ' ')}`, { timeout: 30_000 });
  }
  await fp.getByTestId('job-complete').click();
  await expect(fp.getByTestId('job-done')).toBeVisible({ timeout: 30_000 });
  expect((await sql`select count(*)::int n from condition_report_photos where condition_report_id = ${rr} and shot in ('roof', 'instrument_cluster')`)[0]!.n).toBe(2);
  expect(clean(ferr)).toEqual([]);
  await sql.end();
});

test('gaps: field checklists, the report, referrals, profile and the home screen manifest', async ({ browser }, info) => {
  test.skip(!info.project.name.startsWith('phone'), 'the field portal is a phone app');
  test.setTimeout(240_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const field = await mkUser(sql, 'ck', 'field');
  const admin = await mkUser(sql, 'ck', 'admin');
  const [car] = await sql`select id from vehicles order by created_at desc limit 1`;
  const [job] = await sql`select app.create_field_job('detail', ${car!.id}::uuid, now() + interval '1 hour', ${admin.id}::uuid, null, ${field.id}::uuid, 'Yard', 'Full detail') id`;
  const page = await ctx(browser, true);
  const errors = watch(page);
  await signIn(page, field.email, '/field');
  await page.goto(`/field/jobs/${job!.id as string}`);
  await page.getByTestId('acknowledge').click(); await page.getByTestId('start').click({ timeout: 15_000 });
  await expect(page.getByTestId('job-checklist')).toBeVisible({ timeout: 15_000 });
  await check(page, 'field detail checklist');
  await page.getByTestId('ck-grade-standard').click();
  for (const k of ['exterior', 'interior', 'checks', 'fuel', 'items']) await page.getByTestId(`ck-${k}-ok`).click();
  for (const s of ['front', 'rear', 'front_seats', 'instrument_cluster']) await page.getByTestId(`ck-shot-${s}`).setInputFiles({ name: `${s}.png`, mimeType: 'image/png', buffer: PNG });
  await expect.poll(async () => (await sql`select count(*)::int n from condition_report_photos p join condition_reports r on r.id = p.condition_report_id where r.field_job_id = ${job!.id as string}`)[0]!.n, { timeout: 45_000 }).toBe(4);
  await expect.poll(async () => page.evaluate(() => JSON.stringify(((window as unknown as { __ccQueue?: { items: Array<{ seq: number; shot: string; state: string; error?: string }> } }).__ccQueue?.items ?? []).map((i) => [i.seq, i.shot, i.state, i.error]))), { timeout: 30_000 }).toBe('[]');
  await page.getByTestId('job-complete').click();
  await expect(page.getByTestId('job-done')).toBeVisible({ timeout: 30_000 });
  expect((await sql`select status, cleaning_grade from field_jobs where id = ${job!.id as string}`)[0]).toMatchObject({ status: 'done', cleaning_grade: 'standard' });
  // the report
  await page.goto('/field/report'); await check(page, 'field report');
  await page.getByTestId('what-warning_light').click();
  await page.getByTestId('report-details').fill('Tire pressure light came on after the wash');
  await page.getByTestId('report-send').click();
  await expect(page.getByTestId('report-sent')).toBeVisible({ timeout: 15_000 });
  expect((await sql`select queue, priority from tasks where task_type = 'field_report' and created_by = ${field.id}`)[0]).toMatchObject({ queue: 'fleet', priority: 'urgent' });
  // referrals, profile
  await page.goto('/field/referrals'); await expect(page.getByTestId('referral-code')).toHaveText(/^[A-Z0-9]{7}$/); await expect(page.locator('.fd-qr svg')).toBeVisible(); await check(page, 'field referrals');
  await page.goto('/field/profile'); await check(page, 'field profile');
  await page.getByLabel('Mobile phone').fill('416-555-0142'); await page.getByTestId('profile-save').click();
  await expect(page.getByTestId('profile-phone')).toHaveText('416-555-0142', { timeout: 15_000 });
  // add to home screen
  const m = await page.request.get('/field/manifest.webmanifest');
  expect(m.status()).toBe(200);
  const man = await m.json() as { start_url: string; display: string; icons: Array<{ src: string }> };
  expect(man).toMatchObject({ start_url: '/field', display: 'standalone' });
  for (const i of man.icons) expect((await page.request.get(i.src)).status()).toBe(200);
  await expect(page.locator('link[rel="manifest"]')).toHaveAttribute('href', '/field/manifest.webmanifest');
  expect(clean(errors)).toEqual([]);
  await sql.end();
});

test('gaps: find a renter, a Sales quote, and an assistant who covers two functions', async ({ browser }, info) => {
  test.setTimeout(150_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const cs = await mkUser(sql, 'find', 'va', { va: 'cs', cover: ['fleet'] });
  const sales = await mkUser(sql, 'quote', 'va', { va: 'sales' });
  const renter = await mkUser(sql, 'rfind', 'renter');
  const car = await freeCar(sql, 190 + (phone ? 0 : 10), 3);
  await seedRequest(sql, renter, car.id, car.from, car.to);
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, cs.email, '/va');
  await page.goto(`/va/renters?q=${encodeURIComponent(renter.email)}`);
  await expect(page.getByTestId('renter-matches')).toContainText('Riley Renter');
  await check(page, 'va find a renter');
  // the function switcher: customer service, also covering Fleet
  await expect(page.getByTestId('fn-switch')).toBeVisible();
  await page.getByTestId('fn-switch').getByRole('button', { name: 'Fleet operations' }).click();
  await expect(page.locator('nav[aria-label="Assistant"]')).toContainText('Daily checks', { timeout: 15_000 });
  await page.goto('/va/checks'); await expect(page.getByTestId('check-opening')).toBeVisible();
  await page.getByTestId('fn-switch').getByRole('button', { name: 'Customer service and growth' }).click();
  await expect(page.locator('nav[aria-label="Assistant"]')).toContainText('Find a renter', { timeout: 15_000 });
  // a quote by Sales
  const sp = await ctx(browser, phone);
  await signIn(sp, sales.email, '/va');
  await sp.goto('/va/quotes/new'); await check(sp, 'va quote');
  const [v] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id and l.status = 'published' order by random() limit 1`;
  const at = (days: number) => { const d = new Date(Date.now() + days * 86_400_000); return `${d.toISOString().slice(0, 10)}T10:00`; };
  await sp.locator('#q-car').selectOption(v!.id as string);
  await sp.locator('#q-from').fill(at(210 + (phone ? 0 : 5))); await sp.locator('#q-to').fill(at(213 + (phone ? 0 : 5)));
  await sp.locator('#q-name').fill('Quinn Caller');
  await sp.locator('#q-email').fill(`quinn.${Date.now()}.${phone ? 'p' : 'd'}@example.test`);
  await sp.locator('#q-mobile').fill('647-555-0177'); await sp.locator('#q-dob').fill('1985-02-03');
  await sp.getByTestId('quote-create').click();
  await sp.waitForURL(/\/va\/bookings\/[^/]+\?tab=review/, { timeout: 20_000 });
  await check(sp, 'va quote booking');
  const n = decodeURIComponent(new URL(sp.url()).pathname.split('/').pop()!);
  expect((await sql`select status, source, created_by from bookings where booking_number = ${n}`)[0]).toMatchObject({ status: 'requested', source: 'phone', created_by: sales.id });
  expect(clean(errors)).toEqual([]);
  await sql.end();
});

test('gaps: an investor downloads a year of statements; an Admin reads an assistant scorecard', async ({ browser }, info) => {
  test.setTimeout(150_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const me = await mkUser(sql, 'invy', 'renter');
  await sql`delete from user_roles where user_id = ${me.id} and role = 'renter'`;
  const ids = { a: randomUUID(), ia: randomUUID(), ra: randomUUID(), rb: randomUUID(), dc: randomUUID(), ga: randomUUID() };
  await sql`insert into investors (id, user_id, legal_name, investor_type, status, email) values (${ids.a}, ${me.id}, 'Ivy Year', 'individual', 'active', ${me.email})`;
  await sql`insert into documents (id, kind, storage_bucket, storage_path) values (${ids.dc}, 'other', 'documents', 'x/c.pdf')`;
  await sql`insert into investment_agreements (id, investor_id, agreement_number, status, schedule_c_document_id, schedule_d_document_id, exemption_category, legal_advice_choice)
    values (${ids.ga}, ${ids.a}, ${`IA-${ids.a.slice(0, 6)}`}, 'signed', ${ids.dc}, ${ids.dc}, 'accredited_investor', 'declined')`;
  await sql`insert into investments (id, investor_id, agreement_id, is_initial, principal_cents, yearly_bps, investment_date, lockup_end_date) values (${ids.ia}, ${ids.a}, ${ids.ga}, true, 2500000, 1200, date '2026-01-05', date '2026-07-05')`;
  await sql`insert into investment_returns (id, investment_id, return_month, opening_invested_cents, yearly_bps, days_earning, days_in_month, return_cents, disposition, payment_date, closing_invested_cents, status)
    values (${ids.ra}, ${ids.ia}, date '2026-07-01', 2500000, 1200, 31, 31, 25479, 'pay', date '2026-08-15', 2500000, 'paid'), (${ids.rb}, ${ids.ia}, date '2026-08-01', 2500000, 1200, 31, 31, 25479, 'pay', date '2026-09-15', 2500000, 'paid')`;
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, me.email, '/investor');
  await page.goto('/investor/statements');
  await expect(page.getByTestId('year-downloads')).toContainText('All 2026 statements (ZIP)');
  await check(page, 'investor statements year');
  const z = await page.request.get('/investor/statements/year/2026');
  expect(z.status()).toBe(200);
  expect(z.headers()['content-type']).toBe('application/zip');
  const body = await z.body();
  expect(body.subarray(0, 4).toString('hex')).toBe('504b0304');
  expect(body.toString('latin1')).toContain('2026-returns.csv');
  const c = await page.request.get('/investor/statements/year/2026?format=csv');
  expect(await c.text()).toContain('2026-08,25000.00,31,31,254.79,Paid,2026-09-15,paid');
  await page.goto('/investor/profile'); await expect(page.getByTestId('two-step-offer')).toContainText('Set up two-step sign-in'); await check(page, 'investor profile two-step');
  // an Admin reads an assistant's scorecard and gives them a second function
  const admin = await mkUser(sql, 'sc', 'admin');
  const va = await mkUser(sql, 'sc', 'va', { va: 'finance' });
  const ap = await ctx(browser, phone);
  await signIn(ap, admin.email, '/admin');
  await ap.goto(`/admin/staff/${va.id}/scorecard`); await expect(ap.getByTestId('scorecard')).toContainText('Tolls and tickets matched and charged'); await check(ap, 'admin scorecard');
  await ap.goto('/admin/settings/staff');
  await act(ap, `cover-${va.id}`, async (d) => { await d.getByLabel('Also covers (finance, fleet, cs, sales; comma separated)').fill('fleet'); });
  await expect.poll(async () => (await sql`select cover_functions::text c from staff_profiles where user_id = ${va.id}`)[0]!.c, { timeout: 15_000 }).toBe('{fleet}');
  expect(clean(errors)).toEqual([]);
  await sql.end();
});

test('gaps: each portal home loads for its test account and refuses the others (what the live verification checks)', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const tag = `${Date.now().toString(36)}${phone ? 'p' : 'd'}`;
  const accounts = [['renter', '/account'], ['owner', '/owner'], ['investor', '/investor'], ['va_cs', '/va'], ['field', '/field']].map(([role, home]) => ({ role: role!, home: home!, id: randomUUID(),
    email: `verify-e2e-${tag}-${role!.replace('_', '-')}@carmacars.ca` }));
  for (const a of accounts) await sql`insert into local_auth.users (id, email, password_hash) values (${a.id}, ${a.email}, ${hash(PW)})`;
  const [r] = await sql`select public.server_verify_accounts(${sql.json(accounts.map((a) => ({ user_id: a.id, email: a.email, role: a.role })))}) v`;
  expect((r!.v as Array<{ roles: { admin: boolean } }>).every((x) => !x.roles.admin)).toBe(true);
  expect((await sql`select count(*)::int n from email_suppressions where email like ${`verify-e2e-${tag}-%`} and lifted_at is null`)[0]!.n).toBe(5);
  const PORTALS = ['/admin', '/owner', '/investor', '/va', '/field'];
  for (const a of accounts) {
    const page = await ctx(browser, phone);
    const errors = watch(page);
    await signIn(page, a.email, a.home);
    await expect(page.locator('h1').first()).toBeVisible();
    await expect(page.locator('body')).not.toContainText(/couldn.t load/);
    await check(page, `${a.role} home`);
    for (const p of PORTALS.filter((x) => x !== a.home)) {
      await page.goto(p);
      expect(new URL(page.url()).pathname, `${a.role} is refused ${p}`).toMatch(/no-access|not-an-owner/);
    }
    expect(clean(errors), `${a.role}`).toEqual([]);
    await page.context().close();
  }
  await sql.end();
});
