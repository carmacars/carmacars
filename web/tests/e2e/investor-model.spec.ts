import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow, pdfText } from './helpers';

// The model spreadsheets, live (migration 0420), at 375 and 1440 with axe: an investor's Live sheets (their investment from
// their records, the calculator, how it works, fund a car), a payout recorded showing as Paid on the next view, the Excel
// and PDF downloads (investor-safe only); an Admin's Company model (forecast, actuals, pro forma, assumptions, the internal
// Excel); Finance and investors refused the internal model. Fictional people only (example.test).
const SHOTS = 'test-results/investor-model';
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
mkdirSync(SHOTS, { recursive: true });

const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;
const shot = (page: Page, name: string) => page.screenshot({ path: `${SHOTS}/${test.info().project.name}-${name}.png`, fullPage: true });
const tag = () => `${Date.now()}${randomBytes(2).toString('hex')}`;

async function mkUser(sql: Sql, kind: 'investor' | 'admin' | 'finance', name: string) {
  const id = randomUUID(); const email = `${kind}.model.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  if (kind === 'finance') {
    await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
    await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'finance')`;
  }
  return { id, email };
}
// an investor with a signed agreement, $50,000 at 30% from March 1, 2026 (lockup to September 1): September paid, October to be paid
async function mkInvestor(sql: Sql, name: string) {
  const u = await mkUser(sql, 'investor', name);
  const t = tag();
  const [inv] = await sql`insert into investors (user_id, legal_name, investor_type, status, email, tax_information_complete) values (${u.id}, ${name}, 'individual', 'active', ${u.email}, true) returning id`;
  const [dc] = await sql`insert into documents (kind, storage_bucket, storage_path) values ('other', 'documents', ${`e2e/model/${t}-c.pdf`}) returning id`;
  const [dd] = await sql`insert into documents (kind, storage_bucket, storage_path) values ('other', 'documents', ${`e2e/model/${t}-d.pdf`}) returning id`;
  const [agr] = await sql`insert into investment_agreements (investor_id, agreement_number, status, schedule_c_document_id, schedule_d_document_id, exemption_category, legal_advice_choice)
    values (${inv!.id}, ${`IA-E2E-${t}`}, 'signed', ${dc!.id}, ${dd!.id}, 'accredited_investor', 'declined') returning id`;
  const [x] = await sql`insert into investments (investor_id, agreement_id, is_initial, principal_cents, yearly_bps, investment_date, lockup_end_date)
    values (${inv!.id}, ${agr!.id}, true, 5000000, 3000, '2026-03-01', '2026-09-01') returning id`;
  await sql`insert into investment_returns (investment_id, return_month, opening_invested_cents, yearly_bps, days_earning, days_in_month, return_cents, disposition, payment_date, status, closing_invested_cents) values
    (${x!.id}, '2026-09-01', 5000000, 3000, 30, 30, 125000, 'pay', '2026-10-15', 'paid', 5000000),
    (${x!.id}, '2026-10-01', 5000000, 3000, 31, 31, 125000, 'pay', '2099-11-15', 'accrued', 5000000)`;
  return { ...u, investmentId: x!.id as string };
}
async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' }).catch(() => page.goto('/sign-in', { waitUntil: 'networkidle' }));
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 60_000 });
  await page.waitForLoadState('networkidle');
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL, reducedMotion: 'reduce' });
  return c.newPage();
}
async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect(await page.locator('main').innerText()).not.toMatch(/[—–]/);
}

test.describe('the model sheets, live', () => {
  let sql: Sql;
  test.beforeAll(() => { sql = db(); });
  test.afterAll(async () => { await sql.end(); });

  test('an investor sees their investment live, uses the calculators and downloads the safe sheets', async ({ browser }) => {
    test.setTimeout(240_000);
    const inv = await mkInvestor(sql, 'Dana Example');
    const page = await ctx(browser);
    await signIn(page, inv.email);
    await page.goto('/investor', { waitUntil: 'networkidle' });
    await page.getByRole('link', { name: 'Live sheets' }).click();
    await page.waitForURL('**/investor/model');
    await expect(page.locator('meta[name="robots"]')).toHaveAttribute('content', /noindex/);
    await expect(page.getByTestId('model-mine')).toBeVisible();
    await expect(page.getByTestId('mine-invested')).toHaveText('$50,000.00');
    await expect(page.getByTestId('mine-paid')).toHaveText('$1,250.00');
    await expect(page.getByTestId('mine-next')).toHaveText('$1,250.00');
    await expect(page.getByTestId('mine-schedule').locator('tbody tr')).toHaveCount(36);
    await expect(page.getByTestId('mine-schedule').locator('tbody tr').first()).toContainText('Paid');
    const body = await page.locator('main').innerText();
    for (const w of [/utili[sz]ation/i, /premium/i, /fleet size/i, /EBITDA/, /DO NOT SHARE/i]) expect(body).not.toMatch(w);
    await check(page, 'my investment');
    await shot(page, 'mine');

    // a payout recorded in the database shows as paid on the next view: nothing to refresh
    await sql`update investment_returns set status = 'paid' where investment_id = ${inv.investmentId} and return_month = '2026-10-01'`;
    await page.reload({ waitUntil: 'networkidle' });
    await expect(page.getByTestId('mine-paid')).toHaveText('$2,500.00');
    await page.getByTestId('mine-reinvest-toggle').click();
    await page.waitForURL('**/investor/model?reinvest=1');
    await expect(page.getByTestId('mine-schedule')).toContainText('Projected, reinvested');

    await page.getByTestId('model-tab-calculator').click();
    await page.waitForURL('**/investor/model?tab=calculator');
    await page.getByTestId('calc-amount').fill('50000');
    await page.getByTestId('calc-rate').fill('30');
    await page.getByTestId('calc-paid').click();
    await expect(page.getByTestId('calc-monthly')).toHaveText('$1,250.00');
    await expect(page.getByTestId('calc-paid36')).toHaveText('$37,500');
    await expect(page.getByTestId('calc-table').locator('tbody tr')).toHaveCount(36);
    await check(page, 'calculator');
    await shot(page, 'calculator');
    await page.getByTestId('calc-amount').fill('15000');
    await expect(page.getByText('Below the $20,000 minimum.')).toBeVisible();

    await page.getByTestId('model-tab-how').click();
    await expect(page.getByTestId('how-examples')).toContainText('$4,167'); // r35: Option 1 at 10% on $500,000, a month
    await expect(page.getByTestId('how-terms')).toContainText('20 to 25% profit share');
    await check(page, 'how it works');
    await shot(page, 'how');

    await page.getByTestId('model-tab-car').click();
    await expect(page.getByTestId('car-cash')).toHaveText('$1,960');
    await page.getByTestId('car-add').click();
    await expect(page.getByTestId('car-cash')).toHaveText('$1,960');
    await check(page, 'fund a car');
    await shot(page, 'car');

    // downloads: the investor-safe sheets only, with their numbers
    const x = await page.request.get('/investor/model/excel');
    expect(x.status()).toBe(200);
    expect(x.headers()['content-type']).toContain('spreadsheetml');
    const bytes = await x.body();
    expect(bytes.subarray(0, 2).toString()).toBe('PK');
    const text = bytes.toString('latin1');
    expect(text).toContain('Investment calculator');
    expect(text).toContain('My investment');
    expect(text).not.toContain('DO NOT SHARE');
    expect(text).not.toContain('Actuals');
    const p = await page.request.get('/investor/model/pdf');
    expect(p.status()).toBe(200);
    expect(await pdfText(await p.body())).toContain('Your CarmaCars investment');

    // the internal model is not theirs
    await page.goto('/admin/money/model', { waitUntil: 'networkidle' });
    await expect(page).not.toHaveURL(/\/admin\/money\/model$/);
    const xi = await page.request.get('/admin/money/model/excel', { maxRedirects: 0 });
    expect(xi.status()).not.toBe(200);
  });

  test('an Admin runs the company model; Finance is refused', async ({ browser }) => {
    test.setTimeout(240_000);
    const admin = await mkUser(sql, 'admin', 'Sam Example');
    const a = await ctx(browser);
    await signIn(a, admin.email);
    await a.goto('/admin/money/model', { waitUntil: 'networkidle' });
    await expect(a.getByTestId('model-tiles')).toBeVisible();
    await expect(a.getByTestId('model-chart')).toBeVisible();
    await expect(a.getByTestId('model-forecast')).toContainText('EBITDA');
    await check(a, 'company model');
    await shot(a, 'admin-forecast');
    await a.getByRole('link', { name: 'Actuals' }).first().click();
    await expect(a.getByTestId('model-actuals')).toContainText('Total rental revenue');
    await expect(a.getByTestId('model-actuals')).toContainText('Insurer-billed');
    await check(a, 'actuals');
    await shot(a, 'admin-actuals');
    await a.getByRole('link', { name: 'Pro forma 5 years' }).click();
    await expect(a.getByTestId('model-proforma')).toContainText('Year 5');
    await check(a, 'pro forma');
    await a.getByRole('link', { name: 'Assumptions' }).click();
    await expect(a.getByTestId('model-assumptions')).toBeVisible();
    await check(a, 'assumptions');
    await shot(a, 'admin-assumptions');
    const before = await sql`select inputs from finance_model_settings`;
    try {
      await a.getByTestId('as-insurancePremium').fill('24000');
      await a.getByTestId('as-save').click();
      await expect(a.getByText('Saved. The forecast')).toBeVisible({ timeout: 15_000 });
      expect((await sql`select inputs ->> 'insurancePremium' as v from finance_model_settings`)[0]!.v).toBe('24000');
    } finally {
      await sql`update finance_model_settings set inputs = ${before[0]!.inputs}`;
    }
    const x = await a.request.get('/admin/money/model/excel');
    expect(x.status()).toBe(200);
    const text = (await x.body()).toString('latin1');
    for (const s of ['Assumptions - DO NOT SHARE', 'Actuals - DO NOT SHARE', 'Forecast - DO NOT SHARE', 'Pro forma 5y - DO NOT SHARE']) expect(text).toContain(s);

    const fin = await mkUser(sql, 'finance', 'Fin Example');
    const f = await ctx(browser);
    await signIn(f, fin.email);
    await f.goto('/admin/money/model', { waitUntil: 'networkidle' });
    await expect(f).not.toHaveURL(/\/admin\/money\/model$/);
    const fx = await f.request.get('/admin/money/model/excel', { maxRedirects: 0 });
    expect(fx.status()).not.toBe(200);
  });
});
