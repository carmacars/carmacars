import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Release 50 (3720), end to end at phone width (375): a field staff member must choose whose money paid on Add, Money spent
// (nothing preselected; sending without it is refused on the form); own money is owed back to them ("Owed to you" on My
// shifts); Finance declines one with the reason and approves another on Field spending; the payroll lists what is owed per
// person with Mark paid back; the person sees it paid. Every page: no sideways scroll, no serious axe finding.
type Sql = ReturnType<typeof db>;
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text, `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function mkUser(sql: Sql, role: 'admin' | 'va' | 'field', name: string, fn?: string) {
  const id = randomUUID(); const email = `r50.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${fn ?? 'finance'}, 0)`;
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
async function phone(browser: Browser) {
  const c = await browser.newContext({ viewport: { width: 375, height: 812 }, hasTouch: true, baseURL: test.info().project.use.baseURL });
  const p = await c.newPage();
  p.on('dialog', (d) => void d.accept());
  return p;
}

test.describe.configure({ mode: 'serial' });
test.setTimeout(240_000);

test('whose money: chosen on the phone, owed back, declined with the reason, paid back from the payroll', async ({ browser }) => {
  test.skip(test.info().project.name !== 'phone-375', 'one run is enough: each page is opened at 375 wide inside');
  const sql = db();
  const t = tag();
  const ann = await mkUser(sql, 'field', `Ann Field ${t}`);
  const fin = await mkUser(sql, 'va', `Fay Finance ${t}`, 'finance');
  const admin = await mkUser(sql, 'admin', `Ada Admin ${t}`);

  // 1. the form: no choice made, nothing sent
  const fp = await phone(browser);
  await signIn(fp, ann.email, '/staff');
  await fp.goto('/staff/field', { waitUntil: 'networkidle' });
  const add = fp.getByTestId('add-button');
  if (await add.count()) {
    await add.click();
    await fp.getByTestId('add-money').click();
    await expect(fp.getByTestId('money-whose')).toBeVisible();
    await expect(fp.getByTestId('money-whose-own')).not.toBeChecked();
    await expect(fp.getByTestId('money-whose-company')).not.toBeChecked();
    await fp.locator('#m-amt').fill('40.00');
    await fp.getByTestId('money-save').click();
    await expect(fp.getByTestId('money-form')).toContainText('Choose whose money it was');
    await check(fp, 'the money form');
    await fp.getByText('My own money (pay me back)').click();
    await expect(fp.getByTestId('money-whose-own')).toBeChecked();
  }

  // 2. two own-money expenses as the form sends them (the database refuses one without the choice)
  await expect(sql`select app.fx_spend_add(${ann.id}::uuid, ${sql.json({ kind: 'gas', description: `Gas r50 ${t}`, amount_cents: 4000 })})`).rejects.toThrow(/Choose whose money/);
  await sql`select app.fx_spend_add(${ann.id}::uuid, ${sql.json({ kind: 'gas', description: `Gas r50 ${t}`, amount_cents: 4000, hst_cents: 520, paid_with: 'own' })})`;
  await sql`select app.fx_spend_add(${ann.id}::uuid, ${sql.json({ kind: 'parking', description: `Parking r50 ${t}`, amount_cents: 1500, paid_with: 'own' })})`;
  await fp.goto('/staff/field/shifts#owed', { waitUntil: 'networkidle' });
  await expect(fp.getByTestId('owed-to-you')).toContainText('$60.20');
  await expect(fp.getByTestId('owed-to-you')).toContainText('Waiting for Finance');
  await check(fp, 'My shifts, Owed to you');

  // 3. Finance: decline one with the reason, approve the other
  const vp = await phone(browser);
  await signIn(vp, fin.email, '/staff');
  await vp.goto('/staff/field-spending', { waitUntil: 'networkidle' });
  const [park] = await sql<Array<{ id: string }>>`select id from field_spends where description = ${`Parking r50 ${t}`}`;
  const [gas] = await sql<Array<{ id: string }>>`select id from field_spends where description = ${`Gas r50 ${t}`}`;
  await vp.getByTestId(`spend-decline-${park!.id}`).click();
  await expect(vp.getByTestId('field-spending')).toContainText('Say why it is declined');
  await vp.getByTestId(`spend-reason-${park!.id}`).fill('Personal parking');
  await vp.getByTestId(`spend-decline-${park!.id}`).click();
  await vp.getByTestId(`spend-approve-${gas!.id}`).click();
  await expect(vp.getByTestId('reimbursements')).toContainText(ann.name, { timeout: 20_000 });
  await check(vp, 'Finance, Field spending');
  const [st] = await sql<Array<{ p: string; g: string }>>`select (select status from staff_reimbursements where field_spend_id = ${park!.id}) p, (select status from staff_reimbursements where field_spend_id = ${gas!.id}) g`;
  expect(`${st!.p}/${st!.g}`).toBe('declined/owed');

  // 4. the payroll's payout list: Mark paid back
  const ap = await phone(browser);
  await signIn(ap, admin.email, '/admin');
  await ap.goto('/admin/money/field-pay', { waitUntil: 'networkidle' });
  await expect(ap.getByTestId(`reimb-${ann.id}`)).toContainText('$45.20 owed');
  await check(ap, 'Admin, Payroll');
  const [rb] = await sql<Array<{ id: string }>>`select id from staff_reimbursements where field_spend_id = ${gas!.id}`;
  await ap.getByTestId(`reimb-paid-${rb!.id}`).click();
  await expect(ap.getByTestId(`reimb-${ann.id}`)).toHaveCount(0, { timeout: 20_000 });

  // 5. the person sees it paid, and the decline with its reason
  await fp.goto('/staff/field/shifts#owed', { waitUntil: 'networkidle' });
  await expect(fp.getByTestId('owed-to-you')).toContainText('Paid back');
  await expect(fp.getByTestId('owed-to-you')).toContainText('Personal parking');
  const codes = await sql<Array<{ code: string }>>`select distinct code from app_events where code like 'staff_expense_%' and payload ->> 'staff_id' = ${ann.id}`;
  expect(codes.map((c) => c.code).sort()).toEqual(['staff_expense_approved', 'staff_expense_declined', 'staff_expense_submitted']);
  await sql.end();
});
