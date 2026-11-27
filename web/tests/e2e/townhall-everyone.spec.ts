import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db } from './helpers';

// R50 hotfix 2: "Join did not work for anyone and the deck could not be seen during the meeting (it ran on WhatsApp)".
// Two staff (one at the office, one in the field) and an Admin go to the townhall the way people do: from their portal's
// home, press Join, join the call in the site, see the deck; the Admin advances a slide and it moves for everyone. The
// staff page of the townhall also shows the deck without the call. Nothing the people read says "VA" for in-person staff.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
type Who = 'admin' | 'office' | 'field';
async function mk(sql: Sql, who: Who) {
  const id = randomUUID(); const email = `th.${who}.${Date.now()}.${randomBytes(2).toString('hex')}@example.test`;
  const name = who === 'admin' ? 'Ada Presenter' : who === 'office' ? 'Cora Service' : 'Fay Fieldworker';
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${who === 'admin' ? 'admin' : who === 'office' ? 'va' : 'field'})`;
  if (who === 'office') await sql`insert into staff_profiles (user_id, staff_type, va_function, home_address, home_postal_code, onboarding_exempt, agreement_waived_at) values (${id}, 'va', 'cs', '1 Test Lane, Testville', 'X9X 9X9', true, now())`;
  if (who === 'field') await sql`insert into staff_profiles (user_id, staff_type, field_function, home_address, home_postal_code, onboarding_exempt, agreement_waived_at) values (${id}, 'field', 'driver', '1 Test Lane, Testville', 'X9X 9X9', true, now())`;
  return { id, email, name };
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  const useEmail = page.getByRole('button', { name: /email/i }).first();
  if (await useEmail.isVisible().catch(() => false)) await useEmail.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(next.split('?')[0]!));
}
async function open(browser: Browser) {
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 900 } });
  return { ctx, page: await ctx.newPage() };
}

test.describe.configure({ mode: 'serial' });
let sql: Sql;
let saved: { townhall_weekday: number; townhall_time: string; townhall_minutes: number; calls_mode: string; townhall_call_url: string | null } | undefined;
test.beforeAll(async () => {
  sql = db();
  [saved] = await sql`select townhall_weekday, townhall_time, townhall_minutes, calls_mode, townhall_call_url from program_settings limit 1` as unknown as Array<NonNullable<typeof saved>>;
  // the townhall started 2 minutes ago (Toronto), the call is in the site, and no outside link is set (the case on the day)
  await sql`update program_settings set townhall_weekday = extract(isodow from now() at time zone 'America/Toronto')::int,
              townhall_time = to_char((now() - interval '2 minutes') at time zone 'America/Toronto', 'HH24:MI'), townhall_minutes = 60, calls_mode = 'in_site', townhall_call_url = ''`;
  await sql`select app.townhall_build(null, null)`;
});
test.afterAll(async () => {
  if (saved) await sql`update program_settings set townhall_weekday = ${saved.townhall_weekday}, townhall_time = ${saved.townhall_time}, townhall_minutes = ${saved.townhall_minutes}, calls_mode = ${saved.calls_mode}, townhall_call_url = ${saved.townhall_call_url}`;
  await sql.end();
});

test('two staff and an Admin join from their portals, see the deck, and the presenter moves it for everyone', async ({ browser }) => {
  const admin = await mk(sql, 'admin'); const office = await mk(sql, 'office'); const field = await mk(sql, 'field');
  const A = await open(browser); const B = await open(browser); const C = await open(browser);
  const seen: string[] = [];
  const read = async (p: Page) => { seen.push(await p.locator('body').innerText()); };

  // the staff start on their portal's home and press Join on the townhall card; the Admin on the townhall page of the Admin portal
  await signIn(A.page, admin.email, '/admin/townhall');
  await signIn(B.page, office.email, '/staff');
  await signIn(C.page, field.email, '/staff/field');
  await A.page.getByTestId('townhall-join').click();
  for (const p of [B.page, C.page]) {
    const join = p.getByTestId('townhall-card-join');
    await expect(join, 'Join is on the portal home from 15 minutes before').toBeVisible({ timeout: 15_000 });
    await join.click();
  }
  await A.page.waitForURL('**/admin/townhall/live'); await B.page.waitForURL('**/staff/townhall/live'); await C.page.waitForURL('**/staff/townhall/live');
  for (const p of [A.page, B.page, C.page]) { await expect(p.getByTestId('call-lobby')).toBeVisible(); await expect(p.getByTestId('call-lobby-deck'), 'the deck can be read before (or without) the call').toBeVisible(); await read(p); await p.getByTestId('call-join').click(); await expect(p.getByTestId('call-room')).toBeVisible({ timeout: 15_000 }); }

  // everyone sees the deck, on the same first slide
  const title = (p: Page) => p.getByTestId('call-slide-title');
  for (const p of [A.page, B.page, C.page]) await expect(p.getByTestId('call-deck')).toHaveAttribute('data-slide', '0');
  const first = await title(A.page).innerText();
  expect(first.length).toBeGreaterThan(2);
  for (const p of [B.page, C.page]) await expect(title(p)).toHaveText(first);
  // the Admin is in everyone's list and everyone is in the Admin's
  await expect(A.page.getByTestId(`call-tile-u-${office.id}`)).toBeVisible({ timeout: 15_000 });
  await expect(A.page.getByTestId(`call-tile-u-${field.id}`)).toBeVisible({ timeout: 15_000 });
  await expect(B.page.getByTestId(`call-tile-u-${admin.id}`)).toBeVisible({ timeout: 15_000 });
  await expect(C.page.getByTestId(`call-tile-u-${admin.id}`)).toBeVisible({ timeout: 15_000 });

  // the presenter advances: both staff follow
  await A.page.getByTestId('call-slide-next').click();
  for (const p of [A.page, B.page, C.page]) await expect(p.getByTestId('call-deck')).toHaveAttribute('data-slide', '1', { timeout: 10_000 });
  const second = await title(A.page).innerText();
  for (const p of [B.page, C.page]) await expect(title(p)).toHaveText(second);

  // a staff member browsing alone does not move anyone, and "Back to the presenter" returns
  await B.page.getByTestId('call-slide-prev').click();
  await expect(B.page.getByTestId('call-deck')).toHaveAttribute('data-slide', '0');
  await expect(A.page.getByTestId('call-deck')).toHaveAttribute('data-slide', '1');
  await expect(C.page.getByTestId('call-deck')).toHaveAttribute('data-slide', '1');
  await A.page.getByTestId('call-slide-next').click();
  await expect(C.page.getByTestId('call-deck')).toHaveAttribute('data-slide', '2', { timeout: 10_000 });
  await expect(B.page.getByTestId('call-deck')).toHaveAttribute('data-slide', '0');
  await B.page.getByTestId('call-slide-follow').click();
  await expect(B.page.getByTestId('call-deck')).toHaveAttribute('data-slide', '2', { timeout: 10_000 });

  // a late joiner (the field staff leaves and comes back) lands on the presenter's slide, not the first
  await C.page.getByTestId('call-leave').click();
  await C.page.getByTestId('call-rejoin').click();
  await C.page.getByTestId('call-join').click();
  await expect(C.page.getByTestId('call-deck')).toHaveAttribute('data-slide', '2', { timeout: 15_000 });

  // both staff are counted as there, by themselves
  for (const u of [office, field]) await expect.poll(async () => (await sql`select method from townhall_attendance where user_id = ${u.id} and meeting_at = app.townhall_next(now())`)[0]?.method, { timeout: 10_000 }).toBe('call');
  await A.page.getByTestId('call-tab-people').click();
  await expect(A.page.getByTestId('call-live')).toContainText('In the call now (3)', { timeout: 15_000 });

  for (const t of seen) expect(t).not.toMatch(/\bVAs?\b/);
  await A.ctx.close(); await B.ctx.close(); await C.ctx.close();
});

test('the deck is on the townhall page of every portal, with or without the call', async ({ browser }) => {
  const admin = await mk(sql, 'admin'); const office = await mk(sql, 'office'); const field = await mk(sql, 'field');
  for (const [who, path] of [[admin, '/admin/townhall'], [office, '/staff/townhall'], [field, '/staff/townhall']] as const) {
    const X = await open(browser);
    await signIn(X.page, who.email, path);
    await expect(X.page.getByTestId('townhall-deck')).toBeVisible({ timeout: 15_000 });
    expect(await X.page.getByTestId('townhall-deck').locator('li[data-testid^="townhall-slide-"]').count()).toBeGreaterThan(3);
    await expect(X.page.getByTestId('townhall-join')).toBeVisible();
    expect(await X.page.locator('body').innerText()).not.toMatch(/\bVAs?\b/);
    await X.ctx.close();
  }
});
