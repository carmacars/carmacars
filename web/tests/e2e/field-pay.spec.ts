import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, pdfText } from './helpers';

// Field pay (migration 0165), end to end: a field staff member clocks in and out on the phone (My hours, the shift and its
// note); Fleet sees the shifts of the period; an Admin starts the pay run of the finished period, approves it, records the
// payment (the statement PDF, the CSV link, the email) and the field staff member sees the statement in My hours.
type Sql = ReturnType<typeof db>;
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text.match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(text, `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function mkUser(sql: Sql, role: 'admin' | 'va' | 'field', name: string) {
  const id = randomUUID(); const email = `fp.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'fleet', 0)`;
  if (role === 'field') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver')`;
  return { id, email, name };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 60_000 });
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
  const p = await c.newPage();
  p.on('dialog', (d) => void d.accept());
  return p;
}

test.describe.configure({ mode: 'serial' });
test.setTimeout(240_000);

test('field pay: clock in and out on the phone, Fleet sees the hours, an Admin runs, approves and pays the pay run', async ({ browser }) => {
  const sql = db();
  const phone = isPhone();
  const admin = await mkUser(sql, 'admin', 'Ada Admin');
  const fleet = await mkUser(sql, 'va', 'Val Fleet');
  const ann = await mkUser(sql, 'field', 'Ann Clock');
  const bob = await mkUser(sql, 'field', 'Bob Hours');
  // a finished pay period no other run (the other width, a retry) has used: an Admin can start and approve it now. Bob worked 8 h 30 min in it (entered by the office).
  let prev = '';
  for (let k = 1 + (parseInt(tag(), 16) % 380); !prev; k = k % 380 + 1) {
    const [per] = await sql`select to_char((select period_start from app.fp_period(app.today())) - 14 * ${k}::int, 'YYYY-MM-DD') as s,
      exists (select 1 from field_pay_runs where period_start = (select period_start from app.fp_period(app.today())) - 14 * ${k}::int and status <> 'void') as used`;
    if (!per!.used) prev = per!.s as string;
  }
  await sql`insert into field_shifts (staff_id, started_at, ended_at, source, note, created_by)
            values (${bob.id}, app.local_midnight(${prev}::date + 2) + interval '9 hours', app.local_midnight(${prev}::date + 2) + interval '17 hours 30 minutes', 'manual', 'Deliveries', ${admin.id})`;

  // 1. Ann clocks in and out on her phone
  const fp = await ctx(browser, true);
  await signIn(fp, ann.email, '/field');
  await fp.goto('/field/hours', { waitUntil: 'networkidle' });
  await expect(fp.getByTestId('clock-in')).toBeVisible();
  await check(fp, 'my hours, not clocked in');
  await fp.locator('#clk-note').fill('Starting at the lot');
  await fp.getByTestId('clock-in').click();
  await expect(fp.getByTestId('clock-out')).toBeVisible({ timeout: 30_000 });
  await expect(fp.getByTestId('clock-elapsed')).toBeVisible();
  const [open] = await sql`select note from field_shifts where staff_id = ${ann.id} and ended_at is null`;
  expect(open!.note).toBe('Starting at the lot');
  await check(fp, 'my hours, clocked in');
  await sql`update field_shifts set started_at = now() - interval '2 hours' where staff_id = ${ann.id} and ended_at is null`;
  await fp.reload({ waitUntil: 'networkidle' });
  await fp.locator('#clk-note').fill('All done');
  await fp.getByTestId('clock-out').click();
  await expect(fp.getByTestId('clock-in')).toBeVisible({ timeout: 30_000 });
  await expect(fp.getByTestId('recent-shifts')).toContainText('2 h');
  await expect(fp.getByTestId('hours-so-far')).toBeVisible();
  const [done] = await sql`select note, round(extract(epoch from ended_at - started_at) / 3600) as h from field_shifts where staff_id = ${ann.id}`;
  expect(done!.note).toBe('Starting at the lot / All done');
  expect(Number(done!.h)).toBe(2);
  await check(fp, 'my hours, after clocking out');
  await fp.context().close();

  // 2. Fleet sees the period's shifts and may fix them
  const vp = await ctx(browser, phone);
  await signIn(vp, fleet.email, '/va');
  await vp.goto(`/va/field-hours?date=${prev}`, { waitUntil: 'networkidle' });
  await expect(vp.getByTestId('shifts')).toContainText('Bob Hours');
  await expect(vp.getByTestId('shift-add')).toBeVisible();
  await check(vp, 'Fleet field hours');
  await vp.goto('/admin/money/field-pay', { waitUntil: 'networkidle' });
  await expect(vp).not.toHaveURL(/\/admin\/money\/field-pay$/);
  await vp.context().close();

  // 3. The Admin starts, approves and pays the pay run of the finished period
  const ap = await ctx(browser, phone);
  await signIn(ap, admin.email, '/admin');
  await ap.goto(`/admin/money/field-pay?date=${prev}`, { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('pay-note')).toContainText('accountant');
  await expect(ap.getByTestId('pay-lines')).toContainText('Bob Hours');
  await check(ap, 'pay run, not started');
  await ap.getByTestId('run-start').click();
  await expect(ap.getByTestId('run-approve')).toBeVisible({ timeout: 30_000 });
  await expect(ap.getByTestId('pay-lines')).toContainText('8 h 30 min');
  await expect(ap.getByTestId('pay-lines')).toContainText('$153.00');
  await ap.getByTestId('run-approve').click();
  await ap.getByTestId('run-approve-submit').click();
  const [line] = await sql`select l.id from field_pay_lines l join field_pay_runs r on r.id = l.run_id where l.staff_id = ${bob.id} and r.period_start = ${prev}::date and r.status <> 'void'`;
  await expect(ap.getByTestId(`pay-${line!.id}`)).toBeVisible({ timeout: 30_000 });
  await expect(ap.getByTestId(`statement-${line!.id}`)).toContainText('PS-');
  await ap.getByTestId(`pay-${line!.id}`).click();
  await ap.getByLabel(/^Reference/).fill('CAFP-E2E-1');
  await ap.getByTestId(`pay-${line!.id}-submit`).click();
  await expect(ap.getByTestId('pay-lines')).toContainText('CAFP-E2E-1', { timeout: 30_000 });
  await check(ap, 'pay run, paid');
  const [paid] = await sql`select l.status, l.reference, r.status as run_status from field_pay_lines l join field_pay_runs r on r.id = l.run_id where l.id = ${line!.id}`;
  expect(paid).toMatchObject({ status: 'paid', reference: 'CAFP-E2E-1', run_status: 'paid' });
  const [ev] = await sql`select count(*)::int as n from app_events where code = 'staff_pay_statement' and entity_id = ${line!.id}`;
  expect(ev!.n).toBe(1);
  const pdf = await ap.request.get(`/files/pay_statement/${line!.id}`);
  expect(pdf.ok()).toBe(true);
  const text = await pdfText(await pdf.body());
  expect(text).toContain('Pay statement');
  expect(text).toContain('Bob Hours');
  expect(text).toContain('$153.00');
  const runId = (await sql`select run_id from field_pay_lines where id = ${line!.id}`)[0]!.run_id as string;
  const csv = await ap.request.get(`/admin/money/field-pay/csv?run=${runId}`);
  expect(csv.ok()).toBe(true);
  expect(await csv.text()).toContain('Bob Hours');
  await ap.goto('/admin/money/field-pay?tab=rates', { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('rates')).toContainText('$18.00');
  await check(ap, 'hourly rates');
  await ap.context().close();

  // 4. Bob sees his statement
  const bp = await ctx(browser, true);
  await signIn(bp, bob.email, '/field');
  await bp.goto('/field/hours', { waitUntil: 'networkidle' });
  await expect(bp.getByTestId('pay-statements')).toContainText('$153.00');
  await expect(bp.getByTestId(`statement-${line!.id}`)).toBeVisible();
  await check(bp, 'my hours with a statement');
  await bp.context().close();
  await sql.end();
});
