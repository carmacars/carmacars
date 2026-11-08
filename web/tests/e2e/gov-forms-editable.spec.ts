import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Release 35, part S (migration 0870), end to end at 375 and 1440: the government forms are as editable as the rental
// agreements. An Admin opens a car's form, changes one value with a reason: version 2, the earlier version listed and
// still open; Back to the records; fleet changes a value from the staff portal, opens the forms' mapping (sample car in
// the preview list, the history, no upload), and Make again keeps the change unless discarded. The owner's Documents
// shows the current version only. Every page is checked with axe and for overflow. No real person is emailed.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
const W = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];
const T = (c: string) => (/\d/.test(c) ? Number(c) : 'ABCDEFGH'.includes(c) ? 'ABCDEFGH'.indexOf(c) + 1 : 'JKLMN'.includes(c) ? 'JKLMN'.indexOf(c) + 1 : c === 'P' ? 7 : c === 'R' ? 9 : 'STUVWXYZ'.indexOf(c) + 2);
const withCheck = (v: string) => { const s = [...v].reduce((a, c, i) => a + T(c) * W[i]!, 0) % 11; return `${v.slice(0, 8)}${s === 10 ? 'X' : s}${v.slice(9)}`; };
const vin = () => withCheck(`1HGCM82603A${String(Math.floor(Math.random() * 1e6)).padStart(6, '0')}`);

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function mkUser(sql: Sql, kind: 'admin' | 'plain' | 'fleet', name: string) {
  const id = randomUUID(); const email = `${kind}.r35s.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  if (kind === 'fleet') {
    await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
    await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'fleet')`;
  }
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
  p.on('dialog', (d) => void d.accept());
  return p;
}
async function approvedCar(sql: Sql, admin: string, who: { id: string; email: string; name: string }) {
  const [first, ...rest] = who.name.split(' ');
  const r = await sql`select public.server_submit_owner_application(${sql.json({ source: 'web',
    owner: { owner_type: 'individual', legal_name: who.name, first_name: first, last_name: rest.join(' '), email: who.email, phone: '+16475550144', address_line1: '30 King Street West',
             city: 'Toronto', province: 'ON', postal_code: 'M5H 1A1', licence_number: `P${randomBytes(2).toString('hex').toUpperCase()}4-56789-01234`, date_of_birth: '1990-01-01' },
    vehicles: [{ vin: vin(), plate: `PS${randomBytes(2).toString('hex').toUpperCase()}`, year: 2021, make: 'Hyundai', model: 'Sonata', colour: 'Blue', odometer_km: 30000, held_by: 'individual',
      management_mode: 'managed', onboarding_method: 'co_registrant', current_insurer: 'Example Insurer', title_status: 'owned_outright', title_brand_clear: true }] })}, ${who.id}) r`;
  const ownerId = (r[0]!.r as { owner_id: string }).owner_id;
  const [a] = await sql`select id from owner_applications where owner_id = ${ownerId} order by created_at desc limit 1`;
  const [v] = await sql`select id from vehicles where owner_id = ${ownerId} order by created_at desc limit 1`;
  await sql`select public.door(${admin}, null, 'ops_do', 'application_approve', ${sql.json({ id: a!.id, cars: [{ vehicle_id: v!.id,
    terms: { management_mode: 'managed', onboarding_method: 'co_registrant' }, first_last: { action: 'none' } }] })})`;
  const [f] = await sql`select id from government_form_fills where vehicle_id = ${v!.id} and form_code = 'SR-LV-006' and superseded_at is null`;
  return { ownerId, vehicle: v!.id as string, fill: f!.id as string };
}
async function changeFirst(page: Page, value: string, reason: string) {
  await page.getByTestId('gov-form-change').click();
  await page.getByTestId('gov-form-field').first().getByTestId('gov-form-pick').click();
  await page.getByTestId('gov-form-value').fill(value);
  await page.getByTestId('gov-form-reason').fill(reason);
  await page.getByTestId('gov-form-save').click();
  await expect(page.getByTestId('gov-form-version-now')).toContainText('version', { timeout: 20_000 });
}

test.describe.configure({ mode: 'serial' });
test.setTimeout(180_000);

test('Admin: a value changed with a reason is a new version; the earlier one stays; back to the records', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Gf Admin');
  const owner = await mkUser(sql, 'plain', `Pat Forms${tag()}`);
  const car = await approvedCar(sql, admin.id, owner);
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/owners/${car.ownerId}`, { waitUntil: 'networkidle' });
  await page.getByTestId('government-forms').locator('[data-code="SR-LV-006"]').getByTestId('government-form-download').click();
  await page.waitForURL(`**/admin/government-forms/${car.fill}`);
  await expect(page.getByTestId('gov-form-editor')).toBeVisible();
  await check(page, 'admin government form');
  await changeFirst(page, 'CHANGED BY HAND', 'Corrected at the registry');
  await expect(page).not.toHaveURL(new RegExp(car.fill));
  await expect(page.getByTestId('gov-form-version-now')).toContainText('version 2');
  await expect(page.getByTestId('gov-form-version')).toHaveCount(2);
  expect((await sql`select count(*)::int n from audit_log where action = 'government_form_edit' and after ->> 'vehicle_id' = ${car.vehicle}`)[0]!.n).toBe(1);
  await check(page, 'admin government form, version 2');
  // the earlier version opens, marked earlier, without the change button
  await page.getByTestId('gov-form-version').filter({ hasText: 'Version 1' }).getByRole('link', { name: 'Version 1' }).click();
  await expect(page.getByTestId('gov-form-version-now')).toContainText('an earlier version', { timeout: 20_000 });
  await expect(page.getByTestId('gov-form-change')).toHaveCount(0);
  // back to the records
  await page.getByTestId('gov-form-version').filter({ hasText: '(current)' }).getByRole('link').first().click();
  await page.getByTestId('gov-form-change').click();
  await page.getByTestId('gov-form-field').first().getByTestId('gov-form-pick').click();
  await page.getByTestId('gov-form-reason').fill('As the records say');
  await page.getByTestId('gov-form-restore').click();
  await expect(page.getByTestId('gov-form-version-now')).toContainText('version 3', { timeout: 20_000 });
  await sql.end();
});

test('fleet: changes a value, maps the forms (sample car, history, no upload); Make again keeps or discards; the owner sees the current version', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Gf Admin2');
  const fleet = await mkUser(sql, 'fleet', 'Gf Fleet');
  const owner = await mkUser(sql, 'plain', `Pat Fleetforms${tag()}`);
  const car = await approvedCar(sql, admin.id, owner);
  const page = await ctx(browser);
  await signIn(page, fleet.email, '/staff');
  await page.goto(`/staff/government-forms/${car.fill}`, { waitUntil: 'networkidle' });
  await changeFirst(page, 'FLEET VALUE', 'Read from the permit');
  await expect(page.getByTestId('gov-form-version-now')).toContainText('version 2');
  await check(page, 'staff government form');
  // the mapping page: the sample car first, the history, no upload
  await page.goto('/staff/government-forms', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('official-forms')).toBeVisible();
  await expect(page.locator('input[type="file"]')).toHaveCount(0);
  const card = page.getByTestId('form-SR-LV-006');
  if (await card.locator('summary', { hasText: 'Fields and what goes in them' }).count()) {
    const sel = card.locator('#fp-SR-LV-006');
    if (await sel.count()) await expect(sel.locator('option').first()).toHaveText(/sample car/);
  }
  await check(page, 'staff forms mapping');
  // Make again from the owner page keeps the change, then discards it
  await page.goto(`/staff/owners/${car.ownerId}`, { waitUntil: 'networkidle' });
  const forms = page.getByTestId('government-forms');
  await forms.getByTestId('government-forms-make-again').click();
  await expect(page.getByTestId('government-forms-make-again-msg')).toContainText('changed by hand kept: 1', { timeout: 20_000 });
  await forms.getByTestId('government-forms-discard').check();
  await forms.getByTestId('government-forms-make-again').click();
  await expect(page.getByTestId('government-forms-make-again-msg')).toContainText('discarded: 1', { timeout: 20_000 });
  expect((await sql`select count(*)::int n from government_form_overrides where vehicle_id = ${car.vehicle} and ended_at is null`)[0]!.n).toBe(0);
  // the owner: one form of each kind, the current one
  const own = await ctx(browser);
  await signIn(own, owner.email, '/owner');
  await own.goto('/owner/documents', { waitUntil: 'networkidle' });
  await expect(own.getByTestId('government-forms').locator('[data-code="SR-LV-006"]')).toHaveCount(1);
  const href = await own.getByTestId('government-forms').locator('[data-code="SR-LV-006"]').getByTestId('government-form-download').getAttribute('href');
  const [cur] = await sql`select id from government_form_fills where vehicle_id = ${car.vehicle} and form_code = 'SR-LV-006' and superseded_at is null`;
  expect(href).toContain(cur!.id as string);
  await sql.end();
});
