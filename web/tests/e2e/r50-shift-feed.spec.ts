import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Release 50 (5050): an Admin opens the field jobs board, the "Add shifts to Google Calendar" card is there, makes the
// private link, and the link answers a text/calendar feed with the shift in it; a made-up token answers 404.
type Sql = ReturnType<typeof db>;
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function mkAdmin(sql: Sql) {
  const id = randomUUID(); const email = `r50.sfd.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Sia Shifts ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 60_000 });
}

test('shift feed: the card renders on the field jobs board and its link answers text/calendar', async ({ page }) => {
  test.setTimeout(120_000);
  const sql = db();
  const admin = await mkAdmin(sql);
  const [slot] = await sql`insert into field_shift_slots (starts_at, ends_at, capacity, note)
    values (now() + interval '2 days', now() + interval '2 days 3 hours', 1, ${`sfd e2e ${tag()}`}) returning id`;
  await signIn(page, admin.email);
  await page.goto('/admin/field-jobs', { waitUntil: 'networkidle' });
  const card = page.getByTestId('shift-feed-all');
  await expect(card).toBeVisible();
  await expect(card.getByRole('heading', { name: 'Add shifts to Google Calendar' })).toBeVisible();
  await expect(card).toContainText('every few hours');
  await card.getByTestId('shift-feed-create-all').click();
  const input = card.getByTestId('shift-feed-url-all');
  await expect(input).toHaveValue(/\/api\/shift-feed\/[0-9a-f]{64}\.ics$/);
  await expect(card.getByTestId('shift-feed-google-all')).toHaveAttribute('href', /^https:\/\/calendar\.google\.com\/calendar\/r\?cid=webcal%3A%2F%2F/);
  await noOverflow(page);

  const url = new URL(await input.inputValue());
  const r = await page.request.get(url.pathname);
  expect(r.status()).toBe(200);
  expect(r.headers()['content-type']).toMatch(/^text\/calendar/);
  const body = await r.text();
  expect(body).toContain('BEGIN:VCALENDAR');
  expect(body).toContain(`UID:shift-${slot!.id}@carmacars.ca`);
  expect((await page.request.get(`/api/shift-feed/${'0'.repeat(64)}.ics`)).status()).toBe(404);

  await sql`update field_shift_slots set cancelled_at = now(), cancelled_by = ${admin.id} where id = ${slot!.id}`;
  await sql.end();
});
