import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow, pdfText } from './helpers';

// Owner terms and invoices (migration 0067), end to end at 375 and 1440:
//   Approve with custom terms and the first and last month recorded as paid by e-Transfer, a registration fee sent to the
//   cent; the owner portal shows the exact amounts; a registration fee invoice of an exact amount made from the owner's
//   Invoices tab; void and reissue at the right amount; the terms of a signed car changed, the updated Vehicle Schedule
//   signed by the owner; a car added for an owner by customer service, approved by an Admin, the owner's one set-up email
//   with the link to choose a password; "Add another car". Every page is checked with axe, for overflow and the copy rules.
// No real person is emailed: the local stack only writes the emails' events.
const SHOTS = 'test-results/owner-terms';
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
const plate = () => `OT${randomBytes(2).toString('hex').toUpperCase()}`;
const shot = (page: Page, name: string) => page.screenshot({ path: `${SHOTS}/${test.info().project.name}-${name}.png`, fullPage: true });

async function mkUser(sql: Sql, kind: 'admin' | 'cs' | 'plain', name: string) {
  const id = randomUUID(); const email = `${kind}.ot.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  if (kind === 'cs') { await sql`insert into user_roles (user_id, role) values (${id}, 'va')`; await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'cs')`; }
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
async function application(sql: Sql, who: { id: string; email: string; name: string }) {
  const [first, ...rest] = who.name.split(' ');
  const r = await sql`select public.server_submit_owner_application(${sql.json({ source: 'web',
    owner: { owner_type: 'individual', legal_name: who.name, first_name: first, last_name: rest.join(' '), email: who.email, phone: '+16475550133', address_line1: '30 King Street West',
             city: 'Toronto', province: 'ON', postal_code: 'M5H 1A1', licence_number: `O${randomBytes(2).toString('hex').toUpperCase()}4-56789-01234`, date_of_birth: '1990-01-01' },
    vehicles: [{ vin: vin(), plate: plate(), year: 2022, make: 'Honda', model: 'CR-V', colour: 'Blue', odometer_km: 30000, management_mode: 'managed', onboarding_method: 'transfer',
                 current_insurer: 'Aviva', title_status: 'owned_outright', title_brand_clear: true }] })}, ${who.id}) r`;
  const ownerId = (r[0]!.r as { owner_id: string }).owner_id;
  const [a] = await sql`select id, application_number from owner_applications where owner_id = ${ownerId} order by created_at desc limit 1`;
  return { ownerId, appId: a!.id as string, number: a!.application_number as string };
}
const inv = async (sql: Sql, where: string, ownerId: string) =>
  (await sql.unsafe(`select invoice_number, kind, status, total_cents::int total, fees_cents::int fees, hst_cents::int hst, title from owner_invoices where owner_id = $1 and ${where} order by invoice_number`, [ownerId])) as unknown as Array<{ invoice_number: string; kind: string; status: string; total: number; fees: number; hst: number; title: string | null }>;

test.describe.configure({ mode: 'serial' });

test('approve with custom terms, the first and last paid by e-Transfer, a registration fee to the cent; the owner sees the exact amounts', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Ot Admin');
  const owner = await mkUser(sql, 'plain', `Ola Owner${tag()}`);
  const app = await application(sql, owner);
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/applications/${app.appId}`, { waitUntil: 'networkidle' });
  await page.getByTestId('app-approve').click();
  const step = page.getByTestId('approve-step');
  await page.waitForLoadState('networkidle');
  await expect(step).toBeVisible();
  await expect(step.getByTestId('approve-insurance')).toHaveValue('450.00');
  await expect(step.getByTestId('approve-first-last')).toHaveValue('900.00');
  await check(page, 'approve step');
  // negotiated: $380 a month, 30%, first and last agreed at exactly $725.50
  await step.getByTestId('approve-insurance').fill('380.00');
  await step.getByTestId('approve-share').fill('30');
  await expect(step.getByTestId('approve-insurance')).toHaveValue('380.00');
  await expect(step.getByTestId('approve-first-last')).toHaveValue('760.00');
  await step.getByTestId('approve-first-last').fill('725.50');
  await expect(step.getByTestId('approve-inv-first-last-amount')).toHaveValue('725.50');
  await expect(step.getByTestId('approve-share')).toHaveValue('30');
  await step.getByTestId('approve-inv-first-last-paid').check();
  await step.getByTestId('approve-inv-first-last-method').selectOption('e_transfer');
  await step.getByTestId('approve-inv-first-last-reference').fill('CAxE2E725');
  await step.getByTestId('approve-inv-registration-on').check();
  await step.getByTestId('approve-inv-registration-amount').fill('123.45');
  await expect(step.getByTestId('approve-inv-registration-total')).toHaveText('$139.50');
  await step.getByTestId('approve-inv-registration-send').check();
  await expect(step.getByTestId('approve-inv-first-last-total')).toHaveText('$819.82');
  await expect(step.getByTestId('approve-inv-first-last-reference')).toHaveValue('CAxE2E725');
  await shot(page, 'approve-step');
  await step.getByTestId('approve-confirm').click();
  await expect(page.getByTestId('app-approved')).toBeVisible({ timeout: 30_000 });
  await expect.poll(async () => (await inv(sql, `true`, app.ownerId)).length, { timeout: 15_000 }).toBe(2);
  const rows = await inv(sql, `true`, app.ownerId);
  // 0077: the first and last month invoice is made by the Admin's choice, after the other invoices of the step
  expect(rows.map((r) => `${r.kind}:${r.status}:${r.total}`).sort()).toEqual(['custom:issued:13950', 'upfront:paid:81982']);
  const [s] = await sql`select s.insurance_fee_cents::int ins, s.revenue_share_bps share, s.first_last_cents::int fl from vehicle_schedules s join vehicles v on v.id = s.vehicle_id where v.owner_id = ${app.ownerId} and s.superseded_by is null`;
  expect(`${s!.ins}/${s!.share}/${s!.fl}`).toBe('38000/3000/72550');
  const [m] = await sql`select method, reference from manual_payments m join owner_invoices i on i.id = m.owner_invoice_id where i.owner_id = ${app.ownerId}`;
  expect(`${m!.method}/${m!.reference}`).toBe('e_transfer/CAxE2E725');
  const ev = await sql`select code from app_events where payload ->> 'owner_id' = ${app.ownerId} and code in ('owner_upfront_invoice', 'owner_invoice_issued', 'owner_payment_recorded', 'owner_application_approved') order by code`;
  expect(ev.map((e) => e.code)).toEqual(['owner_application_approved', 'owner_invoice_issued', 'owner_payment_recorded']);
  // the application's Invoices tab
  await page.goto(`/admin/applications/${app.appId}?tab=invoices`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('app-invoice-list').locator('li')).toHaveCount(2);
  await check(page, 'application invoices');
  // the owner portal: the agreed amounts, nothing at the old default
  const op = await ctx(browser);
  await signIn(op, owner.email, '/owner');
  await op.goto('/owner/invoices', { waitUntil: 'networkidle' });
  await expect(op.locator('body')).toContainText('$819.82');
  await expect(op.locator('body')).toContainText('Registration fee');
  await op.goto(`/owner/invoices/${rows.find((r) => r.kind === 'custom')!.invoice_number}`, { waitUntil: 'networkidle' });
  await expect(op.getByTestId('invoice-lines')).toContainText('$123.45');
  await expect(op.getByTestId('invoice-total')).toHaveText('$139.50');
  await check(op, 'owner invoice');
  await op.goto('/owner/review', { waitUntil: 'networkidle' });
  await expect(op.getByTestId('review-first-last')).toHaveText('$725.50');
  await check(op, 'owner review');
  await shot(op, 'owner-review');
  await op.context().close();
  await page.context().close();
  await sql.end();
});

test('a registration fee invoice of an exact amount from the owner page; void and reissue at the right amount; the PDF', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Ot Admin Two');
  const owner = await mkUser(sql, 'plain', `Rita Registration${tag()}`);
  const app = await application(sql, owner);
  await sql`select public.door(${admin.id}, null, 'ops_do', 'application_approve', ${sql.json({ id: app.appId })})`;
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/owners/${app.ownerId}?tab=invoices`, { waitUntil: 'networkidle' });
  await check(page, 'owner invoices tab');
  await page.getByTestId('invoice-new').click();
  await page.waitForURL(/\/admin\/invoices\/new/);
  const ed = page.getByTestId('invoice-editor');
  await ed.getByTestId('invoice-title').fill('Registration fee');
  await ed.getByTestId('line-description').first().fill('ServiceOntario registration');
  await ed.getByTestId('line-unit').first().fill('123.45');
  await ed.getByTestId('line-add').click();
  await ed.getByTestId('line-description').nth(1).fill('Plate stickers');
  await ed.getByTestId('line-quantity').nth(1).fill('2');
  await ed.getByTestId('line-unit').nth(1).fill('12.34');
  await ed.getByTestId('line-hst').nth(1).uncheck();
  await expect(ed.getByTestId('invoice-subtotal')).toHaveText('$148.13');
  await expect(ed.getByTestId('invoice-total')).toHaveText('$164.18');
  await check(page, 'new invoice');
  await shot(page, 'new-invoice');
  await ed.getByTestId('invoice-save').click();
  await page.waitForURL(/\/admin\/invoices\/INV-\d+\?saved=1/, { timeout: 20_000 });
  const number = page.url().match(/INV-\d+/)![0];
  await expect(page.getByTestId('invoice-draft')).toBeVisible();
  expect((await inv(sql, `invoice_number = '${number}'`, app.ownerId))[0]!.status).toBe('draft');
  // a draft is never in the owner portal
  const op = await ctx(browser);
  await signIn(op, owner.email, '/owner');
  await op.goto('/owner/invoices', { waitUntil: 'networkidle' });
  await expect(op.locator('body')).not.toContainText(number);
  // issue
  await page.getByTestId('invoice-issue').click();
  await expect(page.getByTestId('invoice-lines-view')).toBeVisible({ timeout: 20_000 });
  await expect(page.getByTestId('invoice-detail-total')).toHaveText('$164.18');
  await check(page, 'issued invoice');
  const pdf = await page.request.get(`/files/owner_invoice/${(await sql`select id from owner_invoices where invoice_number = ${number}`)[0]!.id}`);
  expect(pdf.status()).toBe(200);
  const text = await pdfText(await pdf.body());
  expect(text).toContain('ServiceOntario registration');
  expect(text).toContain('$164.18');
  // void and reissue: the corrected draft opens; the fee was $120.00
  await page.getByTestId('invoice-void-open').click();
  await page.getByTestId('invoice-void-reason').fill('The registration fee was $120.00, not $123.45.');
  await page.getByTestId('invoice-void-send').click();
  await page.waitForURL(/replaces=/, { timeout: 20_000 });
  await expect(page.getByTestId('invoice-replacement-note')).toContainText(number);
  const fixed = page.url().match(/INV-\d+/)![0];
  await page.getByTestId('line-unit').first().fill('120.00');
  await page.getByTestId('invoice-save-issue').click();
  await expect(page.getByTestId('invoice-lines-view')).toBeVisible({ timeout: 20_000 });
  const both = await inv(sql, `invoice_number in ('${number}', '${fixed}')`, app.ownerId);
  expect(both.map((r) => `${r.status}:${r.total}`)).toEqual(['void:16418', 'issued:16028']);
  const ev = await sql`select code from app_events where entity_id in (select id from owner_invoices where invoice_number in (${number}, ${fixed})) order by id`;
  expect(ev.map((e) => e.code)).toEqual(['owner_invoice_issued', 'owner_invoice_voided', 'owner_invoice_issued']);
  // the owner: the void with its reason, the replacement
  await op.goto(`/owner/invoices/${number}`, { waitUntil: 'networkidle' });
  await expect(op.getByTestId('invoice-void')).toContainText(fixed);
  await check(op, 'owner void invoice');
  await op.goto(`/owner/invoices/${fixed}`, { waitUntil: 'networkidle' });
  await expect(op.getByTestId('invoice-total')).toHaveText('$160.28');
  // record a cash payment: paid, the receipt
  await page.goto(`/admin/invoices/${fixed}`, { waitUntil: 'networkidle' });
  await page.getByTestId(`offline-${fixed}`).click();
  await page.getByTestId('manual-payment-form').locator('select[name="method"]').selectOption('cash');
  await page.getByTestId('manual-payment-form').getByRole('button', { name: 'Record payment' }).click();
  await expect.poll(async () => (await inv(sql, `invoice_number = '${fixed}'`, app.ownerId))[0]!.status, { timeout: 20_000 }).toBe('paid');
  await expect(page.getByTestId('invoice-payments')).toContainText('Receipt');
  await page.goto('/admin/invoices?status=void', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('admin-invoices')).toContainText(number);
  await check(page, 'money owner invoices');
  await op.context().close();
  await page.context().close();
  await sql.end();
});

test('terms of a signed car: the warning, one click for the updated Vehicle Schedule, the owner signs it', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Ot Admin Three');
  const owner = await mkUser(sql, 'plain', `Sam Signed${tag()}`);
  const app = await application(sql, owner);
  await sql`select public.door(${admin.id}, null, 'ops_do', 'application_approve', ${sql.json({ id: app.appId })})`;
  await sql`update vehicle_schedules s set signed_at = now() from vehicles v where v.id = s.vehicle_id and v.owner_id = ${app.ownerId} and s.superseded_by is null`;
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/owners/${app.ownerId}?tab=terms`, { waitUntil: 'networkidle' });
  await check(page, 'terms tab');
  const car = page.getByTestId('terms-car').first();
  await car.locator('summary').click();
  const form = car.getByTestId('terms-car-form');
  await form.getByTestId('terms-insurance_fee_cents').fill('410.00');
  await form.getByTestId('terms-save').click();
  await expect(form.getByTestId('terms-resign-warning')).toBeVisible({ timeout: 20_000 });
  await shot(page, 'terms-warning');
  expect((await sql`select count(*)::int n from vehicle_term_changes c join vehicles v on v.id = c.vehicle_id where v.owner_id = ${app.ownerId}`)[0]!.n).toBe(0);
  await form.getByTestId('terms-resign').click();
  await expect(form.getByTestId('terms-saved')).toBeVisible({ timeout: 20_000 });
  const [c] = await sql`select c.id, c.status from vehicle_term_changes c join vehicles v on v.id = c.vehicle_id where v.owner_id = ${app.ownerId}`;
  expect(c!.status).toBe('awaiting_signature');
  expect((await sql`select count(*)::int n from app_events where code = 'owner_schedule_resign' and entity_id = ${c!.id}`)[0]!.n).toBe(1);
  const op = await ctx(browser);
  await signIn(op, owner.email, '/owner');
  await op.goto('/owner', { waitUntil: 'networkidle' });
  await expect(op.getByTestId('owner-next-step')).toContainText('updated Vehicle Schedule');
  await op.getByTestId('owner-next-step').getByRole('link', { name: 'Read and sign' }).click();
  await op.waitForURL(/\/owner\/sign\/schedule\//);
  await expect(op.getByTestId('schedule-compare')).toContainText('$410.00');
  await check(op, 'schedule sign');
  await shot(op, 'schedule-sign');
  await op.getByTestId('schedule-agree').check();
  await op.getByTestId('schedule-name').fill(owner.name);
  await op.getByTestId('schedule-sign-submit').click();
  await expect(op.getByTestId('schedule-signed')).toBeVisible({ timeout: 20_000 });
  const [s] = await sql`select s.insurance_fee_cents::int ins, s.signed_at is not null signed from vehicle_schedules s join vehicles v on v.id = s.vehicle_id where v.owner_id = ${app.ownerId} and s.superseded_by is null`;
  expect(`${s!.ins}/${s!.signed}`).toBe('41000/true');
  await op.context().close();
  await page.context().close();
  await sql.end();
});

test('customer service adds a car for a new owner; an Admin approves; one set-up email with the password link; Add another car', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Ot Admin Four');
  const cs = await mkUser(sql, 'cs', 'Carla Service');
  const email = `nadia.${tag()}@example.test`;
  const page = await ctx(browser);
  await signIn(page, cs.email, '/va');
  await page.goto('/va/owners/add-car', { waitUntil: 'networkidle' });
  await check(page, 'va add car');
  const f = page.getByTestId('addcar');
  await f.getByTestId('addcar-new-owner').check();
  await f.getByTestId('addcar-legal_name').fill('Nadia Newowner');
  await f.getByTestId('addcar-email').fill(email);
  await f.getByTestId('addcar-phone').fill('+16475550188');
  await f.getByTestId('addcar-vin').fill(vin());
  await f.getByTestId('addcar-year').fill('2021');
  await f.getByTestId('addcar-make').fill('Toyota');
  await f.getByTestId('addcar-model').fill('Corolla');
  await f.getByTestId('addcar-plate').fill(plate());
  await f.getByTestId('addcar-doc-ownership_permit').setInputFiles({ name: 'permit.png', mimeType: 'image/png', buffer: Buffer.from('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da63f8ffff3f0005fe02fea7d6a4c20000000049454e44ae426082', 'hex') });
  await f.getByTestId('addcar-terms-ins').fill('420.00');
  await shot(page, 'va-add-car');
  await f.getByTestId('addcar-submit').click();
  await expect(page.getByTestId('addcar-done')).toContainText('Sent to an Admin', { timeout: 30_000 });
  const [a] = await sql`select a.id, a.status, a.entered_by_name, a.owner_id from owner_applications a join owners o on o.id = a.owner_id where o.email = ${email}`;
  expect(`${a!.status}/${a!.entered_by_name}`).toBe('new/Carla Service');
  expect((await sql`select count(*)::int n from documents where owner_id = ${a!.owner_id} and kind = 'ownership_permit'`)[0]!.n).toBe(1);
  expect((await sql`select count(*)::int n from app_events where payload ->> 'owner_id' = ${a!.owner_id} and code = 'owner_application_received' and processed_at is null`)[0]!.n).toBe(0);
  // the Admin approves with what customer service proposed
  const ap = await ctx(browser);
  await signIn(ap, admin.email, '/admin');
  await ap.goto(`/admin/applications/${a!.id}`, { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('app-entered-by')).toContainText('Carla Service');
  await ap.getByTestId('app-approve').click();
  await expect(ap.getByTestId('approve-insurance')).toHaveValue('420.00');
  await expect(ap.getByTestId('approve-first-last')).toHaveValue('840.00');
  await check(ap, 'approve staff entry');
  await ap.getByTestId('approve-confirm').click();
  await expect(ap.getByTestId('app-approved')).toBeVisible({ timeout: 30_000 });
  const ev = await sql`select code, payload ->> 'password_url' url from app_events where entity_id = ${a!.id} and code in ('owner_car_set_up', 'owner_application_approved')`;
  expect(ev.map((e) => e.code)).toEqual(['owner_car_set_up']);
  expect(ev[0]!.url).toMatch(/\/update-password\?token=/);
  const [o] = await sql`select user_id from owners where id = ${a!.owner_id}`;
  expect(o!.user_id).not.toBeNull();
  // "Add another car": the owner pre-filled, their terms from the first car
  await ap.goto(`/admin/owners/${a!.owner_id}`, { waitUntil: 'networkidle' });
  await ap.getByTestId('owner-add-car').click();
  await ap.waitForURL(/add-car\?owner=/);
  await expect(ap.getByTestId('addcar-owner')).toContainText('Nadia Newowner');
  await expect(ap.getByTestId('addcar-terms-ins')).toHaveValue('420.00', { timeout: 15_000 });
  await check(ap, 'add another car');
  await page.context().close();
  await ap.context().close();
  await sql.end();
});
