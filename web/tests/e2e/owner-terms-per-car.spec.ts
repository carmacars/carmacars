import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow, pdfText } from './helpers';

// Owner terms per car (migration 0135), end to end at 375 and 1440:
//   an owner's page shows every car with its Insurance Fee, Tracker Fee, management fee, Install Fee, mode and since when;
//   a signed, enrolled car: one edit lowers the Insurance Fee at once and raises the management fee (the review first,
//   then the notice and an updated schedule for the owner); History with the periods, the changes and the notice PDF;
//   the owner portal shows which terms apply to which car and from when, the change coming and the notice; the Admin
//   withdraws the schedule. Before signing: the Approve step copies one car's terms to every car, the table edits an
//   unsigned schedule at once, and the car page has the same editor. Every page is checked with axe, for overflow and
//   the copy rules. No real person is emailed: the local stack only writes the emails' events.
const SHOTS = 'test-results/owner-terms-per-car';
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
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
const vin = () => `2T3W1RFV${randomBytes(5).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
const plate = () => `PC${randomBytes(2).toString('hex').toUpperCase()}`;
const shot = (page: Page, name: string) => page.screenshot({ path: `${SHOTS}/${test.info().project.name}-${name}.png`, fullPage: true });

async function mkUser(sql: Sql, kind: 'admin' | 'plain', name: string) {
  const id = randomUUID(); const email = `${kind}.pc.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
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
async function application(sql: Sql, who: { id: string; email: string; name: string }, cars = 1) {
  const [first, ...rest] = who.name.split(' ');
  const vehicles = Array.from({ length: cars }, (_, i) => ({ vin: vin(), plate: plate(), year: 2022, make: i ? 'Toyota' : 'Honda', model: i ? 'RAV4' : 'CR-V', colour: 'Blue', odometer_km: 30000,
    management_mode: 'managed', onboarding_method: 'transfer', current_insurer: 'Aviva', title_status: 'owned_outright', title_brand_clear: true }));
  const r = await sql`select public.server_submit_owner_application(${sql.json({ source: 'web',
    owner: { owner_type: 'individual', legal_name: who.name, first_name: first, last_name: rest.join(' '), email: who.email, phone: '+16475550144', address_line1: '30 King Street West',
             city: 'Toronto', province: 'ON', postal_code: 'M5H 1A1', licence_number: `P${randomBytes(2).toString('hex').toUpperCase()}4-56789-01234`, date_of_birth: '1990-01-01' },
    vehicles })}, ${who.id}) r`;
  const ownerId = (r[0]!.r as { owner_id: string }).owner_id;
  const [a] = await sql`select id from owner_applications where owner_id = ${ownerId} order by created_at desc limit 1`;
  const vs = await sql`select id from vehicles where owner_id = ${ownerId} order by created_at, id`;
  return { ownerId, appId: a!.id as string, vehicles: vs.map((v) => v.id as string) };
}

test.describe.configure({ mode: 'serial' });
test.setTimeout(180_000);

test('a signed car: lower the Insurance Fee at once and raise the management fee by notice and signature; History, the notice, the owner portal', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Pc Admin');
  const owner = await mkUser(sql, 'plain', `Lena Lowered${tag()}`);
  const app = await application(sql, owner);
  const car = app.vehicles[0]!;
  await sql`select public.door(${admin.id}, null, 'ops_do', 'application_approve', ${sql.json({ id: app.appId, cars: [{ vehicle_id: car,
    terms: { insurance_fee_cents: 38000, tracker_fee_cents: 2500, revenue_share_bps: 3000, install_fee_cents: 10000 }, first_last: { action: 'none' } }] })})`;
  // signed and enrolled on September 1: its fee terms run from then
  await sql`update vehicle_schedules set signed_at = now(), enrollment_date = '2026-09-01' where vehicle_id = ${car} and superseded_by is null`;
  await sql`update vehicles set enrollment_date = '2026-09-01' where id = ${car}`;
  await sql`insert into vehicle_fee_history (vehicle_id, vehicle_schedule_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from)
            select ${car}, s.id, 'signed_schedule', s.insurance_fee_cents, s.tracker_fee_cents, s.revenue_share_bps, '2026-09-01' from vehicle_schedules s where s.vehicle_id = ${car} and s.superseded_by is null`;
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/owners/${app.ownerId}`, { waitUntil: 'networkidle' });
  const table = page.getByTestId('car-terms');
  const row = table.getByTestId('car-terms-row').first();
  await expect(row.getByTestId('car-terms-insurance-value')).toHaveText('$380.00');
  await expect(row.getByTestId('car-terms-share-value')).toHaveText('30%');
  await expect(row.getByTestId('car-terms-state')).toContainText('Signed');
  await check(page, 'owner page terms table');
  await shot(page, 'owner-table');
  // one edit: $350 insurance (lower) and 35% (higher)
  await row.getByTestId('car-terms-edit').click();
  await row.getByTestId('car-terms-insurance').fill('350.00');
  await row.getByTestId('car-terms-share').fill('35');
  const panel = table.getByTestId('car-terms-panel');
  await panel.getByTestId('car-terms-review').click();
  const plan = panel.getByTestId('car-terms-plan');
  await expect(plan).toContainText('No notice period', { timeout: 20_000 });
  await expect(plan).toContainText('owner\'s signature');
  await expect(panel.getByTestId('car-terms-raise-from')).toBeVisible();
  expect((await sql`select count(*)::int n from vehicle_term_changes where vehicle_id = ${car}`)[0]!.n).toBe(0);
  await panel.getByTestId('car-terms-reason').fill('Program terms for 2027');
  await check(page, 'terms review');
  await shot(page, 'review');
  await panel.getByTestId('car-terms-confirm').click();
  await expect(table.getByTestId('car-terms-done')).toBeVisible({ timeout: 20_000 });
  const ch = await sql`select kind, status, effective_from::text f from vehicle_term_changes where vehicle_id = ${car} order by created_at, kind`;
  expect(ch.map((c) => `${c.kind}:${c.status}`)).toEqual(['decrease:applied', 'new_schedule:awaiting_signature']);
  const [today] = await sql`select app.today()::text t`;
  expect((await sql`select insurance_fee_cents::int i, revenue_share_bps s from app.vehicle_terms(${car}, app.today())`)[0]).toEqual({ i: 35000, s: 3000 });
  expect(ch[1]!.f > today!.t).toBe(true);
  await expect(row.getByTestId('car-terms-insurance-value')).toHaveText('$350.00');
  // History: the periods, the changes, the notice as a PDF
  await row.getByTestId('car-terms-history-toggle').click();
  const hist = table.getByTestId('car-terms-history');
  await expect(hist.getByTestId('car-terms-period')).toHaveCount(2);
  await expect(hist.getByTestId('car-terms-change')).toHaveCount(2);
  await check(page, 'terms history');
  await shot(page, 'history');
  const href = await hist.getByTestId('car-terms-notice').first().getAttribute('href');
  const pdf = await page.request.get(href!);
  expect(pdf.ok()).toBe(true);
  const text = await pdfText(await pdf.body());
  expect(text).toMatch(/Notice of (lower terms|a change to terms)/);
  expect(text).toContain('$350.00');
  // the owner portal: which terms apply to which car and from when; the change coming; the notice
  const op = await ctx(browser);
  await signIn(op, owner.email, '/owner');
  await op.goto('/owner/vehicles', { waitUntil: 'networkidle' });
  const ot = op.getByTestId('owner-terms');
  await expect(ot.getByTestId('owner-terms-row')).toHaveCount(1);
  await expect(ot).toContainText('$350.00');
  await expect(ot).toContainText('Updated Vehicle Schedule to sign');
  await check(op, 'owner portal terms');
  await shot(op, 'owner-terms');
  await op.goto(`/owner/vehicles/${car}`, { waitUntil: 'networkidle' });
  const oh = op.getByTestId('owner-terms-history');
  await expect(oh).toContainText('In force: $350.00 insurance');
  await oh.locator('summary').click();
  await expect(oh.getByTestId('owner-terms-change')).toHaveCount(2);
  await check(op, 'owner vehicle terms');
  const own = await op.request.get(`/files/terms_notice/${(await sql`select id from vehicle_term_changes where vehicle_id = ${car} and kind = 'decrease'`)[0]!.id}`);
  expect(own.ok()).toBe(true);
  await op.context().close();
  // the Admin withdraws the updated schedule: the share stays
  await page.goto(`/admin/owners/${app.ownerId}?tab=terms`, { waitUntil: 'networkidle' });
  const r2 = page.getByTestId('car-terms').getByTestId('car-terms-row').first();
  await r2.getByTestId('car-terms-history-toggle').click();
  const h2 = page.getByTestId('car-terms-history');
  await h2.getByTestId('car-terms-cancel').first().click();
  await h2.getByTestId('car-terms-cancel-reason').fill('The owner asked to keep 30%');
  await h2.getByTestId('car-terms-cancel-confirm').click();
  await expect.poll(async () => (await sql`select status from vehicle_term_changes where vehicle_id = ${car} and kind = 'new_schedule'`)[0]!.status, { timeout: 20_000 }).toBe('cancelled');
  await check(page, 'terms tab after withdraw');
  await page.context().close();
  await sql.end();
});

test('before signing: the Approve step copies one car\'s terms to every car; the table edits an unsigned schedule at once; the car page has the same editor', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Pc Admin Two');
  const owner = await mkUser(sql, 'plain', `Theo Twocars${tag()}`);
  const app = await application(sql, owner, 2);
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  // not approved yet: the table says so and keeps the numbers for the Approve step
  await page.goto(`/admin/owners/${app.ownerId}`, { waitUntil: 'networkidle' });
  const rows = page.getByTestId('car-terms').getByTestId('car-terms-row');
  await expect(rows).toHaveCount(2);
  const honda = rows.filter({ hasText: 'Honda' });
  await expect(honda.getByTestId('car-terms-state')).toContainText('Not approved yet');
  await honda.getByTestId('car-terms-edit').click();
  await honda.getByTestId('car-terms-share').fill('28');
  await page.getByTestId('car-terms-panel').getByTestId('car-terms-review').click();
  await expect(page.getByTestId('car-terms-plan')).toContainText('Approve step', { timeout: 20_000 });
  await page.getByTestId('car-terms-panel').getByTestId('car-terms-confirm').click();
  await expect(page.getByTestId('car-terms-done')).toBeVisible({ timeout: 20_000 });
  await expect(honda.getByTestId('car-terms-share-value')).toHaveText('28%');
  // the Approve step: car 1 starts at 28%; "Use these terms for every car" copies car 1 to car 2
  await page.goto(`/admin/applications/${app.appId}`, { waitUntil: 'networkidle' });
  await page.getByTestId('app-approve').click();
  const step = page.getByTestId('approve-step');
  await expect(step.getByTestId('approve-car').filter({ hasText: 'Honda' }).getByTestId('approve-share')).toHaveValue('28');
  await step.getByTestId('approve-insurance').first().fill('375.00');
  await step.getByTestId('approve-share').first().fill('28');
  await step.getByTestId('approve-same-terms').click();
  await expect(step.getByTestId('approve-insurance').nth(1)).toHaveValue('375.00');
  await expect(step.getByTestId('approve-share').nth(1)).toHaveValue('28');
  await check(page, 'approve same terms');
  await shot(page, 'approve-same');
  for (const c of await step.getByTestId('approve-inv-first-last-on').all()) if (await c.isChecked()) await c.uncheck();
  await step.getByTestId('approve-confirm').click();
  await expect(page.getByTestId('app-approved')).toBeVisible({ timeout: 30_000 });
  const sch = await sql`select s.insurance_fee_cents::int i, s.revenue_share_bps b from vehicle_schedules s where s.vehicle_id = any (${app.vehicles}) and s.superseded_by is null order by s.vehicle_id`;
  expect(sch.map((x) => `${x.i}/${x.b}`)).toEqual(['37500/2800', '37500/2800']);
  // approved, not signed: the car page's editor writes the unsigned schedule at once
  await page.goto(`/admin/vehicles/${app.vehicles[1]}?tab=records`, { waitUntil: 'networkidle' });
  const vt = page.getByTestId('vehicle-terms');
  await expect(vt.getByTestId('car-terms-state')).toContainText('not signed yet');
  await vt.getByTestId('car-terms-edit').click();
  await vt.getByTestId('car-terms-tracker').fill('20.00');
  await vt.getByTestId('car-terms-review').click();
  await expect(vt.getByTestId('car-terms-plan')).toContainText('not signed yet', { timeout: 20_000 });
  await check(page, 'car page terms');
  await vt.getByTestId('car-terms-confirm').click();
  await expect(vt.getByTestId('car-terms-done')).toBeVisible({ timeout: 20_000 });
  expect((await sql`select tracker_fee_cents::int t, signed_at is null u from vehicle_schedules where vehicle_id = ${app.vehicles[1]!} and superseded_by is null`)[0]).toEqual({ t: 2000, u: true });
  expect((await sql`select count(*)::int n from vehicle_term_changes where vehicle_id = ${app.vehicles[1]!}`)[0]!.n).toBe(0);
  await shot(page, 'car-page');
  await page.context().close();
  await sql.end();
});
