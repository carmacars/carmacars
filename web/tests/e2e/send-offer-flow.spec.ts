import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Release 24, Send an offer as one flow (migration 0250): the rate card is folded away until asked for, the price summary
// is in view (sticky on a desktop, a bottom sheet on a phone), and the choices drive the charges: a delivery fee set by
// hand is shown as "Set by hand" and goes when the delivery goes, with nothing to remove in a second place. Both widths,
// no horizontal overflow.
const PW = 'correct horse battery';
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;

async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
}

test('send an offer: one flow, the rate card folded, a delivery fee goes with the delivery', async ({ page }) => {
  test.setTimeout(180_000);
  const sql = db();
  const id = randomUUID(); const email = `admin.flow.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Ada Flow ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  const vin = `5XYKF${randomBytes(6).toString('hex').toUpperCase()}`.slice(0, 17).padEnd(17, '3').replace(/[IOQ]/g, 'A');
  const [r] = await sql`select app.vehicle_add(${id}, ${sql.json({ supply_type: 'company', vin, plate: `FL${randomBytes(2).toString('hex').toUpperCase()}`, year: 2024, make: 'Kia', model: 'K5',
    rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as v`;
  const car = (r!.v as { vehicle_id: string }).vehicle_id;
  await sql.end();

  await signIn(page, email);
  await page.goto(`/admin/offers/new?car=${car}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('offer-composer')).toBeVisible();
  await page.getByTestId('oc-add-customer').click();
  await page.getByTestId('oc-full_name').fill('Flo Flow');
  await page.getByTestId('oc-mobile').fill(`416555${String(Date.now()).slice(-4)}`);
  await page.getByTestId('oc-email').fill(`flo.${tag()}@example.test`);
  await page.getByTestId('oc-date_of_birth').fill('1988-04-05');
  await expect(page.getByTestId('oc-total')).toBeVisible({ timeout: 15_000 });
  const plain = (await page.getByTestId('oc-total').innerText()).trim();

  // the rate card is folded until asked for
  const card = page.getByTestId('oc-rate-card');
  await expect(card).not.toHaveAttribute('open', /.*/);
  await expect(card.getByText('Daily rate')).toBeHidden();
  await card.locator('summary').click();
  await expect(card.getByText('Daily rate')).toBeVisible();

  // a delivery: its fee is a line, automatic; set by hand, it says so
  await page.getByTestId('oc-pickup_kind').selectOption('delivery');
  await page.getByTestId('oc-pickup_address').fill('1 Test Street, Toronto');
  await page.keyboard.press('Escape');
  await page.getByTestId('oc-pickup_km').fill('15');
  await expect(page.getByTestId('oc-charge-delivery')).toContainText('Automatic', { timeout: 15_000 });
  await page.getByTestId('oc-change-delivery').click();
  await page.getByTestId('oc-fee-delivery').fill('90');
  await expect(page.getByTestId('oc-charge-delivery')).toContainText('Set by hand', { timeout: 15_000 });
  await expect(page.getByTestId('oc-feenote-delivery')).toContainText('$90.00');
  await expect(page.getByTestId('oc-total')).not.toHaveText(plain);
  await noOverflow(page);

  // the delivery taken off in one place: its fee is gone everywhere, and the total is the one without it
  await page.getByTestId('oc-pickup_kind').selectOption('our_location');
  await expect(page.getByTestId('oc-total')).toHaveText(plain, { timeout: 15_000 });
  await expect(page.getByTestId('oc-total')).toHaveAttribute('data-fresh', 'yes');
  await expect(page.getByTestId('oc-charge-delivery')).toHaveCount(0);
  await expect(page.getByTestId('oc-line-delivery')).toHaveCount(0);
  await expect(page.getByTestId('oc-feenote-delivery')).toHaveCount(0);
  // chosen again: the automatic amount, not the one typed before
  await page.getByTestId('oc-pickup_kind').selectOption('delivery');
  await page.getByTestId('oc-pickup_address').fill('1 Test Street, Toronto');
  await page.keyboard.press('Escape');
  await page.getByTestId('oc-pickup_km').fill('15');
  await expect(page.getByTestId('oc-charge-delivery')).toContainText('Automatic', { timeout: 15_000 });

  // the summary: in the side column on a desktop, a bottom sheet with the total on a phone
  if (isPhone()) {
    await expect(page.getByTestId('oc-sheet-toggle')).toBeVisible();
    await page.getByTestId('oc-sheet-toggle').click();
    await expect(page.getByTestId('oc-line-delivery')).toBeVisible();
  } else {
    await expect(page.getByTestId('oc-sheet-toggle')).toBeHidden();
    await expect(page.getByTestId('oc-line-delivery')).toBeVisible();
  }
  await noOverflow(page);
});
