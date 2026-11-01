import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, aiAllowanceLock, db, FIXTURE_JPEG, noOverflow } from './helpers';

// Release 25b end to end, at 375 and 1440: the ownership permit read from a photo (0290) on Add a car for an owner,
// Admin > Add a car, a car's Registration card and the owner's own application; and the rental walkthrough (0291) on the
// renter's booking, its page with "Got it", and the field job's line. The fake vision model (src/integrations/vision/
// fake.ts) answers a synthetic permit: VIN 3FAKEPRM5RT000042 (a valid check digit), plate ZZZZ123, GRY, X0000001,
// sticker 271130. Fictional people only (example.test). Each screen is attached to the report as r25b-*.png.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const PHOTO = { name: 'permit.jpg', mimeType: 'image/jpeg', buffer: FIXTURE_JPEG };

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text.match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
}
async function shot(page: Page, name: string) {
  await page.evaluate(() => document.fonts?.ready).catch(() => undefined);
  await test.info().attach(`r25b-${name}-${isPhone() ? '375' : '1440'}.png`, { body: await page.screenshot({ fullPage: true }), contentType: 'image/png' });
}
async function mkStaff(sql: Sql, kind: 'admin' | 'va' | 'field', name: string, fn?: 'cs' | 'fleet') {
  const id = randomUUID(); const email = `r25b.${kind}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${kind})`;
  if (kind === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${fn ?? 'cs'})`;
  if (kind === 'field') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver_detailer')`;
  return { id, email };
}
async function page(browser: Browser, email: string, expectPath: string) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  const p = await c.newPage();
  await p.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(p);
  await p.locator('input[type="email"]').fill(email);
  await p.locator('input[type="password"]').fill(PW);
  await p.getByRole('button', { name: 'Sign in' }).click();
  await p.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 60_000 });
  return p;
}
/** The permit read on a form: the photo chosen, the answer checked and shown field by field. */
async function readPermit(p: Page, prefix: string) {
  await expect(p.getByTestId(`${prefix}-scan`)).toContainText('Fill this from the ownership permit');
  await p.getByTestId(`${prefix}-scan-file`).setInputFiles(PHOTO);
  const res = p.getByTestId(`${prefix}-scan-result`);
  await expect(res).toBeVisible({ timeout: 60_000 });
  await expect(p.getByTestId(`${prefix}-scan-vin`)).toContainText('3FAKEPRM5RT000042');
  await expect(p.getByTestId(`${prefix}-scan-vin`)).toContainText('Checked');
  await expect(p.getByTestId(`${prefix}-scan-plate`)).toContainText('ZZZZ123');
  await expect(p.getByTestId(`${prefix}-scan-colour`)).toContainText('Grey (GRY)');
  await expect(p.getByTestId(`${prefix}-scan-sticker_expires_on`)).toContainText('2027');
  await expect(p.getByTestId(`${prefix}-scan`)).toContainText('9 of 9 details read and checked');
}

test.describe.configure({ mode: 'serial' });

test('the permit photo fills Add a car for an owner, Add a car and the Registration card; each detail is checked', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  const unlock = await aiAllowanceLock('shared');
  try {
    const admin = await mkStaff(sql, 'admin', `Ada Permit ${tag()}`);
    const p = await page(browser, admin.email, '/admin');

    await p.goto('/admin/owners/add-car', { waitUntil: 'networkidle' });
    await shot(p, 'addcar-before');
    await readPermit(p, 'addcar-permit');
    await expect(p.getByTestId('addcar-plate')).toHaveValue('ZZZZ123');
    await expect(p.getByTestId('addcar-permit_number')).toHaveValue('X0000001');
    await expect(p.getByTestId('addcar-sticker_expires_on')).toHaveValue('2027-11-30');
    await expect(p.getByTestId('addcar-vin')).toHaveValue(/3FAKEPRM5RT000042/);
    await expect(p.getByTestId('addcar-colour-grey')).toBeChecked();
    await expect(p.getByTestId('addcar-permit-attached')).toBeVisible();
    await check(p, 'add a car for an owner, permit read');
    await shot(p, 'addcar-read');

    // Admin > Vehicles > Add a car
    await p.goto('/admin/vehicles/new', { waitUntil: 'networkidle' });
    await readPermit(p, 'add-car-permit');
    await expect(p.getByTestId('add-car-permit_number')).toHaveValue('X0000001');
    await expect(p.getByTestId('add-car-permit-attached')).toBeVisible();
    await check(p, 'add a car, permit read');
    await shot(p, 'vehicle-new-read');

    // a car's Registration: the empty fields filled, the photo ready to upload
    const [car] = await sql`select app.vehicle_add(${admin.id}, ${sql.json({ supply_type: 'company', plate: `R${tag().toUpperCase()}`, year: 2024, make: 'Toyota', model: 'Corolla' })}) as r`;
    const carId = (car!.r as { vehicle_id: string }).vehicle_id;
    await p.goto(`/admin/vehicles/${carId}?tab=records`, { waitUntil: 'networkidle' });
    await readPermit(p, 'reg-permit');
    await expect(p.getByTestId('reg-permit_number')).toHaveValue('X0000001');
    await expect(p.getByTestId('reg-sticker_expires_on')).toHaveValue('2027-11-30');
    await expect(p.getByTestId('reg-year')).toHaveValue('2024');
    await expect(p.getByTestId('reg-permit-ready')).toBeVisible();
    await expect(p.getByTestId('reg-permit-msg')).toContainText('Check each field');
    await check(p, 'registration, permit read');
    await shot(p, 'registration-read');
    // the read is recorded: who and how many fields, never the values
    const [n] = await sql`select count(*)::int n, min(fields_read)::int f from permit_reads where user_id = ${admin.id}`;
    expect(n!.n).toBe(3);
    expect(n!.f).toBe(9);
    await p.context().close();
  } finally { await unlock(); await sql.end(); }
});

test('a signed-in owner reads the permit in their own application', async ({ browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  const unlock = await aiAllowanceLock('shared');
  try {
    const id = randomUUID(); const email = `r25b.owner.${Date.now()}.${tag()}@example.test`;
    await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
    await sql`select public.register_account(${id}, ${email}, 'Olive Permit', null)`;
    const p = await page(browser, email, '/');
    await p.goto('/list-your-car/apply', { waitUntil: 'networkidle' });
    await p.locator('label:has-text("An individual")').click();
    await p.locator('#ap-first').fill('Olive');
    await p.locator('#ap-last').fill('Permit');
    if (await p.locator('#ap-email').isEditable()) await p.locator('#ap-email').fill(email);
    await p.locator('#ap-addr').fill('union');
    await p.getByRole('option', { name: /Union Station/ }).click();
    await p.locator('#ap-postal').fill('m5j 1e6');
    await p.locator('#ap-phone').fill('647-555-0102');
    await p.locator('#ap-lic').fill('O1234-56789-01234');
    await p.locator('#ap-dob').fill('1985-05-05');
    await p.getByRole('button', { name: 'Continue to vehicles' }).click();
    await readPermit(p, 'apply-permit');
    await expect(p.locator('#ap-v0-vin')).toHaveValue('3FAKEPRM5RT000042');
    await expect(p.getByTestId('apply-colour-grey')).toBeChecked();
    await check(p, 'owner application, permit read');
    await shot(p, 'apply-read');
    await p.context().close();
  } finally { await unlock(); await sql.end(); }
});

test('the renter is walked through the rental step by step; field staff see how far they read', async ({ browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  try {
    const admin = await mkStaff(sql, 'admin', `Ada Walk ${tag()}`);
    const field = await mkStaff(sql, 'field', `Frankie Walk ${tag()}`);
    const rid = randomUUID(); const remail = `r25b.renter.${Date.now()}.${tag()}@example.test`;
    await sql`insert into local_auth.users (id, email, password_hash) values (${rid}, ${remail}, ${hash(PW)})`;
    await sql`select public.register_account(${rid}, ${remail}, 'Wendy Walk', null)`;
    await sql`insert into renters (user_id, legal_name, email, mobile, date_of_birth) values (${rid}, 'Wendy Walk', ${remail}, '+14165550143', '1988-04-12')
              on conflict (user_id) do update set date_of_birth = excluded.date_of_birth`;
    const [rn] = await sql`select id from renters where user_id = ${rid}`;
    await sql`insert into drivers (renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_class, licence_number) values (${rn!.id as string}, true, ${rid}, 'Wendy Walk', '1988-04-12', 'G', 'W1234-56789-01234') on conflict do nothing`;
    const [car] = await sql`select app.vehicle_add(${admin.id}, ${sql.json({ supply_type: 'company', plate: `W${tag().toUpperCase()}`, year: 2024, make: 'Kia', model: 'K5',
      rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as r`;
    const carId = (car!.r as { vehicle_id: string }).vehicle_id;
    const pick = new Date(Date.now() + (3 * 24 + Math.floor(Math.random() * 24)) * 3600_000); pick.setMinutes(0, 0, 0);
    const [m] = await sql`select app.manual_rental_create(${admin.id}, ${sql.json({ vehicle_id: carId, pickup_at: pick.toISOString(), return_at: new Date(pick.getTime() + 3 * 86_400_000).toISOString(),
      source: 'phone', coverage_option: 1, renter_id: rn!.id as string, payment: { mode: 'other_way', method: 'cash' } })}) as r`;
    const booking = m!.r as { booking_id: string; booking_number: string };
    const [job] = await sql`insert into field_jobs (kind, vehicle_id, booking_id, scheduled_at, assigned_to, status, created_by)
                            values ('handover', ${carId}, ${booking.booking_id}, ${pick.toISOString()}, ${field.id}, 'scheduled', ${admin.id}) returning id`;

    const rp = await page(browser, remail, '/account');
    await rp.goto(`/account/bookings/${encodeURIComponent(booking.booking_number)}`, { waitUntil: 'networkidle' });
    const card = rp.getByTestId('walk-card');
    await expect(card).toContainText('Your rental, step by step');
    await expect(card).toContainText('Before pickup');
    await check(rp, 'booking with the walkthrough card');
    await shot(rp, 'booking-card');
    await rp.getByTestId('walk-open').click();
    await rp.waitForURL(/\/walkthrough$/);
    await expect(rp.getByTestId('walkthrough')).toBeVisible();
    await expect(rp.getByTestId('walk-progress')).toContainText(/of 1[23] done/);
    for (const s of ['before', 'pickup', 'road', 'return']) await expect(rp.getByTestId(`walk-stage-${s}`)).toBeVisible();
    await expect(rp.getByTestId('walk-step-inspect')).toContainText('Walk around the car with us');
    await expect(rp.getByTestId('walk-now')).toBeVisible();
    await check(rp, 'the walkthrough');
    await shot(rp, 'walkthrough');
    // Got it: what to bring is read, and stays read
    await rp.getByTestId('walk-got-bring').click();
    await expect(rp.getByTestId('walk-step-bring')).toHaveAttribute('data-state', 'done', { timeout: 20_000 });
    await rp.reload({ waitUntil: 'networkidle' });
    await expect(rp.getByTestId('walk-step-bring')).toHaveAttribute('data-state', 'done');
    await shot(rp, 'walkthrough-got-it');
    await rp.context().close();

    const fp = await page(browser, field.email, '/staff/field');
    await fp.goto(`/staff/field/jobs/${job!.id as string}`, { waitUntil: 'networkidle' });
    await expect(fp.getByTestId('job-walkthrough')).toContainText('read 1 of 6 steps');
    await check(fp, 'field job with the walkthrough line');
    await shot(fp, 'field-job');
    await fp.context().close();
  } finally { await sql.end(); }
});
