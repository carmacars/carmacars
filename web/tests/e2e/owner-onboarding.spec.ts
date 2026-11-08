import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, FIXTURE_JPEG, noOverflow, storeFixtureJpeg } from './helpers';

// Release 34, part P (migrations 0820 to 0826), end to end at 375 and 1440:
//   the Admin owner page: the one Onboarding checklist, an onboarding photo replaced (back to review) and removed with a
//   reason, the government forms with their date and Make again; the Sonata bug: a car moved from company supply to the
//   owner, edited on the Terms tab, shows the saved terms after a reload; customer service: Owners, the same checklist
//   and photos; the owner portal: the checklist on the car's page, a photo replaced, cars added from a list of VINs (a
//   typo and a duplicate reported, not made). Every page is checked with axe and for overflow. No real person is emailed.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
// a VIN of the fake decoder's Honda (1HG...) with a valid check digit
const W = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];
const T = (c: string) => (/\d/.test(c) ? Number(c) : 'ABCDEFGH'.includes(c) ? 'ABCDEFGH'.indexOf(c) + 1 : 'JKLMN'.includes(c) ? 'JKLMN'.indexOf(c) + 1 : c === 'P' ? 7 : c === 'R' ? 9 : 'STUVWXYZ'.indexOf(c) + 2);
const withCheck = (v: string) => { const s = [...v].reduce((a, c, i) => a + T(c) * W[i]!, 0) % 11; return `${v.slice(0, 8)}${s === 10 ? 'X' : s}${v.slice(9)}`; };
const vin = () => withCheck(`1HGCM826${'0'}3${'A'}${String(Math.floor(Math.random() * 1e6)).padStart(6, '0')}`);

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function mkUser(sql: Sql, kind: 'admin' | 'plain' | 'cs', name: string) {
  const id = randomUUID(); const email = `${kind}.r34p.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  if (kind === 'cs') {
    await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
    await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'cs')`;
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
async function application(sql: Sql, who: { id: string; email: string; name: string }, method = 'co_registrant') {
  const [first, ...rest] = who.name.split(' ');
  const r = await sql`select public.server_submit_owner_application(${sql.json({ source: 'web',
    owner: { owner_type: 'individual', legal_name: who.name, first_name: first, last_name: rest.join(' '), email: who.email, phone: '+16475550144', address_line1: '30 King Street West',
             city: 'Toronto', province: 'ON', postal_code: 'M5H 1A1', licence_number: `P${randomBytes(2).toString('hex').toUpperCase()}4-56789-01234`, date_of_birth: '1990-01-01' },
    vehicles: [{ vin: vin(), plate: `PO${randomBytes(2).toString('hex').toUpperCase()}`, year: 2021, make: 'Hyundai', model: 'Sonata', colour: 'Blue', odometer_km: 30000, held_by: 'individual',
      management_mode: 'managed', onboarding_method: method, current_insurer: 'Example Insurer', title_status: 'owned_outright', title_brand_clear: true }] })}, ${who.id}) r`;
  const ownerId = (r[0]!.r as { owner_id: string }).owner_id;
  const [a] = await sql`select id from owner_applications where owner_id = ${ownerId} order by created_at desc limit 1`;
  const [v] = await sql`select id from vehicles where owner_id = ${ownerId} order by created_at desc limit 1`;
  return { ownerId, appId: a!.id as string, vehicle: v!.id as string };
}
async function permit(sql: Sql, ownerUser: string, ownerId: string, vehicle: string) {
  const key = `owners/${ownerId}/vehicles/${vehicle}/ownership_permit-${randomUUID()}.jpg`;
  storeFixtureJpeg('documents', key);
  await sql`select app.owner_register_document(${ownerUser}, ${vehicle}, 'ownership_permit', ${key}, ${'a'.repeat(64)}, 'image/jpeg')`;
}

test.describe.configure({ mode: 'serial' });
test.setTimeout(180_000);

test('Admin: one checklist, a photo replaced and removed, the government forms with Make again', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Po Admin');
  const owner = await mkUser(sql, 'plain', `Pat Photos${tag()}`);
  const app = await application(sql, owner);
  await sql`select public.door(${admin.id}, null, 'ops_do', 'application_approve', ${sql.json({ id: app.appId, cars: [{ vehicle_id: app.vehicle,
    terms: { management_mode: 'managed', onboarding_method: 'co_registrant' }, first_last: { action: 'none' } }] })})`;
  await permit(sql, owner.id, app.ownerId, app.vehicle);
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/owners/${app.ownerId}`, { waitUntil: 'networkidle' });
  const list = page.getByTestId('onboarding-checklist');
  await expect(list.getByTestId('onboarding-car')).toHaveCount(1);
  await expect(list.locator('[data-step="documents"]')).toContainText('Check the photos');
  await expect(list.locator('[data-step="government_forms"]')).toHaveAttribute('data-state', /done|blocked/);
  // the government forms: made by themselves at approval, with their date
  const forms = page.getByTestId('government-forms');
  await expect(forms.getByTestId('government-form')).toHaveCount(2);
  // made at approval: the approval fills them in the Admin's name (app.fill_vehicle_government_forms, 0029), so the line
  // names the Admin; a change made later by itself reads "by itself"
  await expect(forms.getByTestId('government-form-made').first()).toContainText(/\d{4}.*by (itself|\S)/);
  await check(page, 'admin owner page');
  // approve, then replace: back to review
  const photo = page.getByTestId('onboarding-photo').first();
  await photo.getByTestId('onboarding-photo-approve').click();
  await expect(page.getByTestId('onboarding-photo').first().getByTestId('onboarding-photo-status')).toHaveText('Approved', { timeout: 20_000 });
  await page.getByTestId('onboarding-photo').first().getByTestId('onboarding-photo-replace').setInputFiles({ name: 'permit.jpg', mimeType: 'image/jpeg', buffer: FIXTURE_JPEG });
  await expect(page.getByTestId('onboarding-photo').first().getByTestId('onboarding-photo-status')).toHaveText('Waiting for the check', { timeout: 30_000 });
  expect((await sql`select count(*)::int n from audit_log where action = 'onboarding_photo_back_to_review' and after ->> 'vehicle_id' = ${app.vehicle}`)[0]!.n).toBe(1);
  // removed with a reason
  await page.getByTestId('onboarding-photo').first().getByTestId('onboarding-photo-remove-open').click();
  await page.getByTestId('onboarding-photo-reason').fill('The permit of another car');
  await page.getByTestId('onboarding-photo-confirm').click();
  await expect(page.getByTestId('onboarding-photos-none')).toBeVisible({ timeout: 20_000 });
  // Make again
  await forms.getByTestId('government-forms-make-again').click();
  await expect(page.getByTestId('government-forms-make-again-msg')).toContainText('Made again: 2', { timeout: 20_000 });
  // the car page has the same box
  await page.goto(`/admin/vehicles/${app.vehicle}?tab=records`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('government-forms').getByTestId('government-form')).toHaveCount(2);
  await sql.end();
});

test('the Sonata: a car moved from company supply to the owner shows the terms saved after a reload', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Ps Admin');
  const owner = await mkUser(sql, 'plain', `Mo Moved${tag()}`);
  const app = await application(sql, owner);
  // the car was the company's, with the company's terms row covering today; then moved to the owner, terms set
  await sql`select app.vehicle_set_supply(${admin.id}, ${sql.json({ vehicle_id: app.vehicle, supply_type: 'company' })})`;
  await sql`insert into owner_terms (owner_id, vehicle_id, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, install_fee_cents, effective_from)
            values (app.company_owner_id(), ${app.vehicle}, 30000, 2500, 3000, 10000, app.today() - 5)`;
  await sql`select app.vehicle_set_supply(${admin.id}, ${sql.json({ vehicle_id: app.vehicle, supply_type: 'program_owner', owner_id: app.ownerId })})`;
  await sql`select public.door(${admin.id}, null, 'ops_do', 'application_approve', ${sql.json({ id: app.appId, cars: [{ vehicle_id: app.vehicle,
    terms: { management_mode: 'managed', onboarding_method: 'co_registrant', insurance_fee_cents: 30000, tracker_fee_cents: 2500, revenue_share_bps: 3000, install_fee_cents: 10000 }, first_last: { action: 'none' } }] })})`;
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/owners/${app.ownerId}?tab=terms`, { waitUntil: 'networkidle' });
  const row = page.getByTestId('car-terms-row').first();
  await row.getByTestId('car-terms-edit').click();
  await row.getByTestId('car-terms-insurance').fill('284.00');
  await row.getByTestId('car-terms-tracker').fill('0.00');
  await row.getByTestId('car-terms-share').fill('30');
  await row.getByTestId('car-terms-install').fill('0.00');
  const panel = page.getByTestId('car-terms-panel');
  await panel.getByTestId('car-terms-review').click();
  await panel.getByTestId('car-terms-confirm').click();
  await expect(page.getByTestId('car-terms-done')).toBeVisible({ timeout: 20_000 });
  await page.reload({ waitUntil: 'networkidle' });
  const after = page.getByTestId('car-terms-row').first();
  await expect(after.getByTestId('car-terms-insurance-value')).toHaveText('$284.00');
  await expect(after.getByTestId('car-terms-tracker-value')).toHaveText('$0.00');
  await expect(after.getByTestId('car-terms-install-value')).toHaveText('$0.00');
  await sql.end();
});

test('customer service: Owners, the same checklist and photos', async ({ browser }) => {
  const sql = db();
  const cs = await mkUser(sql, 'cs', 'Pc Service');
  const owner = await mkUser(sql, 'plain', `Cy Service${tag()}`);
  const app = await application(sql, owner);
  await permit(sql, owner.id, app.ownerId, app.vehicle);
  const page = await ctx(browser);
  await signIn(page, cs.email, '/staff');
  await page.goto(`/staff/owners?q=${encodeURIComponent(owner.name)}`, { waitUntil: 'networkidle' });
  await page.getByTestId('staff-owners').getByRole('link', { name: owner.name }).click();
  await page.waitForURL(`**/staff/owners/${app.ownerId}`);
  const list = page.getByTestId('onboarding-checklist');
  await expect(list.locator('[data-step="terms"]')).toContainText('Waiting on an Admin');
  await expect(list.locator('[data-step="signatures"]')).toHaveAttribute('data-state', 'blocked');
  await expect(page.getByTestId('onboarding-photo')).toHaveCount(1);
  await expect(page.getByTestId('government-forms')).toContainText('once the terms are approved');
  await check(page, 'staff owner page');
  await sql.end();
});

test('the owner: the checklist on the car, a photo replaced, cars from a list of VINs', async ({ browser }) => {
  const sql = db();
  const owner = await mkUser(sql, 'plain', `Ola Owner${tag()}`);
  const app = await application(sql, owner);
  await permit(sql, owner.id, app.ownerId, app.vehicle);
  const page = await ctx(browser);
  await signIn(page, owner.email, '/owner');
  await page.goto(`/owner/vehicles/${app.vehicle}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('onboarding-checklist').locator('[data-step="terms"]')).toContainText('Waiting on CarmaCars');
  await page.getByTestId('onboarding-photo').first().getByTestId('onboarding-photo-replace').setInputFiles({ name: 'permit.jpg', mimeType: 'image/jpeg', buffer: FIXTURE_JPEG });
  await expect(page.getByTestId('onboarding-photo-msg')).toContainText('Replaced', { timeout: 30_000 });
  await check(page, 'owner car page');
  // cars from a list of VINs: two good, a typo and one twice
  const a = vin(); const b = vin();
  const typo = `${a.slice(0, 8)}${a[8] === '1' ? '2' : '1'}${a.slice(9)}`;
  await page.goto('/owner/vehicles', { waitUntil: 'networkidle' });
  await page.getByTestId('owner-add-cars').click();
  await page.waitForURL('**/owner/vehicles/add');
  await page.getByTestId('vin-list-text').fill([a, b, typo, a].join('\n'));
  await page.getByTestId('vin-list-preview').click();
  const rows = page.getByTestId('vin-list-row');
  await expect(rows).toHaveCount(4, { timeout: 30_000 });
  await expect(page.locator('[data-testid="vin-list-row"][data-ok="no"]')).toHaveCount(2);
  await expect(page.getByTestId('vin-list-table')).toContainText('check digit');
  await expect(page.getByTestId('vin-list-table')).toContainText('Listed twice');
  await check(page, 'owner add cars');
  await page.getByTestId('vin-list-create').click();
  await expect(page.getByTestId('vin-list-done')).toContainText('2 cars added', { timeout: 30_000 });
  expect((await sql`select count(*)::int n from vehicles where owner_id = ${app.ownerId}`)[0]!.n).toBe(3);
  await sql.end();
});
