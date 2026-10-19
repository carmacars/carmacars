import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Migration 0032 end to end, with the fake providers of the local stack (fake VIN decoder, fake copy
// model, fake photo editor, fake payments):
// - an owner lists a car on a phone: starts the listing, takes the 14 photos, submits; the worker decodes,
//   drafts the copy and processes the photos; an Admin approves at 1440 and the car is live on the site
// - a failed step shows on the assistant's screen (phone) with its error and a Retry that runs it again
// - an Admin issues an approved refund through the payments module, once
// - the guided Deposit settlement holds back an amount with its reason
// - a single toll entry keeps the uploaded notice
// - an insurer invoice is emailed with a 7-day link, and opens as a PDF
// - a renter downloads a receipt on a phone; the signed email link opens it without a session; an altered
//   or expired link does not
// - an owner and an investor download their statement PDFs; the investor's yearly summary
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/18122211(?! Canada Inc\.?,? (?:operating as|o\/a) CarmaCars)|Canada Inc\b(?!\.?,? (?:operating as|o\/a) CarmaCars)/i, 'numbered company name (the payee "<legal name>, operating as CarmaCars" is allowed)'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
const LINK_KEY = process.env.LINK_SIGNING_KEY ?? 'local-link-signing-key-change-me-32-chars';
type Sql = ReturnType<typeof db>;
// a 1 x 1 PNG: the capture screen re-encodes it as JPEG before the upload, as it does with a camera photo
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
const PDF = Buffer.from('%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n');

async function check(page: Page, where: string, opts: { copy?: boolean } = {}) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  if (opts.copy === false) return;
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const vp = (phone: boolean) => (phone ? { width: 375, height: 812 } : { width: 1440, height: 900 });
const tag = () => `${Date.now().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`;
const VIN_CHARS = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789';
const vin = (prefix: string) => prefix + Array.from({ length: 17 - prefix.length }, () => VIN_CHARS[Math.floor(Math.random() * VIN_CHARS.length)]).join('');

async function mkUser(sql: Sql, role: 'admin' | 'va' | 'renter' | 'owner', extra: { va?: string } = {}) {
  const id = randomUUID(); const email = `${role}.pd.${tag()}@example.test`;
  const name = { admin: 'Ada Admin', va: 'Val Assistant', renter: 'Riley Renter', owner: 'Olive Owner' }[role];
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, ${name}, null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${extra.va!})`;
  return { id, email };
}

/** An owner with one enrolled car that is not on the website yet (as tests/12's fixtures build one). */
async function mkOwnerCar(sql: Sql) {
  const u = await mkUser(sql, 'owner');
  const owner = randomUUID(); const car = randomUUID(); const agr = randomUUID(); const t = tag().toUpperCase();
  await sql`insert into owners (id, user_id, owner_type, legal_name, status, email, phone) values (${owner}, ${u.id}, 'individual', 'Olive Owner', 'active', ${u.email}, '416-555-0100')`;
  await sql`insert into owner_agreements (id, owner_id, kind, agreement_number, agreement_date, status) values (${agr}, ${owner}, 'enrollment', ${`EA-${t}`}, current_date - 30, 'signed')`;
  await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, fleet_policy_added_on, enrollment_date, colour)
            values (${car}, ${owner}, ${`F-${t}`}, 2022, 'Toyota', 'Corolla', ${vin('2T1')}, ${`PD${t.slice(-5)}`}, 'standard', 'ready_to_list', 'managed', 'transfer', true, current_date - 20, current_date - 20, 'Grey')`;
  await sql`insert into vehicle_schedules (vehicle_id, owner_agreement_id, schedule_number, vehicle_number, held_by, title_status, management_mode, onboarding_method,
              insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps, enrollment_date, signed_at)
            values (${car}, ${agr}, ${`VS-${t}`}, 1, 'individual', 'owned_outright', 'managed', 'transfer', 45000, 2500, 10000, 3500, current_date - 20, now())`;
  await sql`insert into vehicle_fee_history (vehicle_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from) values (${car}, 'signed_schedule', 45000, 2500, 3500, current_date - 20)`;
  await sql`insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
            values (${car}, 6900, 7900, 39000, 140000, 250, 25, 50000, 7500, 7500, now() - interval '20 days')`;
  // seats and transmission as the owner application records them (the sample decoder gives neither)
  await sql`select app.ensure_listing(${car}::uuid)`;
  await sql`update vehicle_listings set seats = 5, transmission = 'automatic' where vehicle_id = ${car}`;
  return { user: u, owner, car };
}

/** A closed booking of a seeded car for a new renter, with its card payment and the processor's ids. */
async function mkPaidBooking(sql: Sql, status: 'closed' | 'returned' = 'closed') {
  const r = await mkUser(sql, 'renter');
  const [renter] = await sql`insert into renters (user_id, legal_name, date_of_birth, mobile, email, identity_status)
                             values (${r.id}, 'Riley Renter', date '1990-05-05', '647-555-0199', ${r.email}, 'verified')
                             on conflict do nothing returning id`;
  const [car] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id where l.status = 'published' order by random() limit 1`;
  const id = randomUUID(); const pay = randomUUID(); const n = `PD-${tag().toUpperCase().slice(-8)}`;
  await sql`insert into bookings (id, booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
              handed_over_at, checked_in_at, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days,
              rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km, deposit_cents,
              subtotal_at_booking_cents, hst_at_booking_cents, total_due_at_booking_cents)
            values (${id}, ${n}, 'standard', ${status}, ${car!.id}, ${renter!.id}, now() - interval '20 days', now() - interval '10 days', now() - interval '7 days', now() - interval '7 days', 3,
              now() - interval '10 days', now() - interval '7 days', 10000, 12000, 56000, 180000, 'daily', 3, 0, 30000, 0, 200, 600, 35, 100000, 30000, 3900, 33900)`;
  await sql`insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, card_brand, card_last4)
            values (${pay}, ${id}, ${renter!.id}, 'booking_total', 'charge', 'card', 33900, 'succeeded', now() - interval '20 days', 'visa', '4242')`;
  await sql`insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id) values (${pay}, 'stripe', ${`pi_e2e_${tag()}`}, ${`ch_e2e_${tag()}`})`;
  await sql`insert into booking_line_items (booking_id, charge_type, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage, payment_id)
            select ${id}, 'rental_charge', 1, 30000, 30000, true, 3900, f.revenue_class, f.stage, ${pay} from fee_types f where f.code = 'rental_charge'`;
  return { renter: r, renterId: renter!.id as string, booking: id, number: n, payment: pay };
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
  const c = await browser.newContext({ viewport: vp(phone), hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
const b64url = (b: Buffer) => b.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
/** The token the email sender signs (supabase/functions/send-outbox): purpose "doc", 7 days. */
function docToken(k: string, key: string, ttl = 7 * 86400) {
  const body = b64url(Buffer.from(JSON.stringify({ k, key, p: 'doc', exp: Math.floor(Date.now() / 1000) + ttl })));
  return `${body}.${b64url(createHmac('sha256', LINK_KEY).update(body).digest())}`;
}
async function waitFor<T>(fn: () => Promise<T>, ok: (v: T) => boolean, ms = 45_000): Promise<T> {
  const end = Date.now() + ms; let v = await fn();
  while (!ok(v) && Date.now() < end) { await new Promise((r) => setTimeout(r, 750)); v = await fn(); }
  return v;
}
const onlyDesktop = () => test.skip(test.info().project.name !== 'desktop-1440', 'one run: the test opens its own phone and desktop pages');

test('listing: an owner lists a car on a phone; the pipeline drafts and edits; an Admin approves at 1440; the car is live', async ({ browser }) => {
  onlyDesktop();
  test.setTimeout(240_000);
  const sql = db();
  try {
    const { user, car } = await mkOwnerCar(sql);
    const admin = await mkUser(sql, 'admin');
    const phone = await ctx(browser, true);
    const errors = watch(phone);
    await signIn(phone, user.email, '/owner', `/owner/vehicles/${car}`);
    await phone.goto(`/owner/vehicles/${car}`);
    await phone.getByTestId('listing-start').click();
    await expect(phone.getByTestId('listing-capture')).toBeVisible({ timeout: 20_000 });
    await check(phone, 'owner capture 375');
    const shots = await sql`select code from listing_shot_types where required and is_active order by seq`;
    for (const s of shots) {
      await phone.getByTestId(`shot-${s.code}`).setInputFiles({ name: `${s.code}.png`, mimeType: 'image/png', buffer: PNG });
      await expect(phone.locator(`[data-shot="${s.code}"]`)).toContainText('Added', { timeout: 20_000 });
    }
    await expect(phone.getByTestId('listing-submit')).toBeEnabled();
    await phone.getByTestId('listing-submit').click();
    await expect(phone.getByRole('status').filter({ hasText: 'Submitted' })).toBeVisible({ timeout: 20_000 });
    // the worker ran right after the submit (fake decoder, fake model, fake photo editor)
    const [intake] = await sql`select id from listing_intakes where vehicle_id = ${car}`;
    const state = await waitFor(async () => (await sql`select state from listing_intakes where id = ${intake!.id}`)[0]!.state as string, (s) => s === 'needs_review');
    expect(state).toBe('needs_review');
    const [d] = await sql`select model, prompt_version, headline, needs_rewrite from listing_drafts where intake_id = ${intake!.id}`;
    expect([d!.model, d!.prompt_version, d!.needs_rewrite]).toEqual(['fake-draft-v1', 'listing-draft-v1', false]);
    const [c] = await sql`select count(*)::int as n from provider_calls where intake_id = ${intake!.id}`;
    expect(c!.n).toBeGreaterThan(14);
    await phone.reload();
    await expect(phone.getByTestId('listing-progress')).toHaveAttribute('data-state', 'needs_review');
    await check(phone, 'owner progress 375');
    expect(errors.filter((e) => !/favicon|Failed to load resource/.test(e))).toEqual([]);

    const desk = await ctx(browser, false);
    await signIn(desk, admin.email, '/admin', `/admin/listings/${intake!.id}`);
    await desk.goto('/admin/listings');
    await expect(desk.getByTestId('listings')).toContainText('2022 Toyota Corolla');
    await desk.goto(`/admin/listings/${intake!.id}`);
    await expect(desk.getByTestId('listing-progress')).toContainText('Ready for review');
    await check(desk, 'admin listing review 1440');
    // every public photo needs a plate decision before publishing (0042): none of the test photos shows a plate
    await desk.getByTestId('plates-none-visible').click();
    await desk.getByTestId('plates-none-visible-yes').click();
    await expect(desk.getByTestId('plates-none-visible')).toHaveCount(0, { timeout: 20_000 });
    await desk.getByTestId('listing-approve').click();
    await expect(desk.getByRole('status').filter({ hasText: 'Approved and published' })).toBeVisible({ timeout: 20_000 });
    const [l] = await sql`select status, slug, headline from vehicle_listings where vehicle_id = ${car}`;
    expect(l!.status).toBe('published');
    const res = await desk.goto(`/cars/${l!.slug}`);
    expect(res!.status()).toBe(200);
    await expect(desk.locator('h1')).toContainText('Toyota Corolla');
    // off the site again through the admin screen (the public pages are rebuilt), so the fleet pages of the
    // other tests see the seeded cars only
    await desk.goto(`/admin/listings/${intake!.id}`);
    await desk.getByRole('button', { name: 'Unlist' }).first().click();
    await desk.getByRole('dialog').getByLabel('Reason').fill('End to end test car');
    await desk.getByRole('dialog').getByRole('button', { name: 'Unlist' }).click();
    await expect.poll(async () => (await sql`select status from vehicle_listings where vehicle_id = ${car}`)[0]!.status, { timeout: 15_000 }).toBe('unpublished');
    await phone.context().close(); await desk.context().close();
  } finally { await sql.end(); }
});

test('listing: a failed step shows on the assistant\'s phone with its error, and Retry runs it again', async ({ browser }) => {
  onlyDesktop();
  test.setTimeout(120_000);
  const sql = db();
  try {
    const { car } = await mkOwnerCar(sql);
    const va = await mkUser(sql, 'va', { va: 'fleet' });
    const [s] = await sql`select app.start_listing_intake(${va.id}::uuid, ${sql.json({ vehicle_id: car })}) r`;
    const intake = (s!.r as { intake_id: string }).intake_id;
    const [job] = await sql`select (j ->> 'id')::uuid as id from jsonb_array_elements((public.server_listing_claim('e2e', 50)) -> 'jobs') j where j ->> 'intake_id' = ${intake}`;
    await sql`select public.server_listing_result(${job!.id}::uuid, ${sql.json({ ok: false, provider: 'vpic', error: 'The VIN decoder did not answer', retryable: false })})`;
    const phone = await ctx(browser, true);
    await signIn(phone, va.email, '/va', `/va/listings/${intake}`);
    await phone.goto(`/va/listings/${intake}`);
    await expect(phone.getByTestId('listing-problems')).toContainText('The VIN decoder did not answer');
    await check(phone, 'va listing failure 375');
    await phone.getByTestId('listing-retry').first().click();
    const st = await waitFor(async () => (await sql`select status from listing_jobs where id = ${job!.id}`)[0]!.status as string, (x) => x === 'succeeded');
    expect(st).toBe('succeeded');
    await phone.reload();
    await expect(phone.getByTestId('listing-problems')).toHaveCount(0);
    await phone.context().close();
  } finally { await sql.end(); }
});

test('money: an Admin issues an approved refund through the payments module, once', async ({ browser }) => {
  onlyDesktop();
  const sql = db();
  try {
    const admin = await mkUser(sql, 'admin');
    const b = await mkPaidBooking(sql);
    const [rf] = await sql`insert into refunds (booking_id, payment_id, reason, amount_cents, status, requested_by, approved_by, approved_at) values (${b.booking}, ${b.payment}, 'goodwill', 2500, 'approved', ${admin.id}, ${admin.id}, now()) returning id`;
    const page = await ctx(browser, false);
    await signIn(page, admin.email, '/admin', '/admin/money?tab=refunds');
    await page.goto('/admin/money?tab=refunds');
    const row = page.getByTestId('refunds').locator('tr', { hasText: b.number });
    await row.getByTestId('refund-issue').click();
    await check(page, 'refund confirm 1440');
    await page.getByTestId('refund-issue-submit').click();
    const status = await waitFor(async () => (await sql`select status from refunds where id = ${rf!.id}`)[0]!.status as string, (x) => x === 'paid', 20_000);
    expect(status).toBe('paid');
    const pays = await sql`select p.kind, p.status, p.amount_cents, d.processor_refund_id from payments p join payment_processor_details d on d.payment_id = p.id where p.parent_payment_id = ${b.payment}`;
    expect(pays.length).toBe(1);
    expect([pays[0]!.kind, pays[0]!.status, Number(pays[0]!.amount_cents)]).toEqual(['refund', 'succeeded', 2500]);
    expect(String(pays[0]!.processor_refund_id)).toMatch(/^re_/);
    await page.reload();
    await expect(page.getByTestId('refunds').locator('tr', { hasText: b.number }).getByTestId('refund-issue')).toHaveCount(0);
    await page.context().close();
  } finally { await sql.end(); }
});

test('money: the guided Deposit settlement holds back an amount with its reason and returns the rest', async ({ browser }) => {
  onlyDesktop();
  const sql = db();
  try {
    const admin = await mkUser(sql, 'admin');
    const b = await mkPaidBooking(sql, 'returned');
    const hold = randomUUID();
    await sql`insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at) values (${hold}, ${b.booking}, ${b.renterId}, 'deposit', 'charge', 'card', 100000, 'succeeded', now() - interval '10 days')`;
    await sql`insert into deposits (booking_id, amount_cents, method, status, hold_payment_id, taken_at, captured_cents) values (${b.booking}, 100000, 'charged', 'captured', ${hold}, now() - interval '10 days', 100000)`;
    await sql`insert into booking_statements (booking_id, statement_number, kind) values (${b.booking}, ${`${b.number}-S1`}, 'check_in')`;
    const page = await ctx(browser, false);
    await signIn(page, admin.email, '/admin', `/admin/bookings/${b.number}?tab=money`);
    await page.goto(`/admin/bookings/${b.number}?tab=money`);
    await page.getByTestId('deposit-settle').click();
    await expect(page.getByTestId('deposit-form')).toBeVisible();
    await expect(page.getByTestId('deposit-release')).toContainText('$1,000.00');
    await page.getByLabel('Hold back ($)').fill('200');
    await page.getByLabel('Why').selectOption('pending_ticket');
    await page.getByLabel('What it is (claim, toll or ticket)').fill('Parking ticket expected from the City');
    await expect(page.getByTestId('deposit-release')).toContainText('$800.00');
    await check(page, 'deposit settlement 1440');
    await page.getByTestId('deposit-submit').click();
    await expect(page.getByTestId('deposit-form').getByRole('status')).toBeVisible({ timeout: 20_000 });
    const [d] = await sql`select held_back_cents, held_back_reason, released_cents from deposits where booking_id = ${b.booking}`;
    expect(Number(d!.held_back_cents)).toBe(20000);
    expect(String(d!.held_back_reason)).toContain('Parking ticket expected');
    await page.context().close();
  } finally { await sql.end(); }
});

test('tolls: a single entry keeps the uploaded notice, and the notice opens', async ({ browser }) => {
  onlyDesktop();
  const sql = db();
  try {
    const admin = await mkUser(sql, 'admin');
    const [car] = await sql`select plate from vehicles v join vehicle_listings l on l.vehicle_id = v.id where l.status = 'published' and v.plate is not null limit 1`;
    const page = await ctx(browser, false);
    await signIn(page, admin.email, '/admin', '/admin/tolls/new');
    await page.goto('/admin/tolls/new');
    const n = `PKT-${tag().toUpperCase()}`;
    await page.getByLabel('Kind').selectOption('parking');
    await page.getByLabel('Issued by').fill('City of Toronto');
    await page.getByLabel('Notice number').fill(n);
    await page.getByLabel('Plate', { exact: true }).fill(String(car!.plate));
    // a time and amount of its own: the same plate, time and amount is refused as a duplicate
    const m = Math.floor(Math.random() * 59);
    await page.getByLabel('When it happened').fill(`2026-09-02T15:${String(m).padStart(2, '0')}`);
    await page.getByLabel('Amount ($)').fill(`${30 + Math.floor(Math.random() * 500)}.${String(m).padStart(2, '0')}`);
    await page.getByTestId('toll-log-file').setInputFiles({ name: 'notice.pdf', mimeType: 'application/pdf', buffer: PDF });
    await check(page, 'toll entry 1440');
    await page.getByTestId('toll-log-submit').click();
    await page.waitForURL(/\/admin\/tolls\/[0-9a-f-]{36}$/, { timeout: 20_000 });
    const [t] = await sql`select t.document_id, d.kind from toll_tickets t join documents d on d.id = t.document_id where t.notice_number = ${n}`;
    expect(t!.kind).toBe('toll_ticket_notice');
    const r = await page.request.get(`/admin/documents/${t!.document_id}`);
    expect(r.status()).toBe(200);
    expect(r.headers()['content-type']).toBe('application/pdf');
    await page.context().close();
  } finally { await sql.end(); }
});

test('insurer: an invoice is emailed to the billing contact with a 7-day link, and opens as a PDF', async ({ browser }) => {
  onlyDesktop();
  const sql = db();
  try {
    const admin = await mkUser(sql, 'admin');
    const b = await mkPaidBooking(sql);
    const [ins] = await sql`insert into insurers (name, billing_contact_name, billing_email) values (${`E2E Mutual ${tag()}`}, 'Clara Claims', 'claims@e2e-mutual.test') returning id`;
    const [ii] = await sql`insert into insurer_invoices (booking_id, insurer_id, claim_number, period_start, period_end, amount_cents, hst_cents, lines)
                           values (${b.booking}, ${ins!.id}, 'CL-E2E', current_date - 10, current_date - 7, 30000, 3900, ${sql.json([{ label: 'Rental, 3 days at $100.00', amount_cents: 30000 }])}) returning id, invoice_number`;
    const page = await ctx(browser, false);
    await signIn(page, admin.email, '/admin', '/admin/insurer-invoices');
    await page.goto('/admin/insurer-invoices');
    const row = page.getByTestId('insurer-invoices').locator('tr', { hasText: String(ii!.invoice_number) });
    await row.getByTestId('insurer-invoice-email').click();
    await check(page, 'insurer email confirm 1440');
    await row.getByTestId('insurer-invoice-email-submit').click();
    const st = await waitFor(async () => (await sql`select status from insurer_invoices where id = ${ii!.id}`)[0]!.status as string, (x) => x === 'sent', 15_000);
    expect(st).toBe('sent');
    await sql`select app.process_events()`;
    const [o] = await sql`select to_address, payload, missing_variables from notification_outbox where code = 'insurer_invoice' and entity_id = ${ii!.id}`;
    expect(o!.to_address).toBe('claims@e2e-mutual.test');
    expect((o!.payload as Record<string, unknown>).invoice_total).toBe('$339.00');
    expect(o!.missing_variables).toEqual([]);
    const pdf = await page.request.get(`/files/insurer_invoice/${ii!.id}`);
    expect(pdf.status()).toBe(200);
    expect(pdf.headers()['content-type']).toBe('application/pdf');
    expect((await pdf.body()).subarray(0, 5).toString()).toBe('%PDF-');
    // the email's link, as the sender signs it, opens the same PDF without a session
    const anon = await browser.newContext({ baseURL: test.info().project.use.baseURL });
    const viaLink = await anon.request.get(`/d/${docToken('insurer_invoice', ii!.id as string)}`);
    expect(viaLink.status()).toBe(200);
    expect(viaLink.headers()['content-type']).toBe('application/pdf');
    await anon.close(); await page.context().close();
  } finally { await sql.end(); }
});

test('renter: a receipt downloads on a phone; the email link opens it; an altered or expired link does not', async ({ browser }) => {
  onlyDesktop();
  const sql = db();
  try {
    const b = await mkPaidBooking(sql);
    const phone = await ctx(browser, true);
    await signIn(phone, b.renter.email, '/account', `/account/bookings/${b.number}`);
    await phone.goto(`/account/bookings/${b.number}`);
    const link = phone.getByTestId('generated-files').getByTestId('file-receipt');
    await expect(link).toBeVisible();
    await check(phone, 'renter booking documents 375');
    const r = await phone.request.get((await link.getAttribute('href'))!);
    expect(r.status()).toBe(200);
    expect(r.headers()['content-type']).toBe('application/pdf');
    expect((await r.body()).subarray(0, 5).toString()).toBe('%PDF-');
    const [g] = await sql`select g.document_id, d.renter_id, d.booking_id from generated_documents g join documents d on d.id = g.document_id where g.kind = 'receipt' and g.entity_key = ${b.payment}`;
    expect(g, 'a final receipt is stored once').toBeTruthy();
    // another renter cannot open it
    const other = await mkPaidBooking(sql);
    const p2 = await ctx(browser, true);
    await signIn(p2, other.renter.email, '/account');
    expect((await p2.request.get(`/files/receipt/${b.payment}`)).status()).toBe(404);
    const anon = await browser.newContext({ baseURL: test.info().project.use.baseURL });
    expect((await anon.request.get(`/d/${docToken('receipt', b.payment)}`)).status()).toBe(200);
    const t = docToken('receipt', b.payment);
    expect((await anon.request.get(`/d/${t.slice(0, -2)}xx`)).status()).toBe(410);
    expect((await anon.request.get(`/d/${docToken('receipt', b.payment, -60)}`)).status()).toBe(410);
    expect((await anon.request.get(`/files/receipt/${b.payment}`, { maxRedirects: 0 })).status()).toBe(307);
    await anon.close(); await phone.context().close(); await p2.context().close();
  } finally { await sql.end(); }
});

test('statements: an owner and an investor download their PDFs on a phone; the yearly summary', async ({ browser }) => {
  onlyDesktop();
  const sql = db();
  try {
    const { user, owner } = await mkOwnerCar(sql);
    const admin = await mkUser(sql, 'admin');
    const [st] = await sql`insert into owner_statements (owner_id, statement_month, payout_date, status, approved_by, approved_at, payout_cents, owner_revenue_cents)
                           values (${owner}, date_trunc('month', current_date - 40)::date, current_date - 5, 'approved', ${admin.id}, now(), 50000, 60000) returning id`;
    const phone = await ctx(browser, true);
    await signIn(phone, user.email, '/owner', `/owner/statements/${st!.id}`);
    await phone.goto(`/owner/statements/${st!.id}`);
    await check(phone, 'owner statement 375');
    const r = await phone.request.get(`/files/owner_statement/${st!.id}`);
    expect([r.status(), r.headers()['content-type']]).toEqual([200, 'application/pdf']);

    const inv = await mkUser(sql, 'renter');
    const [i] = await sql`insert into investors (user_id, legal_name, investor_type, status, email) values (${inv.id}, 'Ines Investor', 'individual', 'active', ${inv.email}) returning id`;
    const [doc] = await sql`insert into documents (kind, storage_bucket, storage_path) values ('other', 'documents', 'x/e2e.pdf') returning id`;
    const [a] = await sql`insert into investment_agreements (investor_id, agreement_number, status, schedule_c_document_id, schedule_d_document_id, exemption_category, legal_advice_choice)
                          values (${i!.id}, ${`IA-${tag()}`}, 'signed', ${doc!.id}, ${doc!.id}, 'accredited_investor', 'declined') returning id`;
    const [x] = await sql`insert into investments (investor_id, agreement_id, is_initial, principal_cents, yearly_bps, investment_date, lockup_end_date) values (${i!.id}, ${a!.id}, true, 1000000, 1200, date '2025-01-05', date '2025-07-05') returning id`;
    const [ret] = await sql`insert into investment_returns (investment_id, return_month, opening_invested_cents, yearly_bps, days_earning, days_in_month, return_cents, disposition, payment_date, closing_invested_cents)
                            values (${x!.id}, date '2025-11-01', 1000000, 1200, 30, 30, 9863, 'pay', date '2025-12-15', 1000000) returning id`;
    const p2 = await ctx(browser, true);
    await signIn(p2, inv.email, '/investor', '/investor/statements');
    await p2.goto('/investor/statements');
    await expect(p2.getByTestId('yearly')).toContainText('Yearly summary 2025');
    await check(p2, 'investor statements 375');
    for (const href of [`/files/investor_statement/${ret!.id}`, `/files/investor_year/${encodeURIComponent(`${i!.id}:2025`)}`]) {
      const res = await p2.request.get(href);
      expect([href, res.status(), res.headers()['content-type']]).toEqual([href, 200, 'application/pdf']);
    }
    expect((await phone.request.get(`/files/investor_statement/${ret!.id}`)).status(), 'an owner does not read an investor\'s statement').toBe(404);
    await phone.context().close(); await p2.context().close();
  } finally { await sql.end(); }
});
