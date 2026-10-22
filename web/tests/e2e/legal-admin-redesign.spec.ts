import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { acceptCookies, db, noOverflow, pdfText } from './helpers';

// The legal review and the admin redesign of October 16, 2026 (migrations 0052 to 0055), end to end at 375 and 1440:
//   the admin portal's To do home, its seven menu groups (one Menu button on a phone), search and the keyboard; Admin access
//   only through rent@carmacars.ca (no Admin in the invitation form); the owner applications inbox (ask for something, the
//   owner answers in their portal, approve; decline); sample photos on a listing without photos, replaced by real ones; a
//   rental added with the saved card charged only when the renter presses Accept and sign; Form C signed on screen with
//   the witness; the co-owner's own signing page; the debit policy (insufficient funds only); the assistant's grouped menu;
//   and the guides keeping up by themselves (a section rewritten by the job, shown as changed automatically, reverted).
// Every page is checked with axe, for overflow, and for the copy rules.
const SHOTS = 'test-results/legal-admin-redesign';
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
const GROUPS = ['Today', 'Bookings', 'Cars', 'Owners and partners', 'Money', 'People', 'Settings'];
type Sql = ReturnType<typeof db>;
mkdirSync(SHOTS, { recursive: true });

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
const vin = () => `5YJ3E1EA${randomBytes(5).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
const plate = () => `LR${randomBytes(2).toString('hex').toUpperCase()}`;
const shot = (page: Page, name: string) => page.screenshot({ path: `${SHOTS}/${test.info().project.name}-${name}.png`, fullPage: true });

async function mkUser(sql: Sql, kind: 'admin' | 'va' | 'renter' | 'plain', name: string) {
  const id = randomUUID(); const email = `${kind}.lr.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (kind === 'renter') {
    await sql`select public.register_account(${id}, ${email}, ${name}, null)`;
    await sql`insert into renters (user_id, legal_name, email, mobile, date_of_birth) values (${id}, ${name}, ${email}, '+14165550142', '1988-04-12')
              on conflict (user_id) do update set date_of_birth = excluded.date_of_birth, mobile = excluded.mobile`;
    return { id, email, name };
  }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  if (kind === 'va') { await sql`insert into user_roles (user_id, role) values (${id}, 'va')`; await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'cs')`; }
  return { id, email, name };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  const p = await c.newPage();
  p.on('dialog', (d) => void d.accept(d.type() === 'prompt' ? 'Not clear' : undefined));
  return p;
}
/** On a phone the menu folds behind one Menu button: open it first. */
async function openMenu(page: Page) {
  if (isPhone()) { await page.getByTestId('nav-menu').click(); await expect(page.locator('.gn__groups.is-open')).toBeVisible(); }
}
async function application(sql: Sql, who: { id: string; email: string; name: string }, financed = false) {
  const [first, ...rest] = who.name.split(' ');
  const r = await sql`select public.server_submit_owner_application(${sql.json({ source: 'web',
    owner: { owner_type: 'individual', legal_name: who.name, first_name: first, last_name: rest.join(' '), email: who.email, phone: '+16475550133', address_line1: '30 King Street West',
             city: 'Toronto', province: 'ON', postal_code: 'M5H 1A1', licence_number: `A${randomBytes(2).toString('hex').toUpperCase()}4-56789-01234`, date_of_birth: '1990-01-01' },
    vehicles: [{ vin: vin(), plate: plate(), year: 2022, make: 'Kia', model: 'Sportage', colour: 'Grey', odometer_km: 25000, management_mode: 'managed', onboarding_method: 'transfer',
                 current_insurer: 'Intact', ...(financed ? { title_status: 'financed', finance_party_name: 'TD Auto Finance' } : { title_status: 'owned_outright', title_brand_clear: true }) }] })}, ${who.id}) r`;
  const ownerId = (r[0]!.r as { owner_id: string }).owner_id;
  const [a] = await sql`select id, application_number from owner_applications where owner_id = ${ownerId} order by created_at desc limit 1`;
  return { ownerId, appId: a!.id as string, number: a!.application_number as string };
}

/** A copy of one row with some columns changed (generated columns are left to the database). */
async function cloneRow(sql: Sql, table: string, id: string, over: Record<string, unknown>) {
  const cols = (await sql`select column_name from information_schema.columns where table_schema = 'public' and table_name = ${table} and is_generated = 'NEVER' and identity_generation is null`)
    .map((r) => `"${r.column_name as string}"`).join(', ');
  await sql.unsafe(`insert into ${table} (${cols}) select ${cols} from jsonb_populate_record(null::${table}, (select to_jsonb(t) || $1::jsonb from ${table} t where t.id = $2))`, [over as never, id]);
}

test.describe.configure({ mode: 'serial' });

test('admin: To do, the seven groups, search, the keyboard, Admin access only for rent@carmacars.ca', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Lr Admin');
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto('/admin', { waitUntil: 'networkidle' });
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('To do');
  await expect(page.getByTestId('todo-list')).toBeVisible();
  await expect(page.getByTestId('todo-pickups')).toBeVisible();
  await expect(page.getByTestId('todo-returns')).toBeVisible();
  await check(page, 'To do');
  await shot(page, 'todo');
  // the menu: seven groups with plain names, the current one open
  await openMenu(page);
  const nav = page.getByTestId('admin-nav');
  for (const g of GROUPS) await expect(nav.locator('.gn__head, .gn__single').filter({ hasText: g }).first()).toBeVisible();
  await nav.getByTestId('nav-group-owners').click();
  await expect(nav.getByRole('link', { name: /^Applications/ })).toBeVisible();
  await shot(page, 'menu');
  await nav.getByRole('link', { name: /^Applications/ }).click();
  await page.waitForURL(/\/admin\/applications/);
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Owner applications');
  if (isPhone()) await expect(page.getByTestId('nav-menu')).toContainText('Owners and partners');
  // search: a booking number finds the booking
  const [bk] = await sql`select booking_number from bookings order by created_at desc limit 1`;
  await page.locator('#gn-q').fill(bk!.booking_number as string);
  await page.locator('#gn-q').press('Enter');
  await page.waitForURL(/\/admin\/search\?q=/);
  await expect(page.locator(`main a[href="/admin/bookings/${bk!.booking_number as string}"]`).first()).toBeVisible();
  await check(page, 'search');
  // the keyboard: g then a opens Applications, / focuses the search
  if (!isPhone()) {
    await page.goto('/admin', { waitUntil: 'networkidle' });
    await page.locator('body').click({ position: { x: 700, y: 400 } });
    await page.keyboard.press('g'); await page.keyboard.press('a');
    await page.waitForURL(/\/admin\/applications/);
    await page.keyboard.press('/');
    await expect(page.locator('#gn-q')).toBeFocused();
  }
  // the old dashboard is the Overview
  await page.goto('/admin/overview', { waitUntil: 'networkidle' });
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  await check(page, 'overview');
  // Admin access: rent@carmacars.ca and the automated test account; no Admin in the invitation forms
  await page.goto('/admin/settings/staff', { waitUntil: 'networkidle' });
  const card = page.getByTestId('admin-access');
  await expect(card).toContainText('rent@carmacars.ca');
  await expect(card).toContainText('verify-admin@carmacars.ca');
  await check(page, 'admin access');
  await page.goto('/admin/portals', { waitUntil: 'networkidle' });
  const roles = await page.getByTestId('invite-card').locator('select').first().locator('option').allInnerTexts();
  expect(roles.join('|')).not.toMatch(/admin/i);
  expect(roles).toContain('Staff (assistant)');
  // and the database refuses the role to anyone else
  const other = await mkUser(sql, 'plain', 'Lr Other');
  await sql`update users set email = ${'lr.other.' + tag() + '@carmacars.ca'} where id = ${other.id}`;
  await expect(sql`insert into user_roles (user_id, role) values (${other.id}, 'admin')`).rejects.toThrow(/Admin access is only for rent@carmacars\.ca/);
  // renters have their own list
  await page.goto('/admin/renters', { waitUntil: 'networkidle' });
  await check(page, 'renters');
  await page.context().close();
  await sql.end();
});

test('admin: an owner application, asked for something, answered by the owner, approved; another declined', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Lr Admin');
  const owner = await mkUser(sql, 'plain', `Ana Applicant${tag()}`);
  const app = await application(sql, owner);
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto('/admin/applications', { waitUntil: 'networkidle' });
  await expect(page.getByRole('link', { name: 'New (', exact: false }).first()).toBeVisible();
  await expect(page.getByTestId('applications')).toContainText(app.number);
  await check(page, 'applications');
  await shot(page, 'applications');
  await page.getByRole('link', { name: app.number }).click();
  await page.waitForURL(new RegExp(`/admin/applications/${app.appId}`));
  await expect(page.getByTestId('app-check-list')).toBeVisible();
  await page.getByTestId('app-check-licence').selectOption('ok');
  await expect(page.getByTestId('app-check-licence')).toHaveValue('ok', { timeout: 15_000 });
  await check(page, 'an application');
  // ask for something
  await page.getByTestId('app-ask-open').click();
  await page.locator('[data-testid^="app-item-"]').first().check();
  await page.getByTestId('app-ask-message').fill('Please add a photo of the ownership permit.');
  await page.getByTestId('app-ask-send').click();
  await expect.poll(async () => (await sql`select status from owner_applications where id = ${app.appId}`)[0]!.status, { timeout: 20_000 }).toBe('waiting_on_owner');
  const [mail] = await sql`select count(*)::int n from app_events where code = 'owner_application_info_requested' and payload ->> 'owner_id' = ${app.ownerId}`;
  expect(mail!.n).toBe(1);
  await page.goto('/admin/applications?status=waiting_on_owner', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('applications')).toContainText(app.number);
  // the owner answers in their portal
  const op = await ctx(browser);
  await signIn(op, owner.email, '/owner');
  await op.goto('/owner', { waitUntil: 'networkidle' });
  await expect(op.getByTestId('owner-app-task')).toContainText('We need a little more');
  await expect(op.getByTestId('owner-app-task')).toContainText('ownership permit');
  await check(op, 'owner application task');
  await op.getByTestId('owner-app-reply').fill('I uploaded the permit today.');
  await op.getByTestId('owner-app-send').click();
  await expect(op.getByTestId('owner-app-answered')).toBeVisible({ timeout: 20_000 });
  await op.context().close();
  expect((await sql`select status from owner_applications where id = ${app.appId}`)[0]!.status).toBe('new');
  // approve
  await page.goto(`/admin/applications/${app.appId}`, { waitUntil: 'networkidle' });
  await expect(page.locator('body')).toContainText('I uploaded the permit today.');
  await page.getByTestId('app-approve').click();
  // 0067: the terms and first invoice step, then Approve
  await page.getByTestId('approve-confirm').click();
  await expect(page.getByTestId('app-approved')).toBeVisible({ timeout: 30_000 });
  const [o] = await sql`select o.status, a.status app from owners o join owner_applications a on a.owner_id = o.id where a.id = ${app.appId}`;
  expect(`${o!.status}/${o!.app}`).toBe('active/approved');
  // another one, declined with a reason
  const other = await mkUser(sql, 'plain', `Dan Decline${tag()}`);
  const app2 = await application(sql, other);
  await page.goto(`/admin/applications/${app2.appId}`, { waitUntil: 'networkidle' });
  await page.getByTestId('app-decline-open').click();
  await page.getByTestId('app-decline-reason').fill('We are not adding this model right now.');
  await page.getByTestId('app-decline-send').click();
  await expect.poll(async () => (await sql`select status from owner_applications where id = ${app2.appId}`)[0]!.status, { timeout: 20_000 }).toBe('declined');
  await page.goto('/admin/applications?status=declined', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('applications')).toContainText(app2.number);
  await page.context().close();
  await sql.end();
});

test('sample photos: a listing without photos shows a captioned sample, staff see it, real photos replace it', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Lr Admin');
  // a published car without photos: a copy of a seeded car, its listing and rates
  const [src] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id where l.status = 'published'
                            and exists (select 1 from vehicle_photos p where p.vehicle_id = v.id and p.status = 'approved' and p.is_public) order by v.created_at limit 1`;
  const id = randomUUID(); const slug = `lr-sample-${tag()}`;
  await cloneRow(sql, 'vehicles', src!.id as string, { id, vin: vin(), plate: plate(), fleet_number: null, car_code: null, is_sample: false });
  const [lst] = await sql`select id from vehicle_listings where vehicle_id = ${src!.id}`;
  await cloneRow(sql, 'vehicle_listings', lst!.id as string, { id: randomUUID(), vehicle_id: id, slug, canonical_vehicle_id: null });
  for (const rc of await sql`select id from rate_cards where vehicle_id = ${src!.id} and (effective_to is null or effective_to > now())`) await cloneRow(sql, 'rate_cards', rc.id as string, { id: randomUUID(), vehicle_id: id });
  try {
    const pub = await ctx(browser);
    await pub.goto(`/cars/${slug}`, { waitUntil: 'networkidle' });
    await acceptCookies(pub);
    await expect(pub.getByTestId('sample-photo-caption').first()).toBeVisible();
    await expect(pub.locator('img[src*="/sample-photos/"]').first()).toBeVisible();
    await check(pub, 'a car page with a sample photo');
    await shot(pub, 'car-sample');
    // staff see "Using sample photos"
    const page = await ctx(browser);
    await signIn(page, admin.email, '/admin');
    await page.goto(`/admin/vehicles/${id}`, { waitUntil: 'networkidle' });
    await expect(page.locator('body')).toContainText('Using sample photos');
    await page.goto('/admin/settings/sample-photos', { waitUntil: 'networkidle' });
    await expect(page.locator('body')).toContainText('The most specific photo wins');
    await check(page, 'sample photos settings');
    await page.goto('/admin', { waitUntil: 'networkidle' });
    await expect(page.getByTestId(`prompt-photos:${id}`)).toBeVisible(); // each real car showing sample photos is a To do prompt (0078)
    // a real photo approved: the sample is gone, nothing else to do
    for (const ph of await sql`select id from vehicle_photos where vehicle_id = ${src!.id} and status = 'approved' and is_public`) await cloneRow(sql, 'vehicle_photos', ph.id as string, { id: randomUUID(), vehicle_id: id, plate_status: 'not_visible' });
    // (the public page is rebuilt when staff approve the photos in the listing review; the data and staff screens change at once)
    expect((await sql`select app.public_listing_row(${id}::uuid) ->> 'sample_photos' s`)[0]!.s).toBe('false');
    await page.goto(`/admin/vehicles/${id}`, { waitUntil: 'networkidle' });
    await expect(page.locator('h1, .ad-head').first()).not.toContainText('Using sample photos');
    await page.context().close(); await pub.context().close();
  } finally {
    await sql`delete from vehicle_photos where vehicle_id = ${id}`;
    await sql`delete from rate_cards where vehicle_id = ${id}`;
    await sql`delete from vehicle_listings where vehicle_id = ${id}`;
    await sql`delete from vehicles where id = ${id}`.catch(() => undefined);
    await sql.end();
  }
});

test('legal: a rental added with the saved card is charged only when the renter presses Accept and sign', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Lr Admin');
  const renter = await mkUser(sql, 'renter', `Rita Renter${tag()}`);
  const [rid] = await sql`select id from renters where user_id = ${renter.id}`;
  const [pm] = await sql`insert into payment_methods (renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit) values (${rid!.id}, 'visa', '4242', ${renter.name}, 12, 2031, true) returning id`;
  await sql`insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id) values (${pm!.id}, 'stripe', 'cus_fake_lr', 'pm_fake_lr')`;
  // a real car of its own that takes a rental now (a manual rental never takes a sample car, and the newest car of a run
  // may be one another test just added, still waiting for its insurer or its rates): a copy of a seeded car on the fleet
  // policy, its listing and rates, as a CarmaCars-owned car (an owner's car needs its signed terms first), retired again at the end
  const [src] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and v.retired_at is null and v.bookings_enabled and app.vehicle_on_policy(v.id)
      and exists (select 1 from rate_cards r where r.vehicle_id = v.id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now()))
    order by v.is_sample desc, v.created_at limit 1`;
  const carId = randomUUID();
  const [co] = await sql`select app.company_owner_id() id`;
  await cloneRow(sql, 'vehicles', src!.id as string, { id: carId, vin: vin(), plate: plate(), fleet_number: null, car_code: null, is_sample: false, sample_bookable: false,
    supply_type: 'company', owner_id: co!.id, partner_id: null });
  const [srcList] = await sql`select id from vehicle_listings where vehicle_id = ${src!.id}`;
  await cloneRow(sql, 'vehicle_listings', srcList!.id as string, { id: randomUUID(), vehicle_id: carId, slug: `lr-card-${tag()}`, canonical_vehicle_id: null });
  for (const rc of await sql`select id from rate_cards where vehicle_id = ${src!.id} and (effective_to is null or effective_to > now())`) await cloneRow(sql, 'rate_cards', rc.id as string, { id: randomUUID(), vehicle_id: carId });
  const car = { id: carId };
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto('/admin/bookings/new', { waitUntil: 'networkidle' });
  await page.getByTestId('mr-vehicle_id').selectOption(car!.id as string);
  // months ahead, so it clashes with nothing the other tests book
  const start = new Date(Date.now() + (120 + Math.floor(Math.random() * 150)) * 86400_000);
  const ymd = (d: Date) => d.toISOString().slice(0, 10);
  await page.getByTestId('mr-pickup_at').fill(`${ymd(start)}T10:00`);
  await page.getByTestId('mr-return_at').fill(`${ymd(new Date(start.getTime() + 2 * 86400_000))}T10:00`);
  await page.getByTestId('mr-renter-q').fill(renter.name);
  await page.getByTestId('mr-renter-search').click();
  await page.getByTestId('mr-renter-results').getByRole('button', { name: renter.name }).click();
  await expect(page.getByTestId('mr-renter-chosen')).toContainText('visa ending 4242');
  await page.getByTestId('mr-source').selectOption('phone');
  await page.getByTestId('mr-check').click();
  await expect(page.getByTestId('mr-price')).toBeVisible({ timeout: 20_000 });
  if (await page.getByTestId('mr-clash').isVisible().catch(() => false)) await page.getByTestId('mr-clash_reason').fill('Test rental far ahead');
  await expect(page.getByTestId('mr-mode-card').locator('xpath=..')).toContainText('Charge the saved card when the renter signs');
  await page.getByTestId('mr-mode-card').check();
  await page.getByTestId('mr-do-not-email').check();
  await check(page, 'add a rental with the saved card');
  await page.getByTestId('mr-submit').click();
  // a refusal is shown as written: fail with it rather than with a missing line
  await expect(page.getByTestId('mr-charge-on-sign').or(page.getByTestId('mr-error'))).toBeVisible({ timeout: 30_000 });
  expect(await page.getByTestId('mr-error').allInnerTexts()).toEqual([]);
  await expect(page.getByTestId('mr-charge-on-sign')).toBeVisible();
  const number = (await page.getByTestId('mr-done').locator('h2').innerText()).match(/Rental (\S+) added/)![1]!;
  const paid = async () => (await sql`select count(*)::int n from payments p join bookings b on b.id = p.booking_id where b.booking_number = ${number} and p.status = 'succeeded' and p.kind = 'charge'`)[0]!.n;
  expect(await paid()).toBe(0);
  // the renter signs: the card is charged at that moment
  const rp = await ctx(browser);
  await signIn(rp, renter.email, '/account');
  await rp.goto(`/account/bookings/${number}/sign`, { waitUntil: 'networkidle' });
  if (await rp.locator('#pt-d-address_line1').isVisible()) {
    await rp.locator('#pt-d-address_line1').fill('100 Queen Street West');
    await rp.locator('#pt-d-city').fill('Toronto');
    await rp.locator('#pt-d-postal_code').fill('M5H 2N2');
    await rp.locator('#pt-d-licence_number').fill('W1234-56789-01234');
    await rp.locator('#pt-d-licence_expiry').fill('2031-06-30');
    await rp.getByRole('button', { name: 'Save details' }).click();
    await expect(rp.locator('.agreement')).toContainText('100 Queen Street West', { timeout: 15_000 });
  }
  await expect(rp.getByTestId('sign-charge-note')).toContainText('Read and sign your rental agreement; your card is charged when you sign.');
  await check(rp, 'sign and be charged');
  await rp.getByTestId('consents-all').check();
  await rp.getByRole('button', { name: 'Accept and sign' }).click();
  await rp.waitForURL(new RegExp(`/account/bookings/${number}(\\?|$)`), { timeout: 30_000 });
  await expect.poll(paid, { timeout: 20_000 }).toBe(1);
  // the signed rental agreement: countersigned by the signing officer with the approved wording; the staff member who
  // added the rental appears only as "Added by" (the legal review, section 6)
  const signedText = async () => {
    await rp.goto(`/account/bookings/${number}`, { waitUntil: 'networkidle' });
    for (const href of await rp.getByTestId('doc-rental_agreement').evaluateAll((as) => as.map((a) => a.getAttribute('href') ?? ''))) {
      const r = await rp.request.get(href);
      if (r.status() !== 200) continue;
      const t = await pdfText(await r.body());
      if (t.includes('Signature record')) return t;
    }
    return '';
  };
  let text = '';
  await expect.poll(async () => (text = await signedText()).length, { timeout: 30_000, intervals: [1000, 3000, 5000] }).toBeGreaterThan(0);
  // in the signature block and in the signature record
  expect(text.match(/Signed electronically for [^,]+, operating as CarmaCars, by Abbas Al-Mashita, Director, under a standing authorization dated [A-Z][a-z]+ \d{1,2}, \d{4}\./g)?.length ?? 0).toBeGreaterThanOrEqual(2);
  expect(text).toContain(`Added by ${admin.name}`);
  expect(text).not.toMatch(new RegExp(`carmacars: ${admin.name}`, 'i'));
  await rp.context().close(); await page.context().close();
  await sql`update vehicles set retired_at = now(), retired_reason = 'e2e: the saved-card rental car' where id = ${carId}`.catch(() => undefined);
  await sql.end();
});

test('legal: an investment agreement shows "Awaiting countersignature" until the Admin countersigns', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Lr Officer');
  const inv = await mkUser(sql, 'plain', `Ivy Investor${tag()}`);
  const [iv] = await sql`insert into investors (user_id, legal_name, investor_type, email, status) values (${inv.id}, ${inv.name}, 'individual', ${inv.email}, 'prospect') returning id`;
  const sha = randomBytes(32).toString('hex');
  const [req] = await sql`select public.door(${admin.id}::uuid, null, 'ops_do', 'sign_request_create', ${sql.json({ doc_type: 'investment_agreement', investor_id: iv!.id,
    exemption_category: 'accredited_investor', document: { path: `investors/${iv!.id}/ia.pdf`, sha256: sha } })}) r`;
  await sql`select public.sign_request_sign(${inv.id}::uuid, ${(req!.r as { id: string }).id}::uuid, ${sql.json({ typed_name: inv.name, consent_text: 'I agree', document_sha256: sha, legal_advice_choice: 'declined', initials: 'II' })})`;
  const countersigned = async () => (await sql`select count(*)::int n from signature_records r join investment_agreements a on a.signature_request_id = r.signature_request_id where a.investor_id = ${iv!.id} and r.signer_role = 'carmacars'`)[0]!.n;
  expect(await countersigned(), 'no automatic countersignature').toBe(0);
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/investors/${iv!.id}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('awaiting-countersignature')).toHaveText('Awaiting countersignature');
  await check(page, 'investment awaiting countersignature');
  await page.getByTestId('countersign').click();
  await expect(page.getByTestId('countersigned')).toContainText('Fully signed.', { timeout: 20_000 });
  await expect(page.getByTestId('awaiting-countersignature')).toHaveCount(0);
  expect(await countersigned()).toBe(1);
  await page.context().close();
  await sql.end();
});

test('legal: Form C on screen with the witness, the co-owner\'s own page, the debit policy', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Lr Admin');
  const owner = await mkUser(sql, 'plain', `Olive Owner${tag()}`);
  const app = await application(sql, owner, true);
  await sql`select public.admin_set_vehicle_terms(v.id, ${admin.id}, '{}'::jsonb) from vehicles v where v.owner_id = ${app.ownerId}`;
  await sql`update owners set status = 'active' where id = ${app.ownerId}`;
  const [v] = await sql`select id from vehicles where owner_id = ${app.ownerId} limit 1`;
  await sql`select public.door(${admin.id}::uuid, null, 'ops_do', 'owner_cosigner_add', ${sql.json({ owner_id: app.ownerId, name: 'Colin Coowner', email: `colin.${tag()}@example.test` })})`;
  const op = await ctx(browser);
  await signIn(op, owner.email, '/owner');
  // the owner's documents open (the co-owner gets their own link)
  await op.goto('/owner/sign', { waitUntil: 'networkidle' });
  await expect(op.locator('body')).toContainText('Every Owner named in the Title Schedule signs');
  const [co] = await sql`select token from owner_cosigners where owner_id = ${app.ownerId}`;
  if (co?.token) {
    const cp = await ctx(browser);
    await cp.goto(`/sign/owner/${co.token}`, { waitUntil: 'networkidle' });
    await expect(cp.locator('body')).toContainText('I have read these documents and I sign them electronically.');
    await check(cp, 'the co-owner signing page');
    await cp.context().close();
  }
  // Form C on screen
  await op.goto(`/owner/documents/form-c/${v!.id}`, { waitUntil: 'networkidle' });
  // 0077: the page shows the text at once; the sign form appears once the document is prepared in its own request
  await expect(op.getByTestId('form-c-sign')).toBeVisible({ timeout: 30_000 });
  await check(op, 'Form C on screen');
  await shot(op, 'form-c');
  for (const box of await op.locator('[data-testid^="form-c-ack-"]').all()) await box.check();
  await op.getByTestId('form-c-initials').fill('OO');
  await op.getByTestId('form-c-witness').fill('Wanda Witness');
  await op.getByTestId('form-c-witness-statement').check();
  await op.getByTestId('form-c-submit').click();
  await expect.poll(async () => (await sql`select status || ':' || coalesce(signed_method, '') || ':' || coalesce(witness_1_name, '') s from owner_agreement_forms
    where owner_id = ${app.ownerId} and form_code = 'C' order by created_at desc limit 1`)[0]?.s, { timeout: 30_000 }).toBe('approved:screen:Wanda Witness');
  // an invoice paid by debit from its page with the second box unticked: this invoice only, no mandate kept
  await sql`update vehicle_onboardings ob set first_last_choice = 'send', first_last_choice_cents = 2 * s.insurance_fee_cents from vehicle_schedules s join vehicles v on v.id = s.vehicle_id where s.vehicle_id = ob.vehicle_id and s.superseded_by is null and v.owner_id = ${app.ownerId}`; // 0077: the Admin's choice
  await sql`select public.admin_issue_upfront_invoices(${app.ownerId}::uuid, ${admin.id}::uuid, null)`;
  const [inv] = await sql`select invoice_number from owner_invoices where owner_id = ${app.ownerId} and status = 'issued' order by created_at limit 1`;
  if (inv) {
    await op.goto(`/owner/invoices/${inv.invoice_number}`, { waitUntil: 'networkidle' });
    await op.locator('label:has-text("Pre-authorized debit")').click();
    await expect(op.getByTestId('fake-bank')).toBeVisible();
    await expect(op.getByTestId('pad-payee')).toContainText('operating as CarmaCars');
    await expect(op.getByTestId('pad-one-time')).toContainText('I waive pre-notification and any waiting period for this one-time debit.');
    await check(op, 'invoice debit, two boxes');
    await op.locator('#ow-bname').fill(owner.name);
    await op.locator('#ow-binst').fill('004');
    await op.locator('#ow-btransit').fill('12345');
    await op.locator('#ow-bacct').fill('1234567');
    await op.getByTestId('pad-recurring').locator('input').uncheck();
    await op.getByTestId('pad-one-time').locator('input').check();
    await op.getByRole('button', { name: /Authorize debit/ }).click();
    await expect(op.getByTestId('invoice-pending')).toContainText('processing', { timeout: 20_000 });
    const [m] = await sql`select count(*)::int n from owner_payment_methods where owner_id = ${app.ownerId} and kind = 'pre_authorized_debit' and status in ('active', 'pending')`;
    expect(m!.n, 'no recurring mandate when the second box is unticked').toBe(0);
  }
  await op.context().close();
  // the debit policy, in words: the retry and the Late Fee only for insufficient funds
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto('/admin/debits', { waitUntil: 'networkidle' });
  await expect(page.locator('body')).toContainText(/insufficient funds/i);
  await check(page, 'owner debits');
  await page.context().close();
  await sql.end();
});

test('assistant: the grouped menu, To do first', async ({ browser }) => {
  const sql = db();
  const va = await mkUser(sql, 'va', 'Lr Assistant');
  const page = await ctx(browser);
  await signIn(page, va.email, '/va');
  await page.goto('/va', { waitUntil: 'networkidle' });
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('To do');
  await openMenu(page);
  const nav = page.getByTestId('va-nav');
  for (const g of ['My work', 'Bookings', 'Renters', 'Cars', 'Owners']) await expect(nav.locator('.gn__head, .gn__single').filter({ hasText: g }).first()).toBeVisible();
  await nav.getByTestId('nav-group-bookings').click();
  await nav.getByRole('link', { name: 'Requests' }).click();
  await page.waitForURL(/\/va\/requests/);
  await check(page, 'assistant requests');
  await page.context().close();
  await sql.end();
});

test('guides keep up: a section rewritten by the job is published, shown as changed automatically, and reverted', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Lr Admin');
  const slug = `lr-auto-${tag()}`;
  const before = 'Open your jobs and press **Start the job now**.\n';
  const [sec] = await sql`insert into guide_sections (portal, kind, sort_order, slug, title, body_md, draft_version, published_title, published_md, published_html, published_hidden, published_version, published_at)
    values ('field', 'chapter', 990, ${slug}, 'Lr auto chapter', ${before}, 1, 'Lr auto chapter', ${before}, '<p>Old</p>', false, 1, now()) returning id`;
  try {
    const env = readFileSync(path.join(process.cwd(), '.env.local'), 'utf8');
    const key = /^LINK_SIGNING_KEY=(.*)$/m.exec(env)![1]!.trim();
    const token = createHmac('sha256', key).update('carmacars-listing-worker-v1').digest('hex');
    const page = await ctx(browser);
    const run = `e2e-${tag()}`;
    const r = await page.request.post('/api/jobs/guide-rewrite', { headers: { authorization: `Bearer ${token}` },
      data: { section_id: sec!.id, run, reason: 'It names buttons the portals no longer show (Start the job now)', labels: ['Start'],
              facts: { portal: 'field', nav: [], screen_labels: ['Start'], missing: [{ label: 'Start the job now', closest: ['Start'] }] } } });
    expect(r.ok()).toBe(true);
    const j = await r.json();
    expect(j.result).toBe('updated');
    expect((await sql`select published_md from guide_sections where id = ${sec!.id}`)[0]!.published_md).toContain('**Start**');
    // without the token: refused
    expect((await page.request.post('/api/jobs/guide-rewrite', { data: {} })).status()).toBe(403);
    await signIn(page, admin.email, '/admin');
    await page.goto('/admin/settings/guides', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('guide-auto-field')).toContainText('Changed automatically on');
    await expect(page.getByTestId('guide-upkeep')).toBeVisible();
    await check(page, 'guides');
    await page.goto('/admin/settings/guides/field', { waitUntil: 'networkidle' });
    await page.getByTestId(`guide-section-${slug}`).click();
    await expect(page.getByTestId('guide-auto-panel')).toContainText('Changed automatically on');
    await check(page, 'a section changed automatically');
    await shot(page, 'guide-auto');
    await page.getByTestId('guide-auto-revert').click();
    await expect(page.getByTestId('guide-auto-panel')).toHaveCount(0, { timeout: 20_000 });
    expect((await sql`select published_md from guide_sections where id = ${sec!.id}`)[0]!.published_md).toBe(before);
    await page.context().close();
  } finally {
    await sql`delete from guide_sections where id = ${sec!.id}`;
    await sql.end();
  }
});
