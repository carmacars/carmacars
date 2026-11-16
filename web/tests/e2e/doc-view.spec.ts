import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, storeFixtureJpeg } from './helpers';

// Migration 3071 end to end, at 375 and 1440: in the renter documents pop-up, an approved licence image opens again with
// View (a one-minute private link; the view is in the audit log), and a document removed by the 90-day purge reads
// "Removed on <date>" with nothing to open.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
}

test('a reviewed licence opens again with View (logged); a purged one reads Removed on', async ({ page }) => {
  test.setTimeout(120_000);
  const sql = db();
  const id = randomUUID(); const email = `dv.admin.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Dana Admin')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  const [b] = await sql`select b.id, b.booking_number, r.user_id, d.driver_id from bookings b join renters r on r.id = b.renter_id
                         join booking_drivers d on d.booking_id = b.id and d.role = 'renter'
                         where b.status = 'confirmed' and b.pickup_at > now() + interval '1 day' and r.user_id is not null and b.booking_type <> 'owner'
                         order by random() limit 1`;
  test.skip(!b, 'no confirmed booking to use');
  const up = async (kind: string) => {
    const key = `renters/dv/${tag()}-${kind}.jpg`;
    storeFixtureJpeg('identity', key);
    const [r] = await sql`select app.register_verification_upload(${b!.id}, ${b!.user_id}, ${kind}, ${b!.driver_id}, ${key}, ${tag()}, 'image/jpeg', null, 'identity') as id`;
    return r!.id as string;
  };
  const front = await up('licence_front');
  const back = await up('licence_back');
  await up('selfie'); // stays waiting: the review card stays on the booking
  await sql`select app.review_verification_upload(${front}, ${id}, true, null)`;
  await sql`select app.review_verification_upload(${back}, ${id}, true, null)`;
  await sql`update documents set purged_at = now() where id = (select document_id from verification_uploads where id = ${back})`;

  await signIn(page, email);
  await page.goto(`/admin/bookings/${b!.booking_number}?tab=overview`, { waitUntil: 'networkidle' });
  await page.getByTestId('booking-doc-review').getByTestId('doc-review-open').click();
  const dlg = page.getByTestId('doc-review-dialog').filter({ visible: true });
  await expect(dlg.getByTestId('doc-licence_back-view-removed')).toContainText(/^Removed on [A-Z][a-z]{2} \d{1,2}, \d{4}$/);
  await dlg.getByTestId('doc-licence_front-view-open').click();
  await expect(dlg.getByTestId('doc-licence_front-view-img')).toBeVisible();
  expect(await dlg.getByTestId('doc-licence_front-view-img').getAttribute('src')).toBeTruthy();
  await noOverflow(page);
  await expect.poll(async () => Number((await sql`select count(*) n from audit_log where action = 'document_view' and actor_user_id = ${id}`)[0]!.n), { timeout: 10_000 }).toBe(1);
  await sql.end();
});
