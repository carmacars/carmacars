import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { PDFDocument, StandardFonts } from 'pdf-lib';
import { acceptCookies, db, noOverflow } from './helpers';
import { sampleForm } from '../../src/features/official-forms/fill';

// Migration 0042 end to end, at 375 and 1440, with the fake providers of the local stack (the fake vision model):
// - a 407 ETR statement PDF is read from its text, checked beside the notice, confirmed: the trip in the rental is
//   imported and matched to the renter, the plate not in the fleet becomes an exception, fixed and imported
// - a scanned notice (a photo) is read by the vision model, corrected beside the photo and imported
// - a reading profile is tried on pasted text and saved
// - an Admin covers a plate on a phone (the suggested box and a drawn one, pixelated); the covered photo replaces the
//   public one and the original is kept privately; publishing waits until every public photo is checked
// - an Admin uploads a fillable official form, maps its fields and uses it for owners; the owner downloads it filled
//   and signs it in ink (official forms are never signed on screen)
// - Program settings explain the one turnaround; the vehicle page says the tracker connection is coming soon
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/18122211(?! Canada Inc\.?,? (?:operating as|o\/a) CarmaCars)|Canada Inc\b(?!\.?,? (?:operating as|o\/a) CarmaCars)/i, 'numbered company name (the payee "<legal name>, operating as CarmaCars" is allowed)'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;
const tag = () => `${Date.now().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`;
const VIN_CHARS = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789';
const vin = (prefix: string) => prefix + Array.from({ length: 17 - prefix.length }, () => VIN_CHARS[Math.floor(Math.random() * VIN_CHARS.length)]).join('');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const onlyDesktop = () => test.skip(test.info().project.name !== 'desktop-1440', 'one run: the test opens its own phone and desktop pages');
const STORE = process.env.LOCAL_STORAGE_DIR ?? path.join(process.cwd(), '.local-storage');

function watch(page: Page) {
  const errors: string[] = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(`${new URL(page.url()).pathname}: ${m.text()}`); });
  page.on('pageerror', (e) => errors.push(`${new URL(page.url()).pathname}: ${String(e)}`));
  return errors;
}
const clean = (e: string[]) => e.filter((x) => !/favicon|Failed to load resource|net::ERR|Warning: TT: undefined function/.test(x));
async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
async function mkUser(sql: Sql, role: 'admin' | 'va' | 'renter' | 'owner', extra: { va?: string } = {}) {
  const id = randomUUID(); const email = `${role}.tpf.${tag()}@example.test`;
  const name = { admin: 'Ada Admin', va: 'Val Assistant', renter: 'Riley Renter', owner: 'Olive Owner' }[role];
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, ${name}, null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${extra.va!})`;
  return { id, email };
}
/** An owner with one enrolled car (not on the website), its plate unique to the test. */
async function mkOwnerCar(sql: Sql) {
  const u = await mkUser(sql, 'owner');
  const owner = randomUUID(); const car = randomUUID(); const agr = randomUUID(); const t = tag().toUpperCase();
  const plate = `TP${t.replace(/[^A-Z0-9]/g, '').slice(-5)}`;
  await sql`insert into owners (id, user_id, owner_type, legal_name, status, email, phone, address_line1, city, province, postal_code)
            values (${owner}, ${u.id}, 'individual', 'Olive Owner', 'active', ${u.email}, '416-555-0100', '1 King St W', 'Toronto', 'ON', 'm5v1a1')`;
  await sql`insert into owner_private_details (owner_id, licence_number, date_of_birth) values (${owner}, 'O1234-56789-01234', date '1985-02-03')`;
  await sql`insert into owner_agreements (id, owner_id, kind, agreement_number, agreement_date, status) values (${agr}, ${owner}, 'enrollment', ${`EA-${t}`}, current_date - 30, 'signed')`;
  await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, fleet_policy_added_on, enrollment_date, colour, body_type, odometer_km)
            values (${car}, ${owner}, ${`F-${t}`}, 2022, 'Toyota', 'Corolla', ${vin('2T1')}, ${plate}, 'standard', 'ready_to_list', 'managed', 'transfer', true, current_date - 20, current_date - 20, 'Grey', 'sedan', 21000)`;
  await sql`insert into vehicle_schedules (vehicle_id, owner_agreement_id, schedule_number, vehicle_number, held_by, title_status, management_mode, onboarding_method,
              insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps, enrollment_date, signed_at)
            values (${car}, ${agr}, ${`VS-${t}`}, 1, 'individual', 'owned_outright', 'managed', 'transfer', 45000, 2500, 10000, 3500, current_date - 20, now())`;
  await sql`insert into vehicle_fee_history (vehicle_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from) values (${car}, 'signed_schedule', 45000, 2500, 3500, current_date - 20)`;
  await sql`insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
            values (${car}, 6900, 7900, 39000, 140000, 250, 25, 50000, 7500, 7500, now() - interval '20 days')`;
  await sql`select app.ensure_listing(${car}::uuid)`;
  await sql`update vehicle_listings set seats = 5, transmission = 'automatic' where vehicle_id = ${car}`;
  return { user: u, owner, car, plate };
}
/** A rental of the car that ended last week, for a renter of its own. */
async function mkRental(sql: Sql, car: string) {
  const r = await mkUser(sql, 'renter');
  const [renter] = await sql`insert into renters (user_id, legal_name, date_of_birth, mobile, email, identity_status) values (${r.id}, 'Riley Renter', date '1990-05-05', '647-555-0199', ${r.email}, 'verified') returning id`;
  const n = `TP-${tag().toUpperCase().slice(-8)}`;
  await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days, handed_over_at, checked_in_at,
      daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days, rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km,
      deposit_cents, subtotal_at_booking_cents, hst_at_booking_cents, total_due_at_booking_cents)
    values (${n}, 'standard', 'returned', ${car}, ${renter!.id}, now() - interval '15 days', now() - interval '11 days', now() - interval '7 days', now() - interval '7 days', 4, now() - interval '11 days', now() - interval '7 days',
      10000, 12000, 56000, 180000, 'daily', 4, 0, 40000, 0, 200, 800, 35, 100000, 40000, 5200, 45200)`;
  return n;
}
async function signIn(page: Page, email: string, expectPath: string, next = '') {
  await page.goto(`/sign-in${next ? `?next=${encodeURIComponent(next)}` : ''}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL, acceptDownloads: true });
  return c.newPage();
}
const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
/** A statement as 407 ETR prints it, as a PDF with a text layer. */
async function statementPdf(lines: string[]): Promise<Buffer> {
  const doc = await PDFDocument.create();
  const page = doc.addPage([612, 792]);
  const font = await doc.embedFont(StandardFonts.Helvetica);
  lines.forEach((l, i) => page.drawText(l, { x: 36, y: 750 - i * 18, size: 9, font }));
  return Buffer.from(await doc.save());
}

test('tolls: a 407 ETR statement is read from its text, checked beside it, imported and matched; the exception is fixed', async ({ browser }) => {
  onlyDesktop();
  test.setTimeout(180_000);
  const sql = db();
  try {
    const admin = await mkUser(sql, 'admin');
    const { car, plate } = await mkOwnerCar(sql);
    const other = await mkOwnerCar(sql);
    const booking = await mkRental(sql, car);
    const trip = new Date(Date.now() - 9 * 86_400_000);
    const stmt = `ST-${tag().toUpperCase().slice(-7)}`;
    const pdf = await statementPdf(['407 ETR Express Toll Route', `Statement Number: ${stmt}`, 'Account Number: 1234-5678', `Payment Due Date: ${ymd(new Date(Date.now() + 20 * 86_400_000))}`,
      'Trip Date  Time  Entry  Exit  Distance  Plate  Toll  Camera Charge  Total',
      `${ymd(trip)}  11:15 AM  Highway 400  Dufferin St  23.45 km  ${plate.slice(0, 4)} ${plate.slice(4)}  $8.14  $4.20  $12.34`,
      `${ymd(trip)}  3:40 PM  Yonge St  Keele St  6.02 km  ZZZZ 999  $2.10  $4.20  $6.30`, 'Total Amount Due  $18.64']);
    const desk = await ctx(browser, false);
    const errors = watch(desk);
    await signIn(desk, admin.email, '/admin', '/admin/tolls');
    await desk.goto('/admin/tolls');
    await desk.getByTestId('tolls-read-link').click();
    await desk.waitForURL('**/admin/tolls/read');
    await check(desk, 'read a notice 1440');
    await desk.getByTestId('toll-read-file').setInputFiles({ name: 'statement.pdf', mimeType: 'application/pdf', buffer: pdf });
    await desk.getByTestId('toll-read-run').click();
    await desk.waitForURL(/\/admin\/tolls\/read\/[0-9a-f-]{36}$/, { timeout: 30_000 });
    await expect(desk.getByTestId('toll-review')).toHaveAttribute('data-status', 'in_review');
    await expect(desk.getByTestId('read-line-1')).toBeVisible();
    await expect(desk.getByTestId('line-1-plate')).toHaveValue(plate);
    await expect(desk.getByTestId('line-1-amount')).toHaveValue('12.34');
    await expect(desk.getByTestId('line-1-fees')).toHaveValue('4.20');
    await expect(desk.getByTestId('line-2-problems')).toContainText('Plate not in the fleet');
    // the notice is drawn beside the lines
    await expect(desk.getByTestId('toll-source').locator('canvas')).toBeVisible();
    await check(desk, 'check a notice 1440');
    const readId = desk.url().split('/').pop()!;
    const phone = await ctx(browser, true);
    await signIn(phone, admin.email, '/admin', `/admin/tolls/read/${readId}`);
    await phone.goto(`/admin/tolls/read/${readId}`, { waitUntil: 'networkidle' });
    await expect(phone.getByTestId('read-line-2')).toBeVisible();
    await check(phone, 'check a notice 375');
    await phone.context().close();

    await desk.getByTestId('read-confirm').click();
    await expect(desk.getByTestId('toll-review')).toHaveAttribute('data-status', 'confirmed', { timeout: 20_000 });
    await expect(desk.getByTestId('read-line-1')).toHaveAttribute('data-status', 'imported');
    await expect(desk.getByTestId('read-line-2')).toHaveAttribute('data-status', 'exception');
    const [t1] = await sql`select t.matched_to, t.match_confidence, b.booking_number, t.statement_number, t.document_id is not null as has_doc, t.amount_cents
                             from toll_notice_read_lines l join toll_tickets t on t.id = l.toll_ticket_id left join bookings b on b.id = t.booking_id where l.read_id = ${readId} and l.line_no = 1`;
    expect([t1!.matched_to, t1!.match_confidence, t1!.booking_number, t1!.statement_number, t1!.has_doc, Number(t1!.amount_cents)]).toEqual(['renter', 'high', booking, stmt, true, 1234]);
    const [res] = await sql`select (result ->> 'charged')::int as charged from toll_notice_reads where id = ${readId}`;
    expect(res!.charged).toBe(1);
    // the exception: the plate was misread; corrected to a car of the fleet and imported on its own
    await desk.getByTestId('line-2-plate').fill(other.plate);
    await desk.getByTestId('line-2-save').click();
    await expect(desk.getByTestId('line-2-import')).toBeVisible({ timeout: 15_000 });
    await desk.getByTestId('line-2-import').click();
    await expect(desk.getByTestId('read-line-2')).toHaveAttribute('data-status', 'imported', { timeout: 15_000 });
    const [t2] = await sql`select t.vehicle_id, t.matched_to from toll_notice_read_lines l join toll_tickets t on t.id = l.toll_ticket_id where l.read_id = ${readId} and l.line_no = 2`;
    expect(t2!.vehicle_id).toBe(other.car);
    const [task] = await sql`select status from tasks where dedupe_key = ${`toll_read_exceptions:${readId}`}`;
    expect(task!.status).toBe('done');
    expect(clean(errors)).toEqual([]);
    await desk.context().close();
  } finally { await sql.end(); }
});

test('tolls: a photo of a notice is read by the vision model, corrected beside the photo, imported; a profile is tried and saved', async ({ browser }) => {
  onlyDesktop();
  test.setTimeout(150_000);
  const sql = db();
  try {
    const fin = await mkUser(sql, 'va', { va: 'finance' });
    const { plate } = await mkOwnerCar(sql);
    const page = await ctx(browser, false);
    const errors = watch(page);
    // the "photo" of a parking notice: drawn here and taken as a screenshot
    await page.setContent('<body style="margin:0;background:#fff;font:20px Arial"><div style="padding:30px;width:700px"><h1>City of Toronto</h1><p>Penalty Notice Number: PN 7710-0042</p><p>Licence Plate: FAKE 123</p><p>Date of Infraction: 2026-10-02 2:32 PM</p><p>Penalty Amount: $50.00</p></div></body>');
    const shot = await page.screenshot({ type: 'png' });
    await signIn(page, fin.email, '/va', '/va/tolls/read');
    await page.goto('/va/tolls/read', { waitUntil: 'networkidle' });
    await page.getByTestId('toll-read-file').setInputFiles({ name: 'notice.png', mimeType: 'image/png', buffer: shot });
    await page.getByTestId('toll-read-run').click();
    await page.waitForURL(/\/va\/tolls\/read\/[0-9a-f-]{36}$/, { timeout: 30_000 });
    const readId = page.url().split('/').pop()!;
    const [r] = await sql`select method, model, kind, authority from toll_notice_reads where id = ${readId}`;
    expect([r!.method, r!.model, r!.kind, r!.authority]).toEqual(['vision', 'fake-vision-v1', 'parking', 'City of Toronto']);
    const [call] = await sql`select count(*)::int as n from provider_calls where purpose = 'toll_read' and created_at > now() - interval '5 minutes'`;
    expect(call!.n).toBeGreaterThan(0);
    await expect(page.getByTestId('toll-source').locator('img')).toBeVisible();
    await expect(page.getByTestId('line-1-problems')).toContainText('Plate not in the fleet');
    await check(page, 'va check a scanned notice 1440');
    // the plate on the photo is one of the fleet's (the fake reads FAKE123): corrected, checked, confirmed
    await page.getByTestId('line-1-plate').fill(plate);
    // the fake model reads the same notice number every time: a number of this run, so a second run is not a duplicate
    const pn = `PN ${tag().toUpperCase()}`;
    await page.getByTestId('line-1-notice_number').fill(pn);
    await page.getByTestId('line-1-check').click();
    await expect(page.getByTestId('read-line-1')).toHaveAttribute('data-status', 'checked', { timeout: 15_000 });
    await page.getByTestId('read-charge').uncheck();
    await page.getByTestId('read-confirm').click();
    await expect(page.getByTestId('read-line-1')).toHaveAttribute('data-status', 'imported', { timeout: 20_000 });
    const [t] = await sql`select t.kind, t.notice_number, t.amount_cents from toll_notice_read_lines l join toll_tickets t on t.id = l.toll_ticket_id where l.read_id = ${readId}`;
    expect([t!.kind, t!.notice_number, Number(t!.amount_cents)]).toEqual(['parking', pn, 5000]);

    // a reading profile, adjusted without code: tried on pasted text, then saved
    await page.goto('/va/tolls/profiles', { waitUntil: 'networkidle' });
    const [p] = await sql`select id from toll_import_profiles where header_signature = 'text:ontario-parking'`;
    const row = page.locator('details').filter({ has: page.getByTestId(`profile-${p!.id}`) });
    await row.locator('summary').click();
    const form = page.getByTestId(`profile-${p!.id}`);
    await form.getByLabel('Try it: paste the text of a notice').fill(`City of Mississauga\nPenalty Notice Number: PN 55-1\nLicence Plate: ${plate}\nDate of Infraction: 2026-10-05 9:10 AM\nPenalty Amount: $35.00`);
    await expect(page.getByTestId(`profile-trial-${p!.id}`)).toContainText('PN 55-1');
    await expect(page.getByTestId(`profile-trial-${p!.id}`)).toContainText('$35.00');
    await form.getByLabel('Notes').fill(`Tried ${tag()}`);
    await form.getByRole('button', { name: 'Save the profile' }).click();
    await expect(form.getByRole('status').filter({ hasText: 'Saved' })).toBeVisible({ timeout: 15_000 });
    const [saved] = await sql`select notes, sample_text from toll_import_profiles where id = ${p!.id}`;
    expect(saved!.notes).toMatch(/^Tried /);
    expect(saved!.sample_text).toContain('PN 55-1');
    await check(page, 'reading profiles 1440');
    expect(clean(errors)).toEqual([]);
    await page.context().close();
  } finally { await sql.end(); }
});

test('plates: an Admin covers a plate on a phone; the covered photo replaces the public one; publishing waits for every public photo', async ({ browser }) => {
  onlyDesktop();
  test.setTimeout(180_000);
  const sql = db();
  try {
    const admin = await mkUser(sql, 'admin');
    const { car } = await mkOwnerCar(sql);
    // a real photo in the public bucket (local storage), as the pipeline leaves it
    const shooter = await ctx(browser, false);
    await shooter.setContent('<body style="margin:0"><div style="width:1200px;height:800px;background:linear-gradient(#9cc,#fff);position:relative"><div style="position:absolute;left:300px;top:300px;width:600px;height:260px;background:#333;border-radius:40px"></div><div style="position:absolute;left:520px;top:470px;width:160px;height:60px;background:#fff;border:3px solid #036;font:bold 36px Arial;text-align:center;line-height:60px">ABCD 123</div></div></body>');
    await shooter.setViewportSize({ width: 1200, height: 800 });
    const jpg = await shooter.screenshot({ type: 'jpeg', quality: 90 });
    await shooter.context().close();
    const dir = path.join(STORE, 'vehicle-public', 'vehicles', car);
    mkdirSync(dir, { recursive: true });
    const [ik] = await sql`insert into listing_intakes (vehicle_id, started_by, started_role, state, review_required) values (${car}, ${admin.id}, 'admin', 'started', true) returning id`;
    const shots = await sql`select code, is_public from listing_shot_types where required and is_active order by seq`;
    for (const s of shots) {
      writeFileSync(path.join(dir, `${s.code}.jpg`), jpg);
      await sql`select app.record_listing_upload(${admin.id}, ${ik!.id}, jsonb_build_object('shot_type', ${s.code}::text, 'original_path', ${`vehicles/${car}/original/${s.code}.jpg`}::text, 'width', 1200, 'height', 800, 'byte_size', ${jpg.length}::int, 'mime_type', 'image/jpeg'))`;
    }
    await sql`select app.submit_listing_intake(${admin.id}, ${ik!.id})`;
    const words = Array.from({ length: 140 }, (_, i) => ['smooth', 'quiet', 'roomy', 'comfortable', 'efficient', 'bright', 'clean', 'easy'][i % 8]).join(' ');
    const copy = { headline: 'A comfortable car for the city and the highway trips', description: words, features: ['Heated seats', 'Apple CarPlay', 'Android Auto', 'Backup camera', 'Keyless entry', 'Blind spot assist', 'LED headlights'],
      faq: [{ question: 'How many suitcases fit?', answer: 'Two large suitcases.' }, { question: 'Can I fit a child seat?', answer: 'Yes, two.' }, { question: 'Is it good in winter?', answer: 'Yes, with winter tires.' }],
      seo_title: 'Car rental in Toronto', seo_description: 'Rent this car in Toronto.', model: 'e2e', prompt_version: 'e2e' };
    for (let k = 0; k < 10; k++) {
      // this car's jobs only, as the worker would claim them (other tests' jobs are left alone)
      const jobs = await sql`update listing_jobs set status = 'running', locked_at = now(), locked_by = 'e2e-plates', attempts = attempts + 1, started_at = coalesce(started_at, now())
                               where intake_id = ${ik!.id} and status = 'queued' returning *`;
      if (!jobs.length) break;
      for (const j of jobs) {
        const [ph] = j.vehicle_photo_id ? await sql`select shot_type from vehicle_photos where id = ${j.vehicle_photo_id}` : [null];
        const out = j.kind === 'draft_copy' ? copy : j.kind === 'process_photo' ? { processed_path: `vehicles/${car}/${ph!.shot_type}.jpg`, width: 1200, height: 800 } : j.kind === 'decode_vin' ? { ok: false } : {};
        await sql`select app.complete_listing_job(${j.id}, ${sql.json(out)}, 'fake', 0, 10)`;
      }
    }
    expect((await sql`select state from listing_intakes where id = ${ik!.id}`)[0]!.state).toBe('needs_review');
    const [front] = await sql`select id, processed_path from vehicle_photos where vehicle_id = ${car} and shot_type = 'front' and replaced_at is null`;

    const phone = await ctx(browser, true);
    const errors = watch(phone);
    await signIn(phone, admin.email, '/admin', `/admin/listings/${ik!.id}`);
    await phone.goto(`/admin/listings/${ik!.id}`, { waitUntil: 'networkidle' });
    await expect(phone.getByTestId('plate-front')).toHaveAttribute('data-plate', 'unchecked');
    await phone.getByTestId('plate-edit-front').click();
    const editor = phone.getByTestId('plate-editor');
    await expect(editor).toBeVisible();
    // the vision model's suggestion (the fake answers a box in the lower middle)
    await expect(phone.getByTestId('plate-note')).toContainText('Suggested 1 box', { timeout: 20_000 });
    // the fake model's box is below the plate (as the live model's was); it is moved onto the plate's edges
    const sug = JSON.parse((await phone.getByTestId('plate-canvas').getAttribute('data-boxes'))!)[0] as { x: number; y: number; w: number; h: number };
    const plateBox = { x: 520 / 1200, y: 470 / 800, w: 160 / 1200, h: 60 / 800 };
    const ix = Math.max(0, Math.min(sug.x + sug.w, plateBox.x + plateBox.w) - Math.max(sug.x, plateBox.x)), iy = Math.max(0, Math.min(sug.y + sug.h, plateBox.y + plateBox.h) - Math.max(sug.y, plateBox.y));
    expect(ix * iy / (sug.w * sug.h + plateBox.w * plateBox.h - ix * iy), `suggested ${JSON.stringify(sug)}`).toBeGreaterThan(0.3);
    // and one more box drawn by hand over the plate, pixelated
    const cv = phone.getByTestId('plate-canvas');
    await cv.scrollIntoViewIfNeeded();
    const b = (await cv.boundingBox())!;
    await phone.mouse.move(b.x + b.width * 0.42, b.y + b.height * 0.57);
    await phone.mouse.down();
    await phone.mouse.move(b.x + b.width * 0.5, b.y + b.height * 0.62, { steps: 4 });
    await phone.mouse.move(b.x + b.width * 0.58, b.y + b.height * 0.68, { steps: 4 });
    await phone.mouse.up();
    await expect(cv).toHaveAttribute('aria-label', /2 boxes/);
    await phone.getByTestId('plate-style-pixelate').check();
    await check(phone, 'plate editor 375');
    await phone.getByTestId('plate-save').click();
    await expect(phone.getByTestId('plate-front')).toHaveAttribute('data-plate', 'covered', { timeout: 20_000 });
    const [after] = await sql`select processed_path, uncovered_path, plate_style, jsonb_array_length(plate_boxes) as n, plate_checked_by from vehicle_photos where id = ${front!.id}`;
    expect(after!.processed_path).toMatch(new RegExp(`^vehicles/${car}/front-c[0-9a-f]{6}\\.jpg$`));
    expect([after!.plate_style, after!.n, after!.plate_checked_by]).toEqual(['pixelate', 2, admin.id]);
    // the covered file is public, the old public file is gone, the photo as it was is kept privately
    expect(existsSync(path.join(STORE, 'vehicle-public', after!.processed_path))).toBe(true);
    expect(existsSync(path.join(STORE, 'vehicle-public', front!.processed_path))).toBe(false);
    expect(existsSync(path.join(STORE, 'vehicle-originals', after!.uncovered_path))).toBe(true);
    const img = await phone.request.get(`/_local/vehicle-public/${after!.processed_path}`);
    expect(img.status()).toBe(200);
    expect(clean(errors)).toEqual([]);
    await phone.context().close();

    // since 0070 the plate check holds back each photo, not the listing: approving publishes the car at once, and the
    // photos still to check stay private until their plates are checked
    const desk = await ctx(browser, false);
    await signIn(desk, admin.email, '/admin', `/admin/listings/${ik!.id}`);
    await desk.goto(`/admin/listings/${ik!.id}`, { waitUntil: 'networkidle' });
    await expect(desk.getByTestId('listing-review')).toContainText('licence plate not covered');
    await check(desk, 'listing review plates 1440');
    await desk.getByTestId('listing-approve').click();
    await expect(desk.getByRole('status').filter({ hasText: 'Approved and published' })).toBeVisible({ timeout: 20_000 });
    const [l] = await sql`select status from vehicle_listings where vehicle_id = ${car}`;
    expect(l!.status).toBe('published');
    const held = async () => (await sql`select count(*)::int n from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type
                                         where ph.vehicle_id = ${car} and ph.replaced_at is null and ph.status = 'approved' and st.is_public and ph.plate_status = 'unchecked' and not ph.is_public`)[0]!.n as number;
    expect(await held()).toBeGreaterThan(0);
    expect((await sql`select count(*)::int n from vehicle_photos where vehicle_id = ${car} and replaced_at is null and plate_status = 'unchecked' and is_public`)[0]!.n).toBe(0);
    await desk.goto(`/admin/listings/${ik!.id}`, { waitUntil: 'networkidle' });
    await desk.getByTestId('plates-none-visible').click();
    await desk.getByTestId('plates-none-visible-yes').click();
    await expect(desk.getByTestId('plates-none-visible')).toHaveCount(0, { timeout: 20_000 });
    // checked: each goes public by itself
    expect(await held()).toBe(0);
    await sql`select app.unlist_listing(${car}::uuid, ${admin.id}::uuid, 'End to end test car', null)`;
    await desk.context().close();
  } finally { await sql.end(); }
});

test('forms: an Admin maps an official fillable PDF; the owner downloads it filled and signs it in ink; settings and tracker notes', async ({ browser }) => {
  onlyDesktop();
  test.setTimeout(180_000);
  const sql = db();
  const [before] = await sql`select id from pdf_templates where form_code = 'SR-LV-012' and is_current`;
  try {
    const admin = await mkUser(sql, 'admin');
    const { user, car } = await mkOwnerCar(sql);
    await sql`update program_settings set company_rin = coalesce(company_rin, 'RIN-E2E'), company_address = coalesce(company_address, '100 Test St, Toronto ON') where id = (select id from app.settings())`;
    await sql`select app.fill_government_form(${car}::uuid, 'SR-LV-012', ${admin.id}::uuid)`;
    const desk = await ctx(browser, false);
    const errors = watch(desk);
    await signIn(desk, admin.email, '/admin', '/admin/settings/forms');
    await desk.goto('/admin/settings/forms', { waitUntil: 'networkidle' });
    // 0047 loaded the official form with a draft mapping: waiting for an Admin to check it
    await expect(desk.getByTestId('form-SR-LV-012')).toContainText('Mapping to check');
    await desk.getByTestId('form-upload-SR-LV-012').setInputFiles({ name: 'sr-lv-012-fillable.pdf', mimeType: 'application/pdf', buffer: Buffer.from(await sampleForm()) });
    await expect(desk.getByTestId('form-map-SR-LV-012')).toBeVisible({ timeout: 20_000 });
    await expect(desk.getByTestId('form-SR-LV-012')).toContainText('Mapping to check');
    const map = desk.getByTestId('form-map-SR-LV-012');
    await map.getByTestId('map-owner_name').selectOption('owner.legal_name');
    await map.getByTestId('map-vin').selectOption('vehicle.vin');
    await map.getByTestId('map-plate').selectOption('vehicle.plate');
    await map.getByTestId('map-postal_code').selectOption('owner.postal_code');
    await map.getByLabel('Format of postal_code').selectOption('postal');
    await map.getByTestId('map-is_lease').selectOption('method.is_lease');
    await map.getByTestId('map-owner_signature').selectOption('@signature');
    await check(desk, 'settings forms 1440');
    await desk.getByTestId('form-verify-SR-LV-012').click();
    await expect(desk.getByRole('status').filter({ hasText: 'Checked and in use' })).toBeVisible({ timeout: 20_000 });
    const [fill] = await sql`select id, mode, status, field_values ->> 'postal_code' as postal from government_form_fills where vehicle_id = ${car} and form_code = 'SR-LV-012' and superseded_at is null`;
    expect([fill!.mode, fill!.status, fill!.postal]).toEqual(['pdf', 'ready', 'M5V 1A1']);
    // the one turnaround, explained; the tracker, coming soon
    await desk.goto('/admin/settings/program', { waitUntil: 'networkidle' });
    await expect(desk.getByTestId('turnaround-help')).toContainText('not added on top');
    await expect(desk.getByLabel('Turnaround between trips (minutes)')).toBeVisible();
    await expect(desk.getByText('Turnaround block minutes')).toHaveCount(0);
    await desk.goto(`/admin/vehicles/${car}?tab=records`, { waitUntil: 'networkidle' });
    await expect(desk.getByTestId('tracker-coming-soon')).toContainText('Coming soon');
    expect(clean(errors)).toEqual([]);
    await desk.context().close();

    const phone = await ctx(browser, true);
    await signIn(phone, user.email, '/owner', '/owner/documents');
    await phone.goto('/owner/documents', { waitUntil: 'networkidle' });
    await expect(phone.getByTestId('owner-gov-forms')).toContainText('Official form, filled for you');
    await phone.getByTestId('owner-gov-forms').getByRole('link', { name: 'SR-LV-012' }).click();
    await phone.waitForURL(`**/owner/documents/forms/${fill!.id}/official`);
    await check(phone, 'owner official form 375');
    const dl = phone.waitForEvent('download');
    await phone.getByTestId('official-download').click();
    const file = await (await dl).path();
    const { readFileSync } = await import('node:fs');
    const filled = await PDFDocument.load(readFileSync(file!));
    expect(filled.getForm().getTextField('owner_name').getText()).toBe('Olive Owner');
    expect(filled.getForm().getTextField('postal_code').getText()).toBe('M5V 1A1');
    // an official form is printed and signed in ink (0120): no signature pad, the page says so, and the route refuses one
    await expect(phone.getByTestId('official-ink')).toContainText('Print it and sign it in ink');
    await expect(phone.getByTestId('signature-pad')).toHaveCount(0);
    expect((await phone.request.post(`/owner/documents/forms/${fill!.id}/signed`, { data: 'x' })).status()).toBe(410);
    expect(filled.getForm().getTextField('owner_signature').getText() ?? '', 'the signature box stays empty').toBe('');
    await phone.context().close();
  } finally {
    // the other tests see the form as it was (the data sheet)
    await sql`update pdf_templates set is_current = false where form_code = 'SR-LV-012' and is_current and id <> ${before!.id}`;
    await sql`update pdf_templates set is_current = true where id = ${before!.id}`;
    await sql.end();
  }
});
