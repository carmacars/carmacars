import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { db, noOverflow } from './helpers';

// Migration 0086 end to end, at 375 and 1440: a visitor who accepted analytics prices a car for dates two days away,
// opens a question, taps the phone number and starts the request form; Sales sees the visit on Live visitors with
// its booking likelihood, the reasons, the signals with their strength and the suggested message, and invites the
// visitor to chat in one click (the visitor gets the bubble). An Admin opens Signal settings, changes a weight and
// saves. Every staff page is checked with axe, for overflow and the copy rules.
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
const day = (n: number) => { const d = new Date(Date.now() + n * 86_400_000); return d.toLocaleDateString('en-CA', { timeZone: 'America/Toronto' }); };

async function mkUser(sql: Sql, role: 'admin' | 'sales') {
  const id = randomUUID(); const name = `Sid Signal${role} ${tag()}`; const email = `${role}.sg.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (role === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  else {
    await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
    await sql`insert into staff_profiles (user_id, staff_type, va_function) values (${id}, 'va', 'sales')`;
  }
  return { id, email, name };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await b.isVisible().catch(() => false)) await b.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
}
async function ctx(browser: Browser, extra: Record<string, string> = {}) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(),
    baseURL: test.info().project.use.baseURL, extraHTTPHeaders: extra });
  return c.newPage();
}
/** The next answer of the beacon (it sends a batch a few seconds after events, or at once on a page change). */
const beacon = (page: Page) => page.waitForResponse((r) => r.url().endsWith('/api/t') && r.request().method() === 'POST', { timeout: 25_000 });

test.describe.configure({ mode: 'serial' });

test('Signals: a visitor who prices a car for soon, opens a question, taps the phone and starts a request shows as likely to book, and one click invites them to chat', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const sales = await mkUser(sql, 'sales');
  const camp = tag();
  const v = await ctx(browser, { 'x-cc-city': 'Toronto', 'x-cc-region': 'ON', 'x-cc-country': 'CA' });
  await v.goto(`/?utm_source=e2e&utm_campaign=${camp}`, { waitUntil: 'networkidle' });
  await v.getByRole('button', { name: 'Accept all' }).first().click();
  // the car for dates two days away: the dates searched and the price shown
  const from = day(2), to = day(5);
  // a car free for those dates (the seed books some cars in the coming days)
  const [free] = await sql`select l.slug from public_vehicle_listings l
    where app.vehicle_is_available(l.vehicle_id, (${from} || ' 10:00')::timestamp at time zone 'America/Toronto', (${to} || ' 10:00')::timestamp at time zone 'America/Toronto')
    order by l.slug limit 1`;
  const slug = free!.slug as string;
  let sent = beacon(v);
  await v.goto(`/cars/${slug}?from=${from}&to=${to}&tf=10:00&tt=10:00&utm_source=e2e&utm_campaign=${camp}`, { waitUntil: 'load' });
  await sent;
  await expect(v.locator('.estimate__lines')).toBeVisible({ timeout: 20_000 });
  // a question opened (its topic only), and the phone number tapped (the call itself is not made here)
  await v.evaluate(() => document.addEventListener('click', (e) => { if ((e.target as Element).closest('a[href^="tel:"]')) e.preventDefault(); }));
  const q = v.locator('.faq details summary').first();
  await q.scrollIntoViewIfNeeded();
  await q.click();
  await v.locator('a[href^="tel:"]').first().click();
  sent = beacon(v);
  await sent;
  // the request form: the first field touched starts it. The field is touched once the form page's own beacon has sent
  // its page view (the car page's last batch, sent as it closes, can answer first; a field touched before the form
  // page's beacon runs is never seen), and the signals are read once the database has them (under load /api/t answers
  // 204 and stores the batch in the background)
  const bookView = v.waitForRequest((r) => r.url().endsWith('/api/t') && r.method() === 'POST' && /"page_view"/.test(r.postData() ?? '') && (r.postData() ?? '').includes(`/book/${slug}`), { timeout: 25_000 });
  await v.goto(`/book/${slug}?from=${from}&to=${to}&tf=10:00&tt=10:00`, { waitUntil: 'load' });
  await bookView;
  await v.locator('form input, form select').first().focus();
  const read = async () => (await sql`select s.id, s.score, (select string_agg(kind, ',' order by kind) from visitor_live_signals l where l.session_id = s.id and l.active) as kinds
                          from visitor_sessions s where s.utm ->> 'campaign' = ${camp} order by s.last_seen_at desc limit 1`)[0];
  await expect.poll(async () => String((await read())?.kinds ?? ''), { timeout: 30_000, intervals: [1_000] }).toContain('form_reached');
  const s = await read();
  expect(s?.kinds).toContain('price_seen');
  expect(s?.kinds).toContain('contact_tap');
  expect(s?.kinds).toContain('form_reached');
  expect(s?.kinds).toContain('soon_pickup');
  expect(s?.kinds).toContain('help_read');
  // nothing typed is ever recorded: the events carry only their listed details
  const keys = await sql`select distinct jsonb_object_keys(data) as k from visitor_events where session_id = ${s!.id}`;
  for (const k of keys.map((x) => x.k as string)) expect(['pickup', 'return', 'days', 'total', 'avail', 'deliv', 'xdrv', 'step', 'topic', 'via', 'n', 'sort', 'filter', 'maxp', 'type', 'booking_number', 'code']).toContain(k);

  const staff = await ctx(browser);
  await signIn(staff, sales.email, '/va');
  await staff.goto('/va/live', { waitUntil: 'networkidle' });
  const row = staff.getByTestId('live-row').filter({ hasText: `campaign e2e/${camp}` });
  await expect(row).toBeVisible({ timeout: 15_000 });
  await expect(row.getByTestId('score')).toHaveText(new RegExp(`^${s!.score}`));
  await expect(row.getByTestId('reasons')).toContainText('Tapped to call');
  await expect(row).toContainText('Saw the full price');
  await expect(row).toContainText('Reached the booking form');
  await expect(row).toContainText('Pickup soon');
  await expect(row.getByTestId('suggested')).toContainText('Suggested: Invite to chat');
  await check(staff, 'va live visitors with signals');
  // the sort and the filter
  await staff.getByTestId('lv-sort').selectOption('recent');
  await expect(row).toBeVisible();
  await staff.getByTestId('lv-sort').selectOption('score');
  // one click: the suggested message goes to the visitor
  await row.getByTestId('act-invite').click();
  await expect(row).toContainText('The visitor sees your message', { timeout: 10_000 });
  await expect(row).toContainText(/Invited by Sid/, { timeout: 15_000 });
  sent = beacon(v);
  await v.goto(`/cars/${slug}?ref=again`, { waitUntil: 'load' });
  await sent;
  await expect(v.getByTestId('chat-bubble')).toContainText('If it is easier than calling', { timeout: 40_000 });
  const [a] = await sql`select action, signal from visitor_actions where session_id = ${s!.id} order by at desc limit 1`;
  expect(a).toMatchObject({ action: 'chat', signal: 'contact_tap' });
  // the menu counts hot visitors on the site when there are any
  await sql.end();
});

test('Signal settings: an Admin changes a signal\'s points and saves; Live visitors links to it', async ({ browser }) => {
  test.setTimeout(120_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin');
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto('/admin/live', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('live-visitors')).toBeVisible();
  await expect(page.getByTestId('hot-today')).toBeVisible();
  await check(page, 'admin live visitors');
  await page.getByTestId('signal-settings-link').click();
  await page.waitForURL('**/admin/live/signals');
  await expect(page.getByTestId('signal-settings')).toBeVisible();
  await expect(page.getByTestId('rule')).toHaveCount(35);
  const [before] = await sql`select weight from visitor_signal_rules where code = 'price_seen'`;
  const field = page.locator('#w-price_seen');
  await field.fill(String(Number(before!.weight) + 1));
  await page.getByTestId('save-rules').click();
  await expect(page.getByText('Saved 1 signal.')).toBeVisible({ timeout: 10_000 });
  const [after] = await sql`select weight from visitor_signal_rules where code = 'price_seen'`;
  expect(Number(after!.weight)).toBe(Number(before!.weight) + 1);
  await sql`update visitor_signal_rules set weight = ${before!.weight} where code = 'price_seen'`;
  await check(page, 'admin signal settings');
  await sql.end();
});
