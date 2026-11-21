import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow } from './helpers';

// r48 FE (3190 to 3199): the main paths of this part, end to end, with the notification queued, and screenshots of the new
// and changed screens at 320, 375, 768, 1280 and 1440 (long names included), each checked for overflow:
//   1. a renter with a mobile number that is not valid gets the data check pop-up on their portal, fixes it there and the
//      pop-up closes; an Admin's Send reminder queues the branded renter_data_check email;
//   2. the Sales one click (/careers/sales-yes/<token>) makes the Sales application and opens the interview, its email queued;
//   3. the owner's Book my own car offers Who's driving? with Someone else.
const PW = 'correct horse battery';
const WIDTHS = [320, 375, 768, 1280, 1440];
const SHOTS = process.env.SHOTS_DIR ?? 'test-results/r48fe';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const LONG = 'Maximiliana Constantinopolous-Vanderhoeven';

async function signIn(page: Page, email: string, to: RegExp) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => to.test(u.pathname), { timeout: 60_000 });
}
async function shots(page: Page, name: string) {
  mkdirSync(SHOTS, { recursive: true });
  for (const w of WIDTHS) {
    await page.setViewportSize({ width: w, height: 900 });
    await noOverflow(page);
    await page.screenshot({ path: `${SHOTS}/${name}-${w}.png`, fullPage: true });
  }
}

test('a renter fixes their phone in the data check pop-up; the reminder email is queued', async ({ page }) => {
  const sql = db();
  const id = randomUUID(); const email = `fe.renter.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`select public.register_account(${id}, ${email}, ${LONG}, null)`;
  // the renter record a booking request makes (an account alone has none), with a number that is not valid
  await sql`insert into renters (user_id, legal_name, email, mobile) values (${id}, ${LONG}, ${email}, '555')`;
  await signIn(page, email, /^\/account/);
  const box = page.getByTestId('data-check');
  await expect(box).toBeVisible();
  await expect(page.getByTestId('data-check-renter_phone')).toContainText('does not look right');
  await shots(page, 'data-check-renter');
  // an Admin's reminder queues the branded email
  const admin = (await sql`select u.id from users u join user_roles r on r.user_id = u.id where r.role = 'admin' limit 1`)[0]!;
  await sql`select app.data_check_remind(${admin.id}, ${sql.json({ user: id })})`;
  expect(Number((await sql`select count(*) n from app_events where code = 'renter_data_check' and payload ->> 'recipient_user_id' = ${id}`)[0]!.n)).toBeGreaterThan(0);
  // the fix closes it
  await page.getByTestId('data-check-renter_phone-phone').fill('+1 416 555 0199');
  await page.getByTestId('data-check-save-renter_phone').click();
  await expect(page.getByTestId('data-check-renter_phone')).toHaveCount(0);
  await sql.end();
});

test('Yes, put me in Sales: one click makes the Sales application and opens the interview', async ({ page }) => {
  const sql = db();
  const token = `fe${randomBytes(12).toString('hex')}`;
  const [cs, sales] = [(await sql`select id from hiring_roles where slug = 'va-customer-service'`)[0]!, (await sql`select id from hiring_roles where slug = 'sales-remote'`)[0]!];
  await sql`insert into job_applications (role_id, status, full_name, email, phone, token, referred_role_id) values (${cs.id}, 'referred', ${LONG}, ${`fe.app.${tag()}@example.test`}, '+639170000000', ${token}, ${sales.id})`;
  await page.goto(`/careers/sales-yes/${token}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await expect(page.getByTestId('sales-yes-button')).toBeVisible();
  await shots(page, 'sales-yes');
  await page.getByTestId('sales-yes-button').click();
  await page.waitForURL((u) => u.pathname.startsWith('/careers/interview/'), { timeout: 60_000 });
  const app = (await sql`select a.id from job_applications a join job_applications f on f.id = a.referred_from where f.token = ${token}`)[0]!;
  expect(Number((await sql`select count(*) n from app_events where code = 'applicant_ai_interview' and entity_id = ${app.id}`)[0]!.n)).toBeGreaterThan(0);
  await sql.end();
});

test('an owner books their car for someone else', async ({ page }) => {
  const sql = db();
  const owner = (await sql`select o.user_id, u.email from owners o join users u on u.id = o.user_id join vehicles v on v.owner_id = o.id
                            join local_auth.users l on l.id = u.id where o.status = 'active' and v.status::text not in ('exited', 'total_loss', 'declined') limit 1`)[0];
  test.skip(!owner, 'the seed has no owner with a car and a password');
  await sql`update local_auth.users set password_hash = ${hash(PW)} where id = ${owner!.user_id}`;
  await signIn(page, owner!.email as string, /^\/owner/);
  await page.goto('/owner/vehicles?tab=bookings#book-own', { waitUntil: 'networkidle' });
  await page.getByTestId('own-who-other').check();
  await expect(page.getByTestId('own-driver')).toBeVisible();
  await shots(page, 'owner-book-someone-else');
  await sql.end();
});
