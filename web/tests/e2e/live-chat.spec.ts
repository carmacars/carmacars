import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { db, noOverflow } from './helpers';

// Migration 0060 end to end, at 375 and 1440: a visitor who accepted analytics looks at six cars and shows on Live
// visitors with "Viewing spree"; the chat's assistant answers a price from the pricing function (the fake model locally,
// Workers AI in production); "Talk to a person" brings customer service, who takes over and replies in real time and
// hands back; a proactive chat from the Live page reaches the visitor as a bubble. Every staff page is checked with axe,
// for overflow and the copy rules.
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
const CARS = ['toyota-corolla', 'hyundai-elantra', 'mercedes-benz-a220', 'mercedes-benz-cla250', 'mercedes-benz-c300', 'tesla-model-3'];
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
const day = (n: number) => { const d = new Date(Date.now() + n * 86_400_000); return d.toISOString().slice(0, 10); };

async function mkStaff(sql: Sql, fn: 'cs' | 'sales') {
  const id = randomUUID(); const name = `Lena Live${fn} ${tag()}`; const email = `va${fn}.lc.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
  await sql`insert into staff_profiles (user_id, staff_type, va_function) values (${id}, 'va', ${fn})`;
  return { id, email, name, first: name.split(' ')[0]! };
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
/** A visitor who accepted analytics (the beacon then records pages and cars). */
async function visitor(browser: Browser, campaign = tag()) {
  const page = await ctx(browser, { 'x-cc-city': 'Toronto', 'x-cc-region': 'ON', 'x-cc-country': 'CA' });
  // a campaign of its own tells this visitor apart on the Live page (the other width runs at the same time)
  await page.goto(`/?utm_source=e2e&utm_campaign=${campaign}`, { waitUntil: 'networkidle' });
  await page.getByRole('button', { name: 'Accept all' }).first().click();
  await viewAndBeacon(page, `/?utm_source=e2e&utm_campaign=${campaign}`);
  return page;
}
/** The beacon loads after the page is idle and sends at once; wait for its answer. */
async function viewAndBeacon(page: Page, path: string) {
  const sent = page.waitForResponse((r) => r.url().endsWith('/api/t') && r.request().method() === 'POST', { timeout: 20_000 });
  await page.goto(path, { waitUntil: 'load' });
  await sent;
}
async function openMenuIfPhone(page: Page, nav: string) {
  if (isPhone()) await page.getByTestId(nav).getByRole('button', { name: /^Menu\. You are on/ }).click();
}

test.describe.configure({ mode: 'serial' });

test('Live visitors: a visitor viewing six cars shows with a viewing spree for customer service, and the car counts the views', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const cs = await mkStaff(sql, 'cs');
  const camp = tag();
  const v = await visitor(browser, camp);
  for (const slug of CARS) await viewAndBeacon(v, `/cars/${slug}`);
  // the chat button waits until the cookie banner is answered, then sits in the corner
  await expect(v.getByTestId('chat-open')).toBeVisible({ timeout: 15_000 });

  const staff = await ctx(browser);
  await signIn(staff, cs.email, '/staff');
  await openMenuIfPhone(staff, 'va-nav');
  // Live visitors, Live chat and Game leads are their own group, Live (October 23, 2026)
  await staff.getByTestId('va-nav').getByTestId('nav-group-live').click();
  await expect(staff.getByTestId('va-nav').getByRole('link', { name: 'Live visitors' })).toBeVisible();
  await expect(staff.getByTestId('va-nav').getByRole('link', { name: 'Live chat' })).toBeVisible();
  await staff.goto('/staff/live', { waitUntil: 'networkidle' });
  const row = staff.getByTestId('live-row').filter({ hasText: `campaign e2e/${camp}` });
  await expect(row).toBeVisible({ timeout: 15_000 });
  await expect(row).toContainText('Visitor from Toronto');
  await expect(row).toContainText('Viewing spree: 6 cars in 10 minutes');
  await expect(row).toContainText('Now on Car page');
  await expect(staff.getByTestId('live-signals')).toContainText('Viewing spree: 6 cars in 10 minutes');
  await expect(staff.getByTestId('most-viewed')).toContainText('Tesla');
  await row.getByRole('button', { name: 'Pages' }).click();
  await expect(row.locator('.lv-events')).toContainText('Opened a car');
  await check(staff, 'va live visitors');
  // the visitor moves on: the Live page follows without a reload (it refreshes every 15 seconds since 0103)
  await viewAndBeacon(v, '/how-it-works');
  await expect(row).toContainText('Now on How It Works', { timeout: 30_000 });
  await sql.end();
});

test('Live chat: the assistant quotes from the pricing function, a person takes over, replies and hands back', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const cs = await mkStaff(sql, 'cs');
  // customer service opens Live chat first: they are on shift
  const staff = await ctx(browser);
  await signIn(staff, cs.email, '/staff');
  await staff.goto('/staff/chat', { waitUntil: 'networkidle' });
  await check(staff, 'va live chat, empty or with others');

  const v = await visitor(browser);
  await viewAndBeacon(v, '/cars/toyota-corolla');
  await v.getByTestId('chat-open').click();
  await expect(v.getByRole('dialog', { name: 'Chat with CarmaCars' })).toBeVisible();
  const from = day(40 + Math.floor(Math.random() * 100));
  const end = new Date(new Date(from).getTime() + 2 * 86_400_000).toISOString().slice(0, 10);
  await v.getByLabel('Your message').fill(`How much is the Toyota Corolla from ${from} to ${end}?`);
  await v.getByRole('button', { name: 'Send' }).click();
  const ai = v.getByTestId('chat-log').locator('[data-sender="ai"]').last();
  await expect(ai).toContainText('in total with HST', { timeout: 30_000 });
  // the amount the visitor reads is the quote's own total (public.quote_booking), never one the model made up
  const [car] = await sql`select vehicle_id from vehicle_listings where slug = 'toyota-corolla'`;
  const [q] = await sql`select public.quote_booking(${car!.vehicle_id}, ${from + 'T10:00:00-04:00'}::timestamptz, ${end + 'T10:00:00-04:00'}::timestamptz, '{}') as q`;
  const total = (q!.q as { total_cents: number }).total_cents;
  await expect(ai).toContainText(`$${(total / 100).toLocaleString('en-CA', { minimumFractionDigits: 2 })}`);
  if (!isPhone()) await check(v, 'visitor chat open');

  // a person, please
  await v.getByRole('button', { name: 'Talk to a person' }).click();
  await expect(v.getByTestId('chat-status')).toContainText('A person will reply shortly', { timeout: 15_000 });
  const item = staff.getByTestId('chat-item').filter({ hasText: 'Waiting for a person' }).filter({ hasText: from });
  await expect(item).toBeVisible({ timeout: 15_000 });
  await item.click();
  const thread = staff.getByTestId('chat-thread');
  await expect(thread).toContainText('How much is the Toyota Corolla');
  await expect(staff.locator('.lc-side')).toContainText('Car page');
  await thread.getByRole('button', { name: 'Take over' }).click();
  await expect(staff.getByTestId('thread-status')).toContainText('With a person', { timeout: 10_000 });
  await expect(v.getByTestId('chat-status')).toContainText(`${cs.first} from CarmaCars is here`, { timeout: 15_000 });
  await staff.getByLabel('Reply').fill(`Hi, ${cs.first} here. I can send you an offer for those dates.`);
  await expect(v.getByTestId('chat-typing')).toBeVisible({ timeout: 10_000 });
  await thread.getByRole('button', { name: 'Send' }).click();
  await expect(v.getByTestId('chat-log').locator('[data-sender="staff"]').last()).toContainText('I can send you an offer', { timeout: 15_000 });
  await check(staff, 'va live chat thread');
  // the visitor answers; staff read it without a reload
  await v.getByLabel('Your message').fill('Yes please, thank you');
  await v.getByRole('button', { name: 'Send' }).click();
  await expect(thread.locator('[data-sender="visitor"]').last()).toContainText('Yes please', { timeout: 15_000 });
  // hand back to the assistant, then close
  await thread.getByRole('button', { name: 'Hand back to the assistant' }).click();
  await expect(v.getByTestId('chat-log')).toContainText('The CarmaCars assistant is back to help', { timeout: 15_000 });
  await thread.getByRole('button', { name: 'Close' }).click();
  await expect(v.getByRole('button', { name: 'Start a new chat' })).toBeVisible({ timeout: 15_000 });
  // this visitor's conversation (another test may start one meanwhile), once the close is stored
  await expect.poll(async () => (await sql`select status, first_human_reply_at is not null as replied from chat_conversations
      where exists (select 1 from chat_messages m where m.conversation_id = chat_conversations.id and m.body like ${'%' + from + '%'}) order by created_at desc limit 1`)[0], { timeout: 15_000 })
    .toMatchObject({ status: 'closed', replied: true });
  await sql.end();
});

test('Proactive chat: customer service starts a chat from Live visitors and the visitor sees the bubble', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const sales = await mkStaff(sql, 'sales');
  const camp = tag();
  const v = await visitor(browser, camp);
  await viewAndBeacon(v, '/cars/mercedes-benz-c300');
  const staff = await ctx(browser);
  await signIn(staff, sales.email, '/staff');
  await staff.goto('/staff/live', { waitUntil: 'networkidle' });
  const row = staff.getByTestId('live-row').filter({ hasText: `campaign e2e/${camp}` });
  await expect(row).toContainText('Mercedes-Benz C300', { timeout: 15_000 });
  await row.getByRole('button', { name: 'Start a chat' }).click();
  await row.getByLabel('Your message (the visitor sees it in a bubble)').fill('Hi, I am here if you have a question about the C300.');
  await row.getByRole('button', { name: 'Send' }).click();
  await expect(row).toContainText('The visitor sees your message', { timeout: 10_000 });
  // the next beacon (a page view, or the 30-second heartbeat) brings the invitation
  await viewAndBeacon(v, '/cars/mercedes-benz-c300?ref=again');
  const bubble = v.getByTestId('chat-bubble');
  await expect(bubble).toContainText('question about the C300', { timeout: 40_000 });
  await bubble.getByRole('button', { name: 'Reply' }).click();
  await expect(v.getByTestId('chat-log')).toContainText('question about the C300', { timeout: 15_000 });
  await v.getByLabel('Your message').fill('Is it automatic?');
  await v.getByRole('button', { name: 'Send' }).click();
  await staff.goto('/staff/chat', { waitUntil: 'networkidle' });
  await staff.getByTestId('chat-item').filter({ hasText: 'Is it automatic?' }).first().click();
  await expect(staff.getByTestId('chat-thread')).toContainText('Is it automatic?', { timeout: 15_000 });
  await sql.end();
});

test('Admin: Live visitors and Live chat in the menu, a car shows its interest, the renter page has the visits', async ({ browser }) => {
  test.setTimeout(120_000);
  const sql = db();
  const id = randomUUID(); const email = `admin.lc.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Ada Admin ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  const page = await ctx(browser);
  await signIn(page, email, '/admin');
  await openMenuIfPhone(page, 'admin-nav');
  await expect(page.getByTestId('admin-nav').getByRole('link', { name: 'Live visitors' })).toBeAttached();
  await page.goto('/admin/live', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('live-visitors')).toBeVisible();
  await check(page, 'admin live visitors');
  await page.goto('/admin/chat', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('chat-inbox')).toBeVisible();
  await check(page, 'admin live chat');
  const [car] = await sql`select vehicle_id from vehicle_listings where slug = 'toyota-corolla'`;
  await page.goto(`/admin/vehicles/${car!.vehicle_id}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('car-interest')).toContainText('Views, 7 days');
  const [r] = await sql`select id from renters order by created_at limit 1`;
  if (r) {
    await page.goto(`/admin/renters/${r.id}`, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('renter-visits')).toBeVisible();
    await check(page, 'admin renter page');
  }
  await sql.end();
});
