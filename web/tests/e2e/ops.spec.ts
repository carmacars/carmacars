import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, pdfText, storeFixturePdf } from './helpers';

// Migration 0040 end to end, at 375 and 1440, with the fake providers of the local stack:
// - an Admin proposes a change to a confirmed booking (a day longer); the renter reviews it, signs the amendment
//   and the difference is charged to the card on file; the booking moves only then; the signed amendment is a PDF
//   under Documents; a second proposal is declined and nothing moves
// - the cleaning block follows the trip on the car's calendar and an Admin removes it
// - the renter and customer service send an additional driver a new signing link; the older one stops working
// - a request made before the account existed is attached after a verified sign-in, with a notice
// - an Admin clears a possible duplicate (a VIN one character apart)
// - an owner uploads Form D, customer service sends it back with a reason, the owner uploads again, it is approved
// - field staff take the listing photos inside the photo-shoot job and submits them
// Every page is checked with axe, for overflow and with the copy rules.
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/18122211(?! Canada Inc\.?,? (?:operating as|o\/a) CarmaCars)|Canada Inc\b(?!\.?,? (?:operating as|o\/a) CarmaCars)/i, 'numbered company name (the payee "<legal name>, operating as CarmaCars" is allowed)'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
const PDF = Buffer.from('%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n');
const VIN_CHARS = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789';
const vin = (prefix: string) => prefix + Array.from({ length: 17 - prefix.length }, () => VIN_CHARS[Math.floor(Math.random() * VIN_CHARS.length)]).join('');
/** A VIN with a right check digit (position 9): a near copy of a real VIN is what the similarity check flags. */
function realVin(prefix: string) {
  const s = vin(prefix).split('');
  const val = (c: string) => (/\d/.test(c) ? Number(c) : 'ABCDEFGH'.includes(c) ? 'ABCDEFGH'.indexOf(c) + 1 : 'JKLMN'.includes(c) ? 'JKLMN'.indexOf(c) + 1 : c === 'P' ? 7 : c === 'R' ? 9 : 'STUVWXYZ'.indexOf(c) + 2);
  const w = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];
  const m = s.reduce((a, c, i) => a + val(c) * w[i]!, 0) % 11;
  s[8] = m === 10 ? 'X' : String(m);
  return s.join('');
}
const tag = () => `${Date.now().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`;

/** Console errors and page errors while a test runs, each with the address it happened on. */
function watch(page: Page) {
  const errors: string[] = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(`${new URL(page.url()).pathname}: ${m.text()}`); });
  page.on('pageerror', (e) => errors.push(`${new URL(page.url()).pathname}: ${String(e)}`));
  return errors;
}
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

async function mkUser(sql: Sql, role: 'admin' | 'va' | 'field' | 'renter' | 'owner', extra: { va?: string; email?: string } = {}) {
  const id = randomUUID(); const email = extra.email ?? `${role}.ops.${tag()}@example.test`;
  const name = { admin: 'Ada Admin', va: 'Val Assistant', field: 'Finn Field', renter: 'Riley Renter', owner: 'Olive Owner' }[role];
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, ${name}, null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${extra.va!})`;
  if (role === 'field') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver_detailer')`;
  return { id, email };
}
async function freeCar(sql: Sql, start: number, days: number) {
  const from = new Date(Date.now() + start * 86_400_000); const to = new Date(from.getTime() + (days + 3) * 86_400_000);
  const rows = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and (not v.is_sample or v.sample_bookable)
      and not exists (select 1 from bookings b where b.vehicle_id = v.id and b.status in ('requested','offered','pending_payment','confirmed','on_rent','returned','closed')
                        and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${from.toISOString()}::timestamptz, ${to.toISOString()}::timestamptz))
      and not exists (select 1 from vehicle_calendar_blocks k where k.vehicle_id = v.id and k.removed_at is null and k.starts_at < ${to.toISOString()}::timestamptz and (k.ends_at is null or k.ends_at > ${from.toISOString()}::timestamptz))
      and not exists (select 1 from field_jobs j where j.vehicle_id = v.id and j.status not in ('cancelled', 'done') and j.scheduled_at between ${from.toISOString()}::timestamptz - interval '3 days' and ${to.toISOString()}::timestamptz)
    order by random() limit 1`;
  if (!rows[0]) throw new Error('no free car');
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  return { id: rows[0].id as string, from: ymd(from), to: ymd(new Date(from.getTime() + days * 86_400_000)) };
}
async function seedRequest(sql: Sql, renter: { id: string | null; email: string }, vehicle: string, from: string, to: string, drivers: Array<Record<string, string>> = []) {
  const req = {
    request_key: randomUUID(), vehicle_id: vehicle, pickup_at: `${from}T10:00:00-04:00`, return_at: `${to}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' },
    coverage_option: 2, extras: { winter_tire: false, baby_seats: 0 },
    renter: { email: renter.email, full_name: 'Riley Renter', mobile: '+16475550123', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: drivers,
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${renter.id}) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  return v;
}
/** Offered, approved, signed (a completed agreement with the renter and any additional driver as signers), paid with
 *  a card on file the fake processor can charge again, verified, covered, confirmed. */
async function confirmBooking(sql: Sql, booking: string, admin: string) {
  await sql`select app.send_offer(${booking}::uuid, ${admin}::uuid)`;
  await sql`select app.approve_offer(b.id, b.current_offer_version, (select user_id from renters where id = b.renter_id)) from bookings b where b.id = ${booking}`;
  const doc = randomUUID(); const sig = randomUUID(); const ra = randomUUID();
  await sql`insert into documents (id, kind, storage_bucket, storage_path, booking_id, sha256) values (${doc}, 'rental_agreement', 'agreements', ${`bookings/${booking}/agreement.pdf`}, ${booking}, ${'1'.repeat(64)})`;
  storeFixturePdf('agreements', `bookings/${booking}/agreement.pdf`);
  await sql`insert into signature_requests (id, document_id, provider, provider_envelope, status, completed_at) values (${sig}, ${doc}, 'builtin', ${`env-${booking}`}, 'completed', now())`;
  await sql`insert into rental_agreements (id, booking_id, agreement_number, template_version, document_id, document_sha256, signature_request_id, status, countersigner_name, renter_signed_at, completed_at)
            values (${ra}, ${booking}, ${`RA-${tag().toUpperCase()}`}, 'rental-e2e', ${doc}, ${'1'.repeat(64)}, ${sig}, 'completed', 'Casey Staff', now(), now())`;
  await sql`insert into rental_agreement_signers (agreement_id, signer_role, signer_name, signer_email) select ${ra}, 'renter', r.legal_name, r.email from bookings b join renters r on r.id = b.renter_id where b.id = ${booking}`;
  await sql`insert into rental_agreement_signers (agreement_id, signer_role, booking_driver_id, driver_id, signer_name, signer_email)
            select ${ra}, 'additional_driver', bd.id, d.id, d.full_name, d.email from booking_drivers bd join drivers d on d.id = bd.driver_id where bd.booking_id = ${booking} and bd.role = 'additional'`;
  await sql`update bookings set signature_request_id = ${sig}, agreement_document_id = ${doc} where id = ${booking}`;
  await sql`insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
            select id, renter_id, 'booking_total', 'charge', 'card', renter_due_at_booking_cents, 'succeeded', now() from bookings where id = ${booking}`;
  const pm = randomUUID();
  await sql`insert into payment_methods (id, renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit)
            select ${pm}, renter_id, 'visa', '4242', 'Riley Renter', 12, 2031, true from bookings where id = ${booking}`;
  await sql`insert into payment_method_secrets (payment_method_id, processor_customer_id, processor_method_id) values (${pm}, ${`cus_fake_${tag()}`}, ${`pm_fake_${tag()}`})`;
  await sql`update bookings set card_on_file_id = ${pm} where id = ${booking}`;
  await sql`update bookings set status = 'confirmed' where id = ${booking}`;
  await sql`update booking_drivers set identity_method = 'staff_review', identity_verified_on = current_date, licence_number = coalesce(licence_number, 'L1234-56789-01234'), licence_expiry = coalesce(licence_expiry, date '2031-01-01') where booking_id = ${booking}`;
  await sql`insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at) values (${booking}, 2, 'confirmed', 'Bank', '4242', now())`;
  await sql`update bookings set coverage_option = 2, coverage_confirmed_at = now(), blocks_calendar = true where id = ${booking}`;
}
/** An owner with one managed car (not on the website), as tests/e2e/pipeline.spec builds one. */
async function mkOwnerCar(sql: Sql, car: { year: number; make: string; model: string; colour: string; vin: string }) {
  const u = await mkUser(sql, 'owner');
  const owner = randomUUID(); const id = randomUUID(); const agr = randomUUID(); const t = tag().toUpperCase();
  await sql`insert into owners (id, user_id, owner_type, legal_name, status, email, phone) values (${owner}, ${u.id}, 'individual', 'Olive Owner', 'active', ${u.email}, '416-555-0100')`;
  await sql`insert into owner_agreements (id, owner_id, kind, agreement_number, agreement_date, status) values (${agr}, ${owner}, 'enrollment', ${`EA-${t}`}, current_date - 30, 'signed')`;
  await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, fleet_policy_added_on, enrollment_date, colour)
            values (${id}, ${owner}, ${`F-${t}`}, ${car.year}, ${car.make}, ${car.model}, ${car.vin}, ${`OP${t.slice(-5)}`}, 'standard', 'ready_to_list', 'managed', 'transfer', true, current_date - 20, current_date - 20, ${car.colour})`;
  await sql`insert into vehicle_schedules (vehicle_id, owner_agreement_id, schedule_number, vehicle_number, held_by, title_status, management_mode, onboarding_method,
              insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps, enrollment_date, signed_at)
            values (${id}, ${agr}, ${`VS-${t}`}, 1, 'individual', 'owned_outright', 'managed', 'transfer', 45000, 2500, 10000, 3500, current_date - 20, now())`;
  await sql`insert into vehicle_fee_history (vehicle_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from) values (${id}, 'signed_schedule', 45000, 2500, 3500, current_date - 20)`;
  await sql`insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
            values (${id}, 6900, 7900, 39000, 140000, 250, 25, 50000, 7500, 7500, now() - interval '20 days')`;
  await sql`select app.ensure_listing(${id}::uuid)`;
  await sql`update vehicle_listings set seats = 5, transmission = 'automatic' where vehicle_id = ${id}`;
  return { user: u, owner, car: id };
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
async function act(page: Page, button: ReturnType<Page['locator']>, testId: string, fill: (d: ReturnType<Page['locator']>) => Promise<void> = async () => {}) {
  await button.click();
  const dlg = page.locator('dialog[open]');
  await fill(dlg);
  await dlg.getByTestId(`${testId}-submit`).click();
}
const outbox = async (sql: Sql, code: string, where: { booking?: string; to?: string }, min = 1) => {
  const read = () => sql`select to_address, payload from notification_outbox where code = ${code}
    and (${where.booking ?? null}::uuid is null or booking_id = ${where.booking ?? null}::uuid) and (${where.to ?? null}::text is null or to_address = ${where.to ?? null}::text) order by created_at`;
  // another worker may be processing the events: wait for the row instead of reading once
  for (let i = 0; i < 30; i++) {
    await sql`select app.process_events(1000)`;
    const rows = await read();
    if (rows.length >= min) return rows;
    await new Promise((r) => setTimeout(r, 500));
  }
  return read();
};

test('change: staff propose a longer trip, the renter signs the amendment and pays; a second proposal is declined; the cleaning block follows and is removed', async ({ browser }, info) => {
  test.setTimeout(240_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  try {
    await sql`delete from app.rate_limit_hits`;
    const admin = await mkUser(sql, 'admin');
    const renter = await mkUser(sql, 'renter');
    const car = await freeCar(sql, 150 + (phone ? 0 : 12), 3);
    const req = await seedRequest(sql, renter, car.id, car.from, car.to);
    await confirmBooking(sql, req.booking_id, admin.id);
    const [before] = await sql`select return_at, renter_due_at_booking_cents::int due from bookings where id = ${req.booking_id}`;
    // the cleaning block is there from the confirmation, right after the return
    const [blk] = await sql`select starts_at = ${before!.return_at} at_return, extract(epoch from ends_at - starts_at)::int / 60 mins from vehicle_calendar_blocks where booking_id = ${req.booking_id} and source = 'turnaround' and removed_at is null`;
    expect(blk).toMatchObject({ at_return: true });

    // 1. an Admin proposes one more day
    const desk = await ctx(browser, phone);
    const errors = watch(desk);
    await signIn(desk, admin.email, '/admin');
    await desk.goto(`/admin/bookings/${req.booking_number}?tab=changes`);
    await expect(desk.getByTestId('propose-card')).toBeVisible();
    const later = new Date(new Date(before!.return_at as string).getTime() + 86_400_000);
    // the date and time fields are in the browser's own time zone (staff are in Toronto; CI runs in UTC)
    const local = await desk.evaluate((ms) => { const d = new Date(ms); const p = (n: number) => String(n).padStart(2, '0'); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`; }, later.getTime());
    await desk.locator('#pc-return').fill(local);
    await desk.getByTestId('propose-preview-btn').click();
    await expect(desk.getByTestId('propose-preview')).toContainText('Difference for the renter', { timeout: 15_000 });
    await desk.locator('#pc-note').fill('The next renter moved their trip, so you can keep the car one more day.');
    await check(desk, 'admin propose change');
    await desk.getByTestId('propose-send').click();
    await expect(desk.getByText('Sent to the renter. The booking moves when they accept.')).toBeVisible({ timeout: 15_000 });
    const [cr] = await sql`select id, status, accept_by is not null deadline, total_difference_cents::int diff from booking_change_requests where booking_id = ${req.booking_id} order by created_at desc limit 1`;
    expect(cr).toMatchObject({ status: 'proposed', deadline: true });
    expect(cr!.diff).toBeGreaterThan(0);
    const [still] = await sql`select return_at from bookings where id = ${req.booking_id}`;
    expect(new Date(still!.return_at as string).getTime()).toBe(new Date(before!.return_at as string).getTime());
    expect((await outbox(sql, 'renter_change_proposed', { booking: req.booking_id })).length).toBe(1);

    // 2. the renter reviews and signs (typed name; the statement is required), the difference is charged
    const rp = await ctx(browser, phone);
    const rerrors = watch(rp);
    await signIn(rp, renter.email, '/account');
    await rp.goto(`/account/bookings/${req.booking_number}`);
    await expect(rp.getByTestId('change-waiting')).toContainText('We suggest a change to your booking');
    await check(rp, 'renter booking with a proposal');
    await rp.getByTestId('change-waiting').getByRole('link', { name: 'Review and answer' }).click();
    await rp.waitForURL(/\/change$/);
    await expect(rp.getByTestId('change-rows')).toContainText('Return');
    await expect(rp.getByTestId('change-reason')).toContainText('keep the car one more day');
    await expect(rp.getByTestId('change-money')).toContainText('Extra to pay');
    await check(rp, 'renter change page');
    // the amendment says CarmaCars signs it at the moment the renter signs (the legal review, 0053); no staff member is named as signer
    await expect(rp.locator('body')).toContainText('CarmaCars signs this amendment electronically at the moment the Renter signs it.');
    await rp.getByTestId('change-accept').click();
    await expect(rp.getByText('Tick the statement to sign.').first()).toBeVisible();
    await rp.getByTestId('amend-agree').check();
    await rp.getByTestId('amend-mode').click();
    await rp.getByTestId('amend-typed').fill('Riley Renter');
    await rp.getByTestId('change-accept').click();
    await rp.waitForURL(/\?changed=1/, { timeout: 30_000 });
    await expect(rp.getByTestId('changed-panel')).toContainText('Booking updated');
    await check(rp, 'renter booking changed');
    // 0077: the signed amendment copy is made by a background job, within seconds
    await expect.poll(async () => (await sql`select count(*)::int n from booking_amendments where change_request_id = ${cr!.id} and status = 'signed' and signed_document_id is not null`)[0]!.n, { timeout: 60_000 }).toBe(1);
    const [after] = await sql`select b.return_at, (select status from booking_change_requests where id = ${cr!.id}) st,
        (select string_agg(p.status || ':' || p.amount_cents, ',') from payments p where p.booking_id = b.id and p.purpose <> 'booking_total') pay,
        (select status || '/' || (signed_document_id is not null) from booking_amendments where change_request_id = ${cr!.id} and status <> 'voided') amend
      from bookings b where b.id = ${req.booking_id}`;
    expect(new Date(after!.return_at as string).getTime()).toBe(later.getTime());
    expect(after).toMatchObject({ st: 'applied', amend: 'signed/true' });
    const [cs] = await sql`select r.method, r.signer_role, r.signer_title, r.signer_name from booking_amendments a join signature_records r on r.id = a.countersignature_record_id
      where a.change_request_id = ${cr!.id} and a.status = 'signed'`;
    // countersigned by the signing officer under the standing authorization, not by the staff member (0053)
    expect(cs, 'CarmaCars countersigned the amendment').toMatchObject({ method: 'automatic', signer_role: 'carmacars', signer_title: 'Director', signer_name: 'Abbas Al-Mashita' });
    expect(after!.pay).toBe(`succeeded:${cr!.diff}`);
    // the signed amendment downloads as a PDF from the booking's documents
    const link = rp.getByTestId('doc-rental_amendment').last();
    // the signed copy is made by a job right after signing (0077): wait for it rather than reading the copy opened before
    let pdf = await rp.request.get(await link.getAttribute('href') as string);
    let text = '';
    for (let i = 0; i < 20; i++) {
      pdf = await rp.request.get(await link.getAttribute('href') as string);
      if (pdf.status() === 200) { text = await pdfText(await pdf.body()); if (/Signed electronically for [^,]+, operating as CarmaCars/.test(text)) break; }
      await rp.waitForTimeout(1500);
    }
    expect(pdf.status()).toBe(200);
    expect((await pdf.body()).subarray(0, 4).toString()).toBe('%PDF');
    // the signed PDF: the corporate countersignature in the signing officer's name, with the approved wording, in the
    // signature block and the record; the staff member only as "Proposed by" (the legal review, section 6)
    // in the signature block and in the signature record
    expect(text.match(/Signed electronically for [^,]+, operating as CarmaCars, by Abbas Al-Mashita, Director, under a standing authorization dated [A-Z][a-z]+ \d{1,2}, \d{4}\./g)?.length ?? 0).toBeGreaterThanOrEqual(2);
    expect(text).toContain('CarmaCars signs this amendment electronically at the moment the Renter signs it.');
    expect(text).toMatch(/Proposed by /);
    expect(text).not.toContain('Signed electronically for CarmaCars ');
    await rp.goto('/account/documents');
    await expect(rp.locator('table')).toContainText('Signed booking amendment');
    // the renter has the signed copy by email; the owner hears the car is booked longer; the cleaning block moved
    const applied = await outbox(sql, 'renter_change_applied', { booking: req.booking_id });
    expect(applied.length).toBe(1);
    expect((await outbox(sql, 'owner_booking_changed', { booking: req.booking_id })).length).toBeGreaterThanOrEqual(1);
    const [moved] = await sql`select id, starts_at from vehicle_calendar_blocks where booking_id = ${req.booking_id} and source = 'turnaround' and removed_at is null`;
    expect(new Date(moved!.starts_at as string).getTime()).toBe(later.getTime());

    // 3. a second proposal (a later pickup), declined by the renter: nothing moves
    await sql`select app.propose_booking_change(${admin.id}::uuid, ${sql.json({ booking: req.booking_id, pickup_at: new Date(Date.parse(`${car.from}T14:00:00Z`) + 3 * 3_600_000).toISOString(), note: 'Could you pick up three hours later?' })})`;
    await rp.goto(`/account/bookings/${req.booking_number}/change`);
    await rp.getByTestId('change-decline-open').click();
    await rp.locator('#pt-decline-reason').fill('I need the car in the morning.');
    await rp.getByTestId('change-decline').click();
    await rp.waitForURL(/\?declined=1/, { timeout: 15_000 });
    await expect(rp.getByTestId('declined-panel')).toContainText('Your booking stays as it was.');
    // buttons fade in after the navigation: check the contrast once they are settled, not mid-transition
    await rp.mouse.move(0, 0);
    await rp.waitForTimeout(400);
    await check(rp, 'renter change declined');
    const [dec] = await sql`select status, renter_declined_at is not null d from booking_change_requests where booking_id = ${req.booking_id} order by created_at desc limit 1`;
    expect(dec).toMatchObject({ status: 'declined', d: true });

    // 4. the cleaning block on the car's calendar, removed by the Admin with a reason
    await desk.goto(`/admin/vehicles/${car.id}?tab=calendar&start=${car.to}`);
    // a phone opens the agenda by itself; a desktop shows the timeline with an "Agenda" switch
    await expect(desk.getByTestId('master-calendar')).toBeVisible();
    const agenda = desk.getByRole('button', { name: 'Agenda' });
    if (await agenda.isVisible()) await agenda.click();
    await desk.getByTestId('cal-agenda').getByRole('button', { name: new RegExp(`Cleaning after booking ${req.booking_number}|cleaning`, 'i') }).first().click();
    await expect(desk.getByTestId('cleaning-block')).toBeVisible();
    await check(desk, 'admin vehicle calendar cleaning block');
    await desk.locator('#cal-rm').fill('Cleaned the same evening');
    await desk.getByTestId('block-remove').click();
    await expect.poll(async () => (await sql`select removed_at is not null r from vehicle_calendar_blocks where id = ${moved!.id}`)[0]!.r, { timeout: 15_000 }).toBe(true);
    expect(clean(errors)).toEqual([]);
    expect(clean(rerrors)).toEqual([]);
    await desk.context().close(); await rp.context().close();
  } finally { await sql.end(); }
});

test('drivers and accounts: new signing links from the renter and from customer service; an earlier request is attached after sign-in', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  try {
    await sql`delete from app.rate_limit_hits`;
    const admin = await mkUser(sql, 'admin');
    const cs = await mkUser(sql, 'va', { va: 'cs' });
    const renter = await mkUser(sql, 'renter');
    const dEmail = `driver.ops.${tag()}@example.test`;
    const car = await freeCar(sql, 175 + (phone ? 0 : 12), 3);
    const req = await seedRequest(sql, renter, car.id, car.from, car.to, [{ full_name: 'Dana Driver', date_of_birth: '1990-05-05', email: dEmail, licence_class: 'G', licence_issuer: 'ON' }]);
    await confirmBooking(sql, req.booking_id, admin.id);
    const [sg] = await sql`select s.id from rental_agreement_signers s join rental_agreements a on a.id = s.agreement_id where a.booking_id = ${req.booking_id} and s.signer_role = 'additional_driver'`;
    expect(sg).toBeTruthy();

    // the renter sends a new link: the driver is emailed it, and it opens the signing page
    const rp = await ctx(browser, phone);
    const errors = watch(rp);
    await signIn(rp, renter.email, '/account');
    await rp.goto(`/account/bookings/${req.booking_number}`);
    const card = rp.getByTestId(`driver-link-${sg!.id}`);
    await expect(card).toContainText('Link valid until');
    await check(rp, 'renter booking driver link');
    await card.getByTestId('driver-link-resend').click();
    await expect(card).toContainText(`New link emailed to ${dEmail}`, { timeout: 15_000 });
    const first = await outbox(sql, 'renter_driver_link', { to: dEmail });
    expect(first.length).toBe(1);
    const url1 = new URL((first[0]!.payload as { sign_url: string }).sign_url);
    await rp.goto(url1.pathname);
    await expect(rp.getByRole('heading', { level: 1 })).toContainText('Accept the rental agreement, Dana');

    // customer service sends another: the renter's link stops working, the new one works
    const va = await ctx(browser, phone);
    const verrors = watch(va);
    await signIn(va, cs.email, '/va');
    await va.goto(`/va/bookings/${req.booking_number}?tab=overview`);
    await expect(va.getByTestId('driver-links')).toContainText('Dana Driver');
    await check(va, 'va driver links');
    await va.getByTestId(`staff-driver-resend-${sg!.id}`).click();
    await expect(va.getByTestId('driver-links')).toContainText(`Emailed to ${dEmail}`, { timeout: 15_000 });
    const second = await outbox(sql, 'renter_driver_link', { to: dEmail }, 2);
    expect(second.length).toBe(2);
    await rp.goto(url1.pathname);
    await expect(rp.getByTestId('driver-link-expired')).toContainText('This link has expired');
    await check(rp, 'expired driver link');
    await rp.goto(new URL((second[1]!.payload as { sign_url: string }).sign_url).pathname);
    await expect(rp.getByRole('heading', { level: 1 })).toContainText('Accept the rental agreement, Dana');
    const [cnt] = await sql`select link_version, link_sent_count, link_sent_by = ${cs.id} by_cs from rental_agreement_signers where id = ${sg!.id}`;
    expect(cnt).toMatchObject({ link_version: 3, link_sent_count: 2, by_cs: true });

    // a request made as a guest, then an account with the same address: attached after a verified sign-in
    const gEmail = `guest.ops.${tag()}@example.test`;
    const car2 = await freeCar(sql, 200 + (phone ? 0 : 12), 2);
    const guest = await seedRequest(sql, { id: null, email: gEmail }, car2.id, car2.from, car2.to);
    // the request made a record for the address; the account is opened on that record (as createForRecord does)
    const [rec] = await sql`select id from users where lower(email) = ${gEmail}`;
    await sql`insert into local_auth.users (id, email, password_hash) values (${rec!.id}, ${gEmail}, ${hash(PW)})`;
    const g = { id: rec!.id as string, email: gEmail };
    const gp = await ctx(browser, phone);
    const gerrors = watch(gp);
    await signIn(gp, g.email, '/account');
    await gp.goto('/account');
    await expect(gp.getByTestId('linked-notice')).toContainText(guest.booking_number);
    await expect(gp.locator('main')).toContainText(guest.booking_number);
    await check(gp, 'account linked notice');
    await gp.getByTestId('linked-notice').getByRole('button', { name: 'Got it' }).click();
    await expect(gp.getByTestId('linked-notice')).toHaveCount(0, { timeout: 15_000 });
    const [lk] = await sql`select (select user_id from renters r join bookings b on b.renter_id = r.id where b.id = ${guest.booking_id}) = ${g.id} mine, (select email_verified_at is not null from users where id = ${g.id}) verified`;
    expect(lk).toMatchObject({ mine: true, verified: true });
    expect(clean(errors)).toEqual([]); expect(clean(verrors)).toEqual([]); expect(clean(gerrors)).toEqual([]);
    await rp.context().close(); await va.context().close(); await gp.context().close();
  } finally { await sql.end(); }
});

test('listings and owners: a possible duplicate is cleared; Form D is sent back, uploaded again and approved; field staff shoot the listing photos', async ({ browser }, info) => {
  test.setTimeout(240_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  try {
    await sql`delete from app.rate_limit_hits`;
    const admin = await mkUser(sql, 'admin');
    const cs = await mkUser(sql, 'va', { va: 'cs' });
    // two cars whose VINs are one character apart
    const v1 = realVin('KNDJ');
    const a = await mkOwnerCar(sql, { year: 2021, make: 'Kia', model: 'Soul', colour: `Blue ${tag()}`, vin: v1 });
    const v2 = v1.slice(0, 16) + (v1[16] === 'A' ? 'B' : 'A');
    const b = await mkOwnerCar(sql, { year: 2020, make: 'Mazda', model: 'CX-5', colour: `Red ${tag()}`, vin: v2 });
    const [fl] = await sql`select id, blocking from listing_similarity_flags where vehicle_id = ${b.car} and other_vehicle_id = ${a.car} and kind = 'vin' and status = 'open'`;
    expect(fl).toMatchObject({ blocking: true });

    const desk = await ctx(browser, phone);
    const errors = watch(desk);
    await signIn(desk, admin.email, '/admin');
    await desk.goto('/admin/similar-cars');
    const row = desk.getByTestId('similar-cars').locator('tr', { hasText: v2 });
    await expect(row).toContainText('VIN one character apart');
    await check(desk, 'admin similar cars');
    await act(desk, row.getByTestId('flag-clear-vin'), 'flag-clear-vin', async (d) => { await d.getByLabel('What you checked').fill('Different VINs on the two ownership permits.'); });
    await expect.poll(async () => (await sql`select status from listing_similarity_flags where id = ${fl!.id}`)[0]!.status, { timeout: 15_000 }).toBe('cleared');

    // Form D: the owner downloads it pre-filled, uploads the signed scan; customer service sends it back, then approves
    const op = await ctx(browser, phone);
    const wit = `Wanda ${Array.from({ length: 8 }, () => "abcdefghjkmnpqrstuvwxyz"[Math.floor(Math.random() * 23)]).join("").replace(/^./, (c) => c.toUpperCase())}`;
    const oerrors = watch(op);
    await signIn(op, a.user.email, '/owner');
    await op.goto('/owner/documents');
    const form = op.getByTestId('witnessed-D1');
    await expect(form).toContainText('To do');
    const dl = await op.request.get(await form.getByTestId('witnessed-download').getAttribute('href') as string);
    expect(dl.status()).toBe(200);
    expect((await dl.body()).subarray(0, 4).toString()).toBe('%PDF');
    await check(op, 'owner documents forms');
    await form.getByLabel(/^First witness|^Witness/).fill(wit);
    const second = form.getByLabel('Second witness, full name');
    if (await second.count()) await second.fill('Walter Witness');
    await form.getByTestId('witnessed-file').setInputFiles({ name: 'form-d.pdf', mimeType: 'application/pdf', buffer: PDF });
    await expect(form).toContainText('We review it within one business day', { timeout: 15_000 });
    const [up] = await sql`select id, status from owner_agreement_forms where owner_id = ${a.owner} and form_code = 'D1' order by uploaded_at desc limit 1`;
    expect(up!.status).toBe('uploaded');
    expect((await sql`select count(*)::int n from app_events where code = 'staff_owner_form_uploaded' and entity_id = ${up!.id}`)[0]!.n).toBe(1);

    const va = await ctx(browser, phone);
    const verrors = watch(va);
    await signIn(va, cs.email, '/va');
    await va.goto('/va/owner-forms');
    const frow = va.getByTestId('owner-forms').locator('tr', { hasText: wit }).first();
    await expect(frow).toContainText('Form D');
    await check(va, 'va owner forms');
    await act(va, frow.getByTestId('form-reject-D1'), 'form-reject-D1', async (d) => { await d.getByLabel('What to fix (the owner reads this)').fill('The second page is missing the witness signature.'); });
    await expect.poll(async () => (await sql`select status from owner_agreement_forms where id = ${up!.id}`)[0]!.status, { timeout: 15_000 }).toBe('rejected');
    expect((await outbox(sql, 'owner_form_rejected', { to: a.user.email })).length).toBe(1);
    await op.reload();
    await expect(form).toContainText('The second page is missing the witness signature.');
    await check(op, 'owner form sent back');
    await form.getByLabel(/^First witness|^Witness/).fill(wit);
    if (await second.count()) await second.fill('Walter Witness');
    await form.getByTestId('witnessed-file').setInputFiles({ name: 'form-d-2.pdf', mimeType: 'application/pdf', buffer: PDF });
    await expect(form).toContainText('We review it within one business day', { timeout: 15_000 });
    await va.reload();
    const again = va.getByTestId('owner-forms').locator('tr', { hasText: wit }).filter({ has: va.getByTestId('form-approve-D1') }).first();
    await act(va, again.getByTestId('form-approve-D1'), 'form-approve-D1');
    await expect.poll(async () => (await sql`select status from owner_agreement_forms where owner_id = ${a.owner} and form_code = 'D1' order by uploaded_at desc limit 1`)[0]!.status, { timeout: 15_000 }).toBe('approved');
    expect((await outbox(sql, 'owner_form_approved', { to: a.user.email })).length).toBe(1);
    await op.reload();
    await expect(form).toContainText('Approved');

    // a field photographer: the photo-shoot job takes the listing photos with the camera and submits them
    const field = await mkUser(sql, 'field');
    const job = randomUUID();
    await sql`insert into field_jobs (id, kind, vehicle_id, assigned_to, scheduled_at, status) values (${job}, 'photo_shoot', ${b.car}, ${field.id}, now(), 'in_progress')`;
    const fp = await ctx(browser, true);
    const ferrors = watch(fp);
    await signIn(fp, field.email, '/field');
    await fp.goto(`/field/jobs/${job}`);
    await fp.getByTestId('listing-start').click();
    await expect(fp.getByTestId('listing-capture')).toBeVisible({ timeout: 20_000 });
    await check(fp, 'field photo shoot');
    const shots = await sql`select code from listing_shot_types where required and is_active order by seq`;
    for (const s of shots) {
      await expect(fp.getByTestId(`shot-${s.code}`)).toHaveAttribute('capture', 'environment');
      await fp.getByTestId(`shot-${s.code}`).setInputFiles({ name: `${s.code}.png`, mimeType: 'image/png', buffer: PNG });
      await expect(fp.locator(`[data-shot="${s.code}"]`)).toContainText('Added', { timeout: 20_000 });
    }
    await expect(fp.getByRole('progressbar')).toHaveAttribute('aria-valuenow', String(shots.length));
    await fp.getByTestId('listing-submit').click();
    await expect(fp.getByRole('status').filter({ hasText: 'Submitted' })).toBeVisible({ timeout: 20_000 });
    const [intake] = await sql`select i.submitted_at is not null submitted, (select count(*)::int from vehicle_photos p where p.vehicle_id = ${b.car} and p.content_sha256 is not null) hashed
      from listing_intakes i where i.vehicle_id = ${b.car}`;
    expect(intake!.submitted).toBe(true);
    expect(intake!.hashed).toBeGreaterThanOrEqual(shots.length);
    expect(clean(errors)).toEqual([]); expect(clean(oerrors)).toEqual([]); expect(clean(verrors)).toEqual([]); expect(clean(ferrors)).toEqual([]);
    await desk.context().close(); await op.context().close(); await va.context().close(); await fp.context().close();
  } finally { await sql.end(); }
});
