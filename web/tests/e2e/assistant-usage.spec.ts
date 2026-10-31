import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { aiAllowanceLock, db, noOverflow } from './helpers';

// Migration 0080 end to end, at 375 and 1440, with the deterministic stub model (LLM_PROVIDER=fake). The usage guard:
// Workers AI used up shows the card on Admin > To do, stopped for today and never paid (0133); images used up show
// "Allow paid usage" and its cost, and allowing up to $1 this month opens them again; Settings > Usage lists every service with its meter and 30 days. The staff assistant: opened from the header
// button and with Ctrl+/; a read answers with cards; a change is a card that runs only on Confirm, through the door, as
// the person (audited "via assistant"); Cancel changes nothing; an assistant (VA) cannot reach an Admin's action. Paused:
// the assistant says it rests until tomorrow, and a visitor's live chat goes to a person with "Our assistant is resting".
// The tests change the day's Workers AI figures: run them with --workers=1.
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
async function person(sql: Sql, role: 'admin' | 'va', fn?: 'cs' | 'fleet' | 'finance') {
  const id = randomUUID(); const email = `${role}${fn ?? ''}.as.${Date.now()}.${tag()}@example.test`; const name = `Ada ${role === 'admin' ? 'Admin' : 'Assist'} ${tag()}`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, staff_type, va_function, home_address, home_postal_code) values (${id}, 'va', ${fn!}, '1 Test Lane, Toronto', 'M5V 1A1')`;
  return { id, email, name };
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function signIn(page: Page, email: string, path: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await b.isVisible().catch(() => false)) await b.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(path), { timeout: 60_000 });
}
/** The day's Workers AI figure, as the app records it; and the guard's refresh (the hourly job). */
async function neurons(sql: Sql, n: number) {
  await sql`delete from provider_calls where purpose = 'e2e_usage'`;
  if (n > 0) await sql`insert into provider_calls (provider, purpose, ok, units, unit) values ('workers-ai', 'e2e_usage', true, ${n}, 'neurons')`;
  await sql`delete from usage_decisions where service = 'workers_ai'`;
  await sql`update usage_services set paid_extra = 0 where service = 'workers_ai'`;
  await sql`select app.job_usage_refresh()`;
}
async function openAssistant(page: Page) {
  await page.getByTestId('assistant-open').first().click();
  await expect(page.getByTestId('assistant-panel')).toBeVisible();
}
async function askIt(page: Page, text: string) {
  await page.getByTestId('assistant-input').fill(text);
  await page.getByTestId('assistant-send').click();
  await expect(page.getByTestId('assistant-busy')).toHaveCount(0, { timeout: 30_000 });
}

test.describe.configure({ mode: 'serial' });

test.afterAll(async () => { const sql = db(); await neurons(sql, 0); await sql.end(); });
// each test moves the day's AI figure: no car copy test runs meanwhile (helpers.ts, aiAllowanceLock)
let unlock: (() => Promise<void>) | null = null;
test.beforeEach(async () => { unlock = await aiAllowanceLock('alone'); });
test.afterEach(async () => { const sql = db(); await neurons(sql, 0); await sql.end(); await unlock?.(); unlock = null; });

test('Usage guard: the used-up card on To do, the cost pop-up, paid usage up to a cap, and Settings > Usage', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  const a = await person(sql, 'admin');
  await neurons(sql, 10_400);
  const page = await ctx(browser);
  await signIn(page, a.email, '/admin');
  await page.goto('/admin', { waitUntil: 'networkidle' });
  const card = page.getByTestId('usage-card-workers_ai');
  // Workers AI is a hard stop at the free allowance (0133): no paid usage to allow
  await expect(card).toContainText('Included Workers AI used up for today');
  await expect(card).toContainText('Stopped for today, never paid.');
  await expect(card.getByTestId('usage-allow-workers_ai')).toHaveCount(0);
  await check(page, 'admin to do with the usage card');
  // paid usage where it may be paid: images, with the cost pop-up
  await sql`insert into provider_calls (provider, purpose, ok, units, unit) values ('e2e', 'e2e_images', true, 5200, 'transformations')`;
  await sql`delete from usage_decisions where service = 'images'`;
  await sql`select app.job_usage_refresh()`;
  await page.goto('/admin', { waitUntil: 'networkidle' });
  const img = page.getByTestId('usage-card-images');
  await expect(img).toContainText('Allow paid usage');
  await img.getByTestId('usage-allow-images').click();
  const dlg = page.getByTestId('usage-allow-images-dialog');
  await expect(dlg).toBeVisible();
  await expect(dlg.getByTestId('usage-allow-images-cost')).toContainText('per 1,000 transformations');
  await check(page, 'paid usage pop-up');
  await dlg.getByTestId('usage-allow-images-cap').fill('0');
  await dlg.getByTestId('usage-allow-images-submit').click();
  await expect(dlg.getByRole('alert')).toContainText('US$0.01 to US$1,000');
  await dlg.getByTestId('usage-allow-images-cap').fill('1');
  await dlg.getByTestId('usage-allow-images-submit').click();
  await expect(page.getByTestId('usage-paid-images')).toContainText('Paid usage allowed until the end of this month, up to US$1.00', { timeout: 15_000 });
  await sql`delete from provider_calls where purpose = 'e2e_images'`;
  await sql`delete from usage_decisions where service = 'images'`;
  await sql`select app.job_usage_refresh()`;

  await page.goto('/admin/settings/usage', { waitUntil: 'networkidle' });
  await expect(page.getByRole('heading', { name: 'Usage', level: 1 })).toBeVisible();
  for (const svc of ['workers_ai', 'workers_requests', 'workers_cpu', 'images', 'resend_day', 'resend_month', 'supabase_db', 'supabase_storage', 'r2_storage', 'github_actions', 'claude']) {
    await expect(page.getByTestId(`usage-${svc}`)).toBeVisible();
  }
  // 0194: the database and files are on our own server; data sent out is not measured there (retired, hidden)
  await expect(page.getByTestId('usage-supabase_egress')).toHaveCount(0);
  await expect(page.getByTestId('usage-workers_ai-paid')).toContainText('Never');
  await expect(page.getByTestId('usage-ai-features')).toBeVisible();
  await expect(page.getByTestId('usage-workers_requests-paid')).toContainText('Never paused');
  await expect(page.getByTestId('usage-chart-workers_ai')).toBeVisible();
  await check(page, 'settings usage');
  // an allowance an Admin changes
  await page.getByTestId('usage-edit-supabase_db').click();
  await page.getByTestId('usage-edit-supabase_db-form').getByLabel('Included (MB)').fill('10240');
  await page.getByTestId('usage-edit-supabase_db-submit').click();
  await expect(page.getByTestId('usage-supabase_db-used')).toContainText('of 10.00 GB', { timeout: 15_000 });
  await sql`update usage_services set included = 8589934592 where service = 'supabase_db'`;
  await neurons(sql, 0);
  await sql.end();
});

test('Assistant (Admin): opened from the header and Ctrl+/, a read answers with cards, a change runs only on Confirm, as the Admin', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  await neurons(sql, 0);
  const a = await person(sql, 'admin');
  const page = await ctx(browser);
  await signIn(page, a.email, '/admin');
  await page.goto('/admin', { waitUntil: 'networkidle' });
  await openAssistant(page);
  await check(page, 'assistant panel, empty');
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('assistant-panel')).toBeHidden();
  await page.keyboard.press('Control+/');
  await expect(page.getByTestId('assistant-panel')).toBeVisible();

  await askIt(page, 'What needs doing today?');
  await expect(page.getByTestId('assistant-results').first()).toContainText(/things need you|Nothing needs you/);
  await expect(page.getByTestId('assistant-results').last()).toContainText(/Pickups \d+ and returns \d+ today/);
  await askIt(page, 'Is the Corolla free from 2026-12-02 to 2026-12-04?');
  await expect(page.getByTestId('assistant-text').last()).toContainText(/Corolla/);

  // a change: the card first, nothing runs
  const title = `Call the renter back ${tag()}`;
  await askIt(page, `Create a task: ${title}`);
  const card = page.getByTestId('assistant-proposal').last();
  await expect(card.getByTestId('assistant-summary')).toHaveText(`Add the task "${title}" to the admin queue?`);
  expect((await sql`select count(*)::int as n from tasks where title = ${title}`)[0]!.n).toBe(0);
  await check(page, 'assistant with a card to confirm');
  await card.getByTestId('assistant-confirm').click();
  await expect(card.getByTestId('assistant-decided')).toHaveText('Done.', { timeout: 15_000 });
  const [t] = await sql`select queue, created_by from tasks where title = ${title}`;
  expect(t).toMatchObject({ queue: 'admin', created_by: a.id });
  const [au] = await sql`select actor_user_id, after ->> 'note' as note from audit_log where action = 'assistant_action' and after ->> 'summary' like ${'%' + title + '%'}`;
  expect(au).toMatchObject({ actor_user_id: a.id, note: 'via assistant' });

  // Cancel changes nothing
  const other = `Never made ${tag()}`;
  await askIt(page, `Create a task: ${other}`);
  await page.getByTestId('assistant-proposal').last().getByTestId('assistant-cancel').click();
  await expect(page.getByTestId('assistant-proposal').last().getByTestId('assistant-decided')).toHaveText('Cancelled. Nothing was changed.');
  expect((await sql`select count(*)::int as n from tasks where title = ${other}`)[0]!.n).toBe(0);

  // more than one car matches: it asks, with the candidates as buttons
  await askIt(page, '{"action": "tool", "tool": "publish_car", "args": {"car": "Toyota"}}');
  const q = page.getByTestId('assistant-question').last();
  await expect(q).toContainText('More than one car matches "Toyota"');
  expect(await q.getByRole('button').count()).toBeGreaterThan(1);
  await check(page, 'assistant asking which car');
  await sql.end();
});

test('Assistant (VA): an assistant cannot reach an Admin\'s action; Finance-only searches are refused for Fleet', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  await neurons(sql, 0);
  const v = await person(sql, 'va', 'fleet');
  const page = await ctx(browser);
  await signIn(page, v.email, '/staff');
  await openAssistant(page);
  await askIt(page, '{"action": "tool", "tool": "record_payment", "args": {"invoice": "INV-1", "method": "cash", "received_on": "2026-10-15"}}');
  await expect(page.getByTestId('assistant-text').last()).toHaveText('I cannot do that from here. Use the screens, or ask an Admin.');
  await askIt(page, '{"action": "tool", "tool": "find", "args": {"kind": "invoice", "q": "INV"}}');
  await expect(page.getByTestId('assistant-text').last()).toContainText('Finance work');
  // the door refuses an Admin's action even when asked for directly
  const r = await page.request.post('/api/staff/assistant', { data: { portal: 'admin', text: 'What needs doing today?' } });
  expect(r.status()).toBe(403);
  await askIt(page, 'What needs doing today?');
  await expect(page.getByTestId('assistant-results').last()).toContainText(/open in your queue/);
  await check(page, 'va assistant');
  expect((await sql`select count(*)::int as n from assistant_actions where user_id = ${v.id}`)[0]!.n).toBe(0);
  await sql.end();
});

test('Paused: the assistant rests until tomorrow, never an error', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  await neurons(sql, 10_500);
  const a = await person(sql, 'admin');
  const page = await ctx(browser);
  await signIn(page, a.email, '/admin');
  await openAssistant(page);
  await askIt(page, 'What needs doing today?');
  await expect(page.getByTestId('assistant-paused')).toHaveText(/^Today's free AI allowance is used up \(1\d,\d{3} of 10,000 neurons\)\. The assistant is back at midnight, Toronto time\. Everything still works from the screens and pop-ups\.$/);
  await check(page, 'assistant paused');
  await page.context().close();
  await neurons(sql, 0);
  await sql.end();
});

test('Paused: a visitor\'s live chat goes to a person with "Our assistant is resting", never an error', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  await neurons(sql, 10_500);
  const v = await ctx(browser);
  // a visitor who accepted analytics, as in live-chat.spec.ts (the chat comes with the beacon's answer)
  await v.goto('/cars/toyota-corolla', { waitUntil: 'networkidle' });
  await v.getByRole('button', { name: 'Accept all' }).first().click();
  await expect(v.getByTestId('chat-open')).toBeVisible({ timeout: 30_000 });
  await v.getByTestId('chat-open').click();
  await v.getByLabel('Your message').fill('Is the Corolla automatic?');
  await v.getByRole('button', { name: 'Send' }).click();
  await expect(v.getByTestId('chat-log')).toContainText('Our assistant is resting until tomorrow. A person will answer you here.', { timeout: 30_000 });
  await expect(v.getByTestId('chat-log')).not.toContainText(/error|went wrong/i);
  await check(v, 'visitor chat while the assistant rests');
  const [c] = await sql`select status, human_reason from chat_conversations order by created_at desc limit 1`;
  expect(c!.status).toBe('waiting');
  expect(String(c!.human_reason)).toContain('daily included AI usage');
  await neurons(sql, 0);
  await sql.end();
});
