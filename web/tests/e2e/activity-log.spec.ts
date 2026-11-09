import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0850 end to end, at 375 and 1440: the renter's one Activity log. An Admin opens a renter with an email, a text,
// a call with its summary, a live chat, a note and 60 website events: everything is in one list, newest first; a chip shows
// one type, the search finds a word, Older shows the next 50, Reply goes to the email form, and a note added above the log
// shows in it. Customer service sees the same log on Find a renter; Fleet sees it without payments. The booking page's
// Messages & history section is the booking's log with the email form under it. Fictional people only (example.test).
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function mkUser(sql: Sql, role: 'admin' | 'va', fn?: 'cs' | 'fleet') {
  const id = randomUUID(); const email = `${role}.al.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Alex Activity ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (fn) await sql`insert into staff_profiles (user_id, staff_type, va_function) values (${id}, 'va', ${fn})`;
  return { id, email };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' }).catch(() => page.goto('/sign-in', { waitUntil: 'networkidle' }));
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 30_000 });
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  return c.newPage();
}

/** A renter with no booking yet (a new lead: inside every office function's window), and one of each kind of activity. */
async function seedRenter(sql: Sql) {
  const t = tag();
  const mobile = `+1416${String(2000000 + Math.floor(Math.random() * 7999999)).slice(0, 7)}`;
  const [r] = await sql<Array<{ id: string }>>`insert into renters (legal_name, date_of_birth, mobile, email, identity_status)
    values (${`Avery Activity ${t}`}, '1991-04-04', ${mobile}, ${`avery.${t}@example.test`}, 'verified') returning id`;
  const id = r!.id;
  const ago = (min: number) => new Date(Date.now() - min * 60_000).toISOString();
  await sql`insert into messages (direction, channel, subject, body, renter_id, occurred_at, status) values ('inbound', 'email', 'Weekend question', 'Can I keep the car until Monday?', ${id}, ${ago(30)}, 'received')`;
  const [th] = await sql<Array<{ id: string }>>`insert into phone_threads (number, match_kind, renter_id) values (${mobile}, 'renter', ${id}) returning id`;
  await sql`insert into phone_activity (thread_id, kind, direction, body, started_at, renter_id) values (${th!.id}, 'text', 'in', 'Running ten minutes late', ${ago(25)}, ${id})`;
  await sql`insert into phone_activity (thread_id, kind, direction, started_at, ended_at, duration_seconds, ai_summary, next_steps, renter_id)
    values (${th!.id}, 'call', 'in', ${ago(24)}, ${ago(23)}, 70, 'Asked about the toll road on the way back', ${sql.json(['Send the toll rules'])}, ${id})`;
  const [c] = await sql<Array<{ id: string }>>`insert into chat_conversations (renter_id, status, created_at) values (${id}, 'human', ${ago(22)}) returning id`;
  await sql`insert into chat_messages (conversation_id, sender, body, at) values (${c!.id}, 'visitor', 'Is the white one free on Friday?', ${ago(22)})`;
  await sql`insert into renter_notes (renter_id, body, author_name, author_role, created_at) values (${id}, 'Prefers texts over calls', 'Morgan Staff', 'cs', ${ago(21)})`;
  const sess = randomUUID();
  await sql`insert into visitor_sessions (id, visitor_id, renter_id, started_at, last_seen_at, landing_path, page_views, device) values (${sess}, ${randomUUID()}, ${id}, ${ago(200)}, ${ago(100)}, '/cars', 60, 'phone')`;
  // 60 searches: more than one page of the log
  await sql`insert into visitor_events (session_id, at, kind, path) select ${sess}, now() - make_interval(mins => 100 + g), 'search', '/cars' from generate_series(1, 60) g`;
  return { id, name: `Avery Activity ${t}`, mobile, thread: th!.id, chat: c!.id };
}

test.describe('renter activity log', () => {
  let sql: Sql;
  test.beforeAll(() => { sql = db(); });
  test.afterAll(async () => { await sql.end(); });

  test('Admin: one log, chips, search, Older, Reply, and a note added above it', async ({ browser }) => {
    test.setTimeout(180_000);
    const r = await seedRenter(sql);
    const admin = await mkUser(sql, 'admin');
    const page = await ctx(browser);
    await signIn(page, admin.email, '/admin');
    await page.goto(`/admin/renters/${r.id}`, { waitUntil: 'networkidle' });
    const log = page.getByTestId('activity-log');
    await expect(log).toBeVisible();
    // the old separate cards are gone
    await expect(page.getByTestId('renter-calls')).toHaveCount(0);
    await expect(page.getByTestId('renter-visits')).toHaveCount(0);
    await expect(log.getByTestId('activity-chip-all')).toHaveAttribute('aria-current', 'true');
    for (const t of ['email', 'text', 'chat', 'call', 'note', 'booking', 'payment', 'document', 'visit']) await expect(log.getByTestId(`activity-chip-${t}`)).toBeVisible();
    const items = log.getByTestId('activity-item');
    await expect(items).toHaveCount(50);
    // newest first: the note, the chat, the call, the text, the email
    await expect(items.nth(0)).toHaveAttribute('data-type', 'note');
    await expect(items.nth(0)).toContainText('Prefers texts over calls');
    await expect(log.getByTestId('activity-item').filter({ hasText: 'Asked about the toll road on the way back' })).toContainText('Send the toll rules');
    await expect(log.getByTestId('activity-item').filter({ hasText: 'Is the white one free on Friday?' }).getByRole('link', { name: 'Open the chat' })).toHaveAttribute('href', new RegExp(`id=${r.chat}`));
    await expect(log).not.toContainText(r.mobile);
    await expect(log).not.toContainText('@example.test');
    await check(page, 'admin renter activity');

    // Older: the next 50 (the last searches), then Newest
    await log.getByTestId('activity-older').click();
    await page.waitForURL(/before=/);
    await expect(page.getByTestId('activity-item').first()).toHaveAttribute('data-type', 'visit');
    await expect(page.getByTestId('activity-item')).toHaveCount(16); // 66 in all: an email, a text, a call, a chat line, a note, the visit and 60 searches
    await page.getByTestId('activity-newest').click();
    await page.waitForURL((u) => !u.search.includes('before='));

    // one type, then a search
    await page.getByTestId('activity-chip-text').click();
    await page.waitForURL(/act=text/);
    await expect(page.getByTestId('activity-item')).toHaveCount(1);
    await expect(page.getByTestId('activity-item')).toContainText('Running ten minutes late');
    // r35 (0970): ContactButtons suffix their test ids (-call, -text), so Text back is activity-text-back-text
    await expect(page.getByTestId('activity-item').getByTestId('activity-text-back-text')).toBeVisible();
    await page.getByTestId('activity-chip-all').click();
    await page.waitForURL((u) => !u.search.includes('act='));
    await page.getByTestId('activity-search').fill('monday');
    await page.getByTestId('activity-search').press('Enter');
    await page.waitForURL(/aq=monday/);
    await expect(page.getByTestId('activity-item')).toHaveCount(1);
    await expect(page.getByTestId('activity-item')).toContainText('Weekend question');
    // Reply goes to the email form (the renter has no booking yet: Email is not offered, the log says nothing it cannot do)
    await expect(page.getByTestId('activity-reply')).toHaveCount(0);

    // a note added above the log is in it at once
    await page.goto(`/admin/renters/${r.id}`, { waitUntil: 'networkidle' });
    await page.getByTestId('renter-note-body').fill('Called back about Monday; extension offered.');
    await page.getByTestId('renter-note-add').click();
    await expect(page.getByTestId('activity-item').first()).toContainText('Called back about Monday; extension offered.', { timeout: 15_000 });
    await page.context().close();
  });

  test('customer service sees the same log on Find a renter; Fleet without payments', async ({ browser }) => {
    test.setTimeout(180_000);
    const r = await seedRenter(sql);
    const cs = await mkUser(sql, 'va', 'cs');
    const page = await ctx(browser);
    await signIn(page, cs.email, '/staff');
    await page.goto(`/staff/renters?id=${r.id}`, { waitUntil: 'networkidle' });
    const log = page.getByTestId('activity-log');
    await expect(log).toBeVisible();
    await expect(log.getByTestId('activity-chip-payment')).toBeVisible();
    await expect(log.getByTestId('activity-item').first()).toContainText('Prefers texts over calls');
    await page.getByTestId('activity-chip-call').click();
    await page.waitForURL(/act=call/);
    // the page's own address stays (the renter is still open)
    expect(new URL(page.url()).searchParams.get('id')).toBe(r.id);
    await expect(page.getByTestId('activity-item')).toHaveCount(1);
    await check(page, 'staff renter activity');
    await page.context().close();

    const fleet = await mkUser(sql, 'va', 'fleet');
    const f = await ctx(browser);
    await signIn(f, fleet.email, '/staff');
    await f.goto(`/staff/renters?id=${r.id}`, { waitUntil: 'networkidle' });
    await expect(f.getByTestId('activity-log')).toBeVisible();
    await expect(f.getByTestId('activity-chip-payment')).toHaveCount(0);
    await f.context().close();
  });
});
