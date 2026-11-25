import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, openAccountMenu } from './helpers';

// Guide me (migration 3950): the booking guide end to end in the live Send an offer screen. Started from the header's
// menu; a step to do does not pass on Next, it moves on by itself once the form says it is done; the card says Step X of
// Y, is never over Report a bug and fits the phone width; sending the offer completes the run, which the server records
// and Admin > Academy counts.
const PW = 'correct horse battery';
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
}

const boxesOverlap = (a: { x: number; y: number; width: number; height: number }, b: { x: number; y: number; width: number; height: number }) =>
  a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;

test('Guide me walks an Admin through sending an offer, step by step in the live screen', async ({ page }) => {
  test.setTimeout(180_000);
  const sql = db();
  const id = randomUUID(); const email = `admin.guide.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Gia Guide ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  const vin = `5XYKG${randomBytes(6).toString('hex').toUpperCase()}`.slice(0, 17).padEnd(17, '3').replace(/[IOQ]/g, 'A');
  const [r] = await sql`select app.vehicle_add(${id}, ${sql.json({ supply_type: 'company', vin, plate: `GM${randomBytes(2).toString('hex').toUpperCase()}`, year: 2024, make: 'Kia', model: 'K5',
    rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as v`;
  const car = (r!.v as { vehicle_id: string }).vehicle_id;

  await signIn(page, email);
  await page.goto(`/admin/offers/new?car=${car}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('offer-composer')).toBeVisible();
  // off by default: no card until asked for
  await expect(page.getByTestId('guide-me-card')).toHaveCount(0);
  await openAccountMenu(page); await page.getByTestId('guide-me-open').click();
  await expect(page.getByTestId('guide-me-keep')).not.toBeChecked();
  await page.getByTestId('guide-me-start-create-offer').click();

  const card = page.getByTestId('guide-me-card');
  await expect(card).toBeVisible();
  // already on the page: "open Send an offer" passed by itself; the renter is the first thing to do
  await expect(card).toHaveAttribute('data-step', 'renter');
  await expect(page.getByTestId('guide-me-progress')).toHaveText(/^Step 2 of \d+$/);
  // a step to do: Next is off, and does not pass it
  await expect(page.getByTestId('guide-me-next')).toBeDisabled();
  // the card is never over Report a bug, and the page does not scroll sideways
  const bug = await page.getByTestId('bug-report-open').boundingBox();
  const cb = await card.boundingBox();
  if (bug && cb) expect(boxesOverlap(bug, cb)).toBe(false);
  await noOverflow(page);

  // doing it on the page moves it on
  await page.getByTestId('oc-add-customer').click();
  await page.getByTestId('oc-full_name').fill('Gus Guided');
  await page.getByTestId('oc-mobile').fill(`416555${String(Date.now()).slice(-4)}`);
  await page.getByTestId('oc-email').fill(`gus.${tag()}@example.test`);
  await page.getByTestId('oc-date_of_birth').fill('1987-03-04');
  await expect(card).not.toHaveAttribute('data-step', 'renter', { timeout: 15_000 });

  // Back opens the renter again (done: Next is on), and Next returns
  const after = await card.getAttribute('data-step');
  await page.getByTestId('guide-me-back').click();
  await expect(card).toHaveAttribute('data-step', 'renter');
  await expect(page.getByTestId('guide-me-next')).toBeEnabled();
  await page.getByTestId('guide-me-next').click();
  await expect(card).toHaveAttribute('data-step', after!);

  // the rest of the walk: each step done on the page or read and passed with Next, until the offer is sent
  for (let i = 0; i < 12; i++) {
    if (await page.getByTestId('offer-sent').isVisible()) break;
    const step = await card.getAttribute('data-step');
    if (step === 'send') {
      await expect(page.getByTestId('oc-ready')).toHaveText('Ready to send', { timeout: 15_000 });
      await page.getByTestId('oc-send').click();
      await expect(page.getByTestId('offer-sent')).toBeVisible({ timeout: 20_000 });
      break;
    }
    // dates, car (given in the address), places and coverage are filled already or are steps to read: Next is on
    await expect(page.getByTestId('guide-me-next')).toBeEnabled({ timeout: 15_000 });
    await page.getByTestId('guide-me-next').click();
    await expect(card).not.toHaveAttribute('data-step', step!);
  }
  await expect(page.getByTestId('guide-me-done')).toContainText('Send an offer to a renter: all done.');
  await expect(page.getByTestId('guide-me-card')).toHaveCount(0);

  // the server has the run completed, and Admin > Academy counts it
  await expect.poll(async () => (await sql`select status from guide_me_runs where user_id = ${id} order by started_at desc limit 1`)[0]?.status, { timeout: 10_000 }).toBe('completed');
  await page.goto('/admin/academy', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('guide-me-report')).toContainText('Send an offer to a renter');
  await sql.end();
});
