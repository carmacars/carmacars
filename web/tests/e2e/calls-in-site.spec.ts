import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// r50 (5010): the calls in the site, end to end on the fake media (CALLS_PROVIDER=fake: no camera or microphone; the
// site's relay carries who is in and the data messages). The Admin presents the townhall and moves the slide; a staff
// member on a phone follows it, browses alone and comes back, raises a hand and writes in the chat; the attendance is
// recorded by itself; the Admin sees who is in. A candidate joins their interview from the single-use link, a second
// browser is refused, and the interviewer sees them beside the rubric.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function mkStaff(sql: Sql, role: 'admin' | 'va') {
  const id = randomUUID(); const email = `calls.${role}.${Date.now()}.${randomBytes(2).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${role === 'admin' ? 'Ada Presenter' : 'Cora Service'})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, staff_type, va_function, home_address, home_postal_code, onboarding_exempt) values (${id}, 'va', 'cs', '1 Test Lane, Testville', 'X9X 9X9', true)`;
  return { id, email };
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
async function open(browser: Browser, phone = false) {
  const ctx = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1366, height: 900 } });
  return { ctx, page: await ctx.newPage() };
}

test.describe.configure({ mode: 'serial' });
let sql: Sql;
let saved: { townhall_weekday: number; townhall_time: string; townhall_minutes: number; calls_mode: string } | undefined;
test.beforeAll(async () => {
  sql = db();
  [saved] = await sql`select townhall_weekday, townhall_time, townhall_minutes, calls_mode from program_settings limit 1` as unknown as Array<NonNullable<typeof saved>>;
  // the townhall is on now (started 2 minutes ago, Toronto), in the site, with a deck
  await sql`update program_settings set townhall_weekday = extract(isodow from now() at time zone 'America/Toronto')::int,
              townhall_time = to_char((now() - interval '2 minutes') at time zone 'America/Toronto', 'HH24:MI'), townhall_minutes = 60, calls_mode = 'in_site'`;
  await sql`select app.townhall_build(null, null)`;
});
test.afterAll(async () => {
  if (saved) await sql`update program_settings set townhall_weekday = ${saved.townhall_weekday}, townhall_time = ${saved.townhall_time}, townhall_minutes = ${saved.townhall_minutes}, calls_mode = ${saved.calls_mode}`;
  await sql.end();
});

test('the townhall in the site: slides in sync, hands, chat, attendance by itself, the live list, phone widths', async ({ browser }) => {
  const admin = await mkStaff(sql, 'admin');
  const va = await mkStaff(sql, 'va');
  const A = await open(browser);
  const B = await open(browser, true);
  await signIn(A.page, admin.email, '/admin/townhall/live');
  await A.page.getByTestId('call-join').click();
  await expect(A.page.getByTestId('call-room')).toHaveAttribute('data-provider', 'fake');
  await expect(A.page.getByTestId('call-deck')).toHaveAttribute('data-slide', '0');

  await signIn(B.page, va.email, '/staff/townhall/live');
  await noOverflow(B.page);
  await B.page.getByTestId('call-join').click();
  await expect(B.page.getByTestId(`call-tile-u-${admin.id}`)).toBeVisible({ timeout: 10_000 });
  await expect(A.page.getByTestId(`call-tile-u-${va.id}`)).toBeVisible({ timeout: 10_000 });

  // the presenter moves the slide: everyone follows
  await A.page.getByTestId('call-slide-next').click();
  await expect(B.page.getByTestId('call-deck')).toHaveAttribute('data-slide', '1', { timeout: 10_000 });
  // browsing alone, then back to the presenter
  await B.page.getByTestId('call-slide-prev').click();
  await expect(B.page.getByTestId('call-deck')).toHaveAttribute('data-slide', '0');
  await B.page.getByTestId('call-slide-follow').click();
  await expect(B.page.getByTestId('call-deck')).toHaveAttribute('data-slide', '1');

  // a raised hand and a message reach the presenter
  await B.page.getByTestId('call-hand').click();
  await B.page.getByTestId('call-tab-chat').click();
  await B.page.getByTestId('call-chat-input').fill('Hello from the field');
  await B.page.getByTestId('call-chat-send').click();
  await expect(A.page.getByTestId('call-tab-chat')).toContainText('(1)', { timeout: 10_000 });
  await A.page.getByTestId('call-tab-chat').click();
  await expect(A.page.getByTestId('call-chat')).toContainText('Hello from the field');
  await A.page.getByTestId('call-tab-people').click();
  await expect(A.page.getByTestId('call-people')).toContainText('hand raised', { timeout: 10_000 });

  // attendance, recorded by itself; the Admin sees who is in
  await expect.poll(async () => (await sql`select method, joined_at is not null as j from townhall_attendance where user_id = ${va.id} and meeting_at = app.townhall_next(now())`)[0], { timeout: 10_000 })
    .toEqual({ method: 'call', j: true });
  await expect(A.page.getByTestId('call-live')).toContainText('In the call now (2)', { timeout: 15_000 });

  // phone layouts: 375 and 320, nothing sideways
  await noOverflow(B.page);
  await B.page.setViewportSize({ width: 320, height: 640 });
  await noOverflow(B.page);
  for (const id of ['call-mic', 'call-cam', 'call-hand', 'call-leave']) expect((await B.page.getByTestId(id).boundingBox())!.height).toBeGreaterThanOrEqual(44);

  await B.page.getByTestId('call-leave').click();
  await expect(B.page.getByTestId('call-left')).toBeVisible();
  await expect.poll(async () => (await sql`select left_at is not null as l from townhall_attendance where user_id = ${va.id} and meeting_at = app.townhall_next(now())`)[0]?.l, { timeout: 10_000 }).toBe(true);
  await A.ctx.close(); await B.ctx.close();
});

test('the fallback: the Admin switches to the outside link and back', async ({ browser }) => {
  const admin = await mkStaff(sql, 'admin');
  await sql`update program_settings set townhall_call_url = coalesce(nullif(townhall_call_url, ''), 'https://meet.example.test/carmacars')`;
  const A = await open(browser);
  await signIn(A.page, admin.email, '/admin/townhall/live');
  await A.page.getByTestId('calls-mode').click();
  await A.page.getByTestId('calls-mode-submit').click();
  await expect(A.page.getByTestId('townhall-live-fallback')).toBeVisible({ timeout: 10_000 });
  await A.page.getByTestId('calls-mode').click();
  await expect(A.page.getByTestId('call-lobby')).toBeVisible({ timeout: 10_000 });
  await A.ctx.close();
});

test('an interview call: the candidate joins from the single-use link, a second browser is refused, the interviewer sees them', async ({ browser }) => {
  const admin = await mkStaff(sql, 'admin');
  const email = `calls.cand.${Date.now()}@example.test`;
  const [day] = await sql`insert into interview_days (day, start_time, end_time, mode, note) values (app.local_date(now()), '00:00', '23:59', 'video', ${'e2e calls ' + email}) returning id`;
  const [slot] = await sql`insert into interview_slots (day_id, starts_at, ends_at) values (${day!.id}, now() + interval '40 minutes', now() + interval '55 minutes') returning id`;
  const [app] = await sql`insert into job_applications (role_id, status, full_name, email, phone) select id, 'invited', 'Casey Candidate', ${email}, '+14165550133' from hiring_roles where slug = 'va-fleet-operations' returning id, token`;
  await sql`select app.hiring_book(${app!.token}, ${slot!.id})`;
  // the call is now in 5 minutes: it opens 15 minutes before
  await sql`update interview_slots set starts_at = now() + interval '5 minutes', ends_at = now() + interval '20 minutes' where id = ${slot!.id}`;
  const link = String((await sql`select meet_url from job_applications where id = ${app!.id}`)[0]!.meet_url);
  expect(link).toMatch(/\/call\/i\/[0-9a-f]{64}$/);
  const path = new URL(link).pathname;

  const G = await open(browser, true);
  await G.page.goto(path, { waitUntil: 'networkidle' });
  await acceptCookies(G.page);
  await noOverflow(G.page);
  await G.page.getByTestId('guest-join').click();
  await G.page.getByTestId('call-join').click();
  await expect(G.page.getByTestId('call-room')).toBeVisible();

  const other = await open(browser);
  await other.page.goto(path, { waitUntil: 'networkidle' });
  await acceptCookies(other.page);
  await other.page.getByTestId('guest-join').click();
  await expect(other.page.getByTestId('guest-error')).toContainText('already opened in another browser');
  await other.ctx.close();

  const A = await open(browser);
  await signIn(A.page, admin.email, `/admin/hiring/${app!.id}/call`);
  await A.page.getByTestId('call-join').click();
  await expect(A.page.getByTestId(`call-tile-g-${app!.id}`)).toBeVisible({ timeout: 10_000 });
  await A.page.getByTestId('call-tab-side').click();
  await expect(A.page.getByTestId('iv-candidate')).toContainText(email);
  await expect(A.page.getByTestId('iv-noshow')).toBeVisible();
  await expect(G.page.getByTestId(`call-tile-u-${admin.id}`)).toBeVisible({ timeout: 10_000 });
  await A.ctx.close(); await G.ctx.close();
});
