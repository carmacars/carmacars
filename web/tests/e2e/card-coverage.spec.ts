import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Which credit cards include rental car coverage (docs/changes/2026-10-24-credit-card-coverage.md, migration 0131):
// - the public page: the value limits first, "confirm with your card issuer", the list with its search and filters, the
//   checklist and the questions, at 375 and 1440, with axe; linked from Requirements and coverage;
// - an Admin adds a card in Settings > Card coverage and it is on the page at once (removed again at the end);
// - customer service's quick reference. Fictional people only.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function person(sql: ReturnType<typeof db>, role: 'admin' | 'va', name: string) {
  const id = randomUUID(); const email = `${role}.cc31.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, staff_type, va_function, home_address, home_postal_code) values (${id}, 'va', 'cs', '1 Test Lane, Testville', 'X9X 9X9')`;
  return email;
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 30_000 });
}

test('the page: value limits first, confirm with the issuer, the list narrows, the checklist, linked from Requirements', async ({ page }) => {
  test.setTimeout(120_000);
  const errors = watch(page);
  const sql = db();
  try {
    const [{ n }] = await sql`select count(*)::int n from card_rental_coverage where is_active` as unknown as [{ n: number }];
    await page.goto('/requirements', { waitUntil: 'networkidle' });
    await acceptCookies(page);
    await page.locator('#coverage').getByRole('link', { name: 'Which cards include it' }).click();
    await page.waitForURL('**/credit-card-rental-coverage');
    await expect(page.getByRole('heading', { level: 1 })).toHaveText('Credit cards with rental car coverage.');
    await expect(page).toHaveTitle(/Credit cards with rental car coverage in Canada/);
    await expect(page.getByTestId('card-coverage-limits')).toContainText('Most cards stop at $65,000 or $85,000');
    await expect(page.getByTestId('card-coverage-confirm')).toContainText('Confirm with your card issuer before you rent');
    await expect(page.getByTestId('card-coverage-confirm')).toContainText('CarmaCars does not decide claims');
    await expect(page.getByTestId('card-coverage-checklist')).toContainText('Pay the whole rental with that card');
    const rows = page.locator('[data-testid="card-coverage"] tbody tr');
    await expect(rows).toHaveCount(n);
    await expect(page.getByTestId('card-coverage-count')).toHaveText(`${n} cards`);

    await page.getByTestId('card-coverage-q').fill('aventura');
    await expect(rows).toHaveCount(2);
    await expect(page.getByTestId('card-cibc-aventura-visa-infinite')).toContainText('$85,000 MSRP');
    await expect(page.getByTestId('card-cibc-aventura-visa-infinite')).toContainText('Primary');
    await page.getByTestId('card-coverage-q').fill('');
    await page.getByTestId('card-coverage-value').selectOption('100000');
    const [{ hi }] = await sql`select count(*)::int hi from card_rental_coverage where is_active and coverage <> 'none' and max_msrp_cents >= 10000000` as unknown as [{ hi: number }];
    await expect(rows).toHaveCount(hi);
    await page.getByTestId('card-coverage-value').selectOption('any');
    await page.getByTestId('card-coverage-country').selectOption('US');
    await expect(page.getByTestId('card-chase-sapphire-reserve')).toBeVisible();
    await expect(page.getByTestId('card-bmo-eclipse-visa-infinite')).toHaveCount(0);
    await page.getByTestId('card-coverage-country').selectOption('all');
    await page.getByTestId('card-coverage-q').fill('no such card at all');
    await expect(page.getByTestId('card-coverage-none')).toBeVisible();
    await page.getByTestId('card-coverage-q').fill('');
    // the official guide opens in a new tab; an unverified card says so
    await expect(page.getByTestId('card-bmo-eclipse-visa-infinite').getByRole('link', { name: /BMO.s guide/ })).toHaveAttribute('target', '_blank');
    await expect(page.getByTestId('card-national-bank-world-elite-mastercard')).toContainText('Unverified');
    // structured data: the breadcrumb and the page's own questions
    const ld = await page.locator('script[type="application/ld+json"]').allTextContents();
    expect(ld.join(' ')).toContain('"FAQPage"');
    expect(ld.join(' ')).toContain('Who decides a claim on my card');
    await axe(page, 'card coverage');
    expect(errors).toEqual([]);
  } finally { await sql.end(); }
});

test('an Admin adds a card in Settings > Card coverage, and it is on the page at once', async ({ page }, info) => {
  test.skip(info.project.name.startsWith('phone'), 'one run: the list is one for the whole site');
  test.setTimeout(180_000);
  const errors = watch(page);
  const sql = db();
  const card = `E2E Travel ${tag()}`;
  try {
    await sql`delete from app.rate_limit_hits`;
    const email = await person(sql, 'admin', 'Avery Admin');
    await signIn(page, email, '/admin/settings/card-coverage');
    await page.goto('/admin/settings/card-coverage', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('card-coverage-admin')).toContainText('American Express Cobalt Card');
    const add = page.getByTestId('add-card-coverage');
    await add.getByLabel('Issuer', { exact: true }).fill('Example Credit Union');
    await add.getByLabel('Card', { exact: true }).fill(card);
    await add.getByLabel('Pays', { exact: true }).selectOption('primary');
    await add.getByLabel('Car value limit (MSRP)').fill('120000');
    await add.getByLabel('Longest rental (days)').fill('31');
    await add.getByLabel('Official guide (https://)').fill('https://example.test/guide.pdf');
    await add.getByTestId('add-card-coverage-save').click();
    await expect(add.getByRole('status')).toHaveText('Saved.');
    const [row] = await sql`select max_msrp_cents::int m, max_days, coverage, last_checked::text d from card_rental_coverage where card = ${card}`;
    expect(row).toMatchObject({ m: 12000000, max_days: 31, coverage: 'primary' });
    await axe(page, 'admin card coverage');

    await page.goto('/credit-card-rental-coverage', { waitUntil: 'networkidle' });
    await page.getByTestId('card-coverage-q').fill(card);
    const r = page.locator('[data-testid="card-coverage"] tbody tr');
    await expect(r).toHaveCount(1);
    await expect(r.first()).toContainText('$120,000 MSRP');
    await expect(r.first()).toContainText('31 days');
    expect(errors).toEqual([]);
  } finally {
    await sql`delete from card_rental_coverage where card like 'E2E Travel %'`;
    await sql.end();
  }
});

test('customer service: the quick reference with what to say and the list', async ({ page }, info) => {
  test.skip(info.project.name.startsWith('phone'), 'one run is enough for a staff page');
  test.setTimeout(120_000);
  const errors = watch(page);
  const sql = db();
  try {
    await sql`delete from app.rate_limit_hits`;
    const email = await person(sql, 'va', 'Casey Service');
    await signIn(page, email, '/va/card-coverage');
    await page.goto('/va/card-coverage', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('va-nav').getByRole('link', { name: 'Card coverage' })).toBeVisible();
    await expect(page.getByTestId('card-coverage-script')).toContainText('Never say they are covered');
    await expect(page.locator('[data-testid="card-coverage"] tbody tr').first()).toBeVisible();
    await axe(page, 'va card coverage');
    expect(errors).toEqual([]);
  } finally { await sql.end(); }
});
