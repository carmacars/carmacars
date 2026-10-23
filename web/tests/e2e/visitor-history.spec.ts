import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { db, noOverflow } from './helpers';

// Migration 0118 end to end, at 375 and 1440: a visitor who accepted analytics views three pages and sends a booking
// request; two hours later (the visit is made two hours old) the visitor job works out its summary and the day's
// totals. An Admin finds it in Today > Visitor history: the daily chart and totals, the row with where it came from,
// its pages and what it led to, the filters (device, "led to"), and the visit in full with the time on each page.
// Customer service does not get the page.
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
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
async function ctx(browser: Browser, extra: Record<string, string> = {}) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(),
    baseURL: test.info().project.use.baseURL, extraHTTPHeaders: extra });
  return c.newPage();
}
async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await b.isVisible().catch(() => false)) await b.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 20_000 });
}
async function person(sql: ReturnType<typeof db>, role: 'admin' | 'va', name: string) {
  const id = randomUUID(); const email = `${role}.vh.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`${name} ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, staff_type, va_function, home_address, home_postal_code) values (${id}, 'va', 'cs', '1 Test Lane, Testville', 'X9X 9X9')`;
  return email;
}

test.describe.configure({ mode: 'serial' });

test('Visitor history: an Admin sees past visits with the daily chart, filters them and opens one in full; customer service cannot', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  try {
    const adminEmail = await person(sql, 'admin', 'Vera History');
    const csEmail = await person(sql, 'va', 'Cyril Service');

    // the visitor: analytics accepted, the home page, a car, the FAQ
    const v = await ctx(browser, { 'x-cc-city': 'Kingston', 'x-cc-region': 'ON', 'x-cc-country': 'CA' });
    await v.goto('/', { waitUntil: 'networkidle' });
    // Ontario: analytics are on with a notice (0075); elsewhere the banner asks first. Either way, analytics.
    const choice = v.locator('[data-testid="cookie-accept"], [data-testid="cookie-ok"]').first();
    await choice.waitFor({ timeout: 8_000 }).then(() => choice.click()).catch(() => undefined);
    const [car] = await sql`select slug from public_vehicle_listings order by slug limit 1`;
    await v.goto(`/cars/${car!.slug}`, { waitUntil: 'networkidle' });
    await v.goto('/faq', { waitUntil: 'networkidle' });
    const sid = await v.evaluate(() => (JSON.parse(sessionStorage.getItem('cc_sid') ?? '{}') as { id?: string }).id ?? '');
    expect(sid).toMatch(/^[0-9a-f-]{36}$/);
    await expect.poll(async () => Number((await sql`select page_views from visitor_sessions where id = ${sid}`)[0]?.page_views ?? 0), { timeout: 25_000 }).toBeGreaterThanOrEqual(2);
    // the FAQ's view is recorded before the visit is made two hours old (else it lands now, after the summary)
    await expect.poll(async () => Number((await sql`select count(*)::integer as n from visitor_events where session_id = ${sid} and path = '/faq'`)[0]?.n ?? 0), { timeout: 25_000 }).toBeGreaterThanOrEqual(1);
    await v.context().close();

    // two hours later: the visit is over and sent a request; the visitor job (every 15 minutes) works it out
    await sql`update visitor_events set at = at - interval '2 hours' where session_id = ${sid}`;
    await sql`update visitor_sessions set started_at = started_at - interval '2 hours', last_seen_at = last_seen_at - interval '2 hours' where id = ${sid}`;
    await sql`insert into visitor_events (session_id, at, kind, path) select ${sid}, max(at) + interval '30 seconds', 'request_submitted', '/book/sent/R-VH' from visitor_events where session_id = ${sid}`;
    await sql`select app.job_visitor_history()`;
    const [s] = await sql`select conversions, summary_at from visitor_sessions where id = ${sid}`;
    expect(s!.summary_at, 'summarized by the job').not.toBeNull();
    expect(s!.conversions).toEqual(['request']);

    // Admin > Today > Visitor history
    const page = await ctx(browser);
    await signIn(page, adminEmail);
    await page.goto('/admin/live/history', { waitUntil: 'networkidle' });
    await expect(page.getByRole('heading', { level: 1, name: 'Visitor history' })).toBeVisible();
    await expect(page.getByTestId('vh-intro')).toContainText('worked out 30 minutes after it ends');
    await expect(page.locator('.ad-tile').filter({ hasText: 'Visits' }).first()).toBeVisible();
    await expect(page.getByTestId('vh-chart')).toBeVisible();
    // the top pages: the day's rollup counts this visit's /faq (or the day already has its 20 pages, as a full run of
    // the tests does); the card shows the dates' first pages, which the other tests' visits of the day decide
    const [faq] = await sql`with d as (select app.local_date(started_at) as day from visitor_sessions where id = ${sid})
      select exists (select 1 from visitor_daily_top t, d where t.day = d.day and t.dim = 'page' and t.key = '/faq' and t.n >= 1)
          or (select count(*) from visitor_daily_top t, d where t.day = d.day and t.dim = 'page') = 20 as ok`;
    expect(faq!.ok, '/faq in the day\'s top pages').toBe(true);
    const from = await page.locator('#vh-from').inputValue();
    const to = await page.locator('#vh-to').inputValue();
    const [top] = await sql`select app.visitor_history_summary(${from}::date, ${to}::date) -> 'top' -> 'page' -> 0 ->> 'key' as key`;
    expect(top!.key).toBeTruthy();
    await expect(page.getByTestId('vh-top-pages')).toContainText(`(${top!.key})`);
    const row = page.locator('[data-testid="vh-table"] tr').filter({ has: page.locator(`a[href="/admin/live/history/${sid}"]`) });
    await expect(row).toHaveCount(1);
    await expect(row).toContainText('Request sent');
    await expect(row).toContainText('Kingston');
    await check(page, 'visitor history');

    // the filters: its device keeps it, "a booking confirmed" does not
    const [dv] = await sql`select device from visitor_sessions where id = ${sid}`;
    const device = ({ phone: 'Phone', tablet: 'Tablet', desktop: 'Computer' } as Record<string, string>)[String(dv!.device)] ?? 'Computer';
    await page.getByTestId('vh-filters').getByLabel('Device').selectOption({ label: device });
    await page.getByTestId('vh-apply').click();
    await page.waitForURL(/device=/);
    await expect(page.locator(`a[href="/admin/live/history/${sid}"]`)).toHaveCount(1);
    await page.getByTestId('vh-filters').getByLabel('Led to').selectOption({ label: 'A booking confirmed' });
    await page.getByTestId('vh-apply').click();
    await page.waitForURL(/converted=booking/);
    await expect(page.locator(`a[href="/admin/live/history/${sid}"]`)).toHaveCount(0);
    await page.getByTestId('vh-filters').getByLabel('Led to').selectOption({ label: 'A request sent' });
    await page.getByTestId('vh-apply').click();
    await page.waitForURL(/converted=request/);

    // the visit in full
    await page.locator(`a[href="/admin/live/history/${sid}"]`).click();
    await page.waitForURL(`**/admin/live/history/${sid}`);
    await expect(page.getByTestId('vh-visit')).toContainText('Request sent');
    await expect(page.getByTestId('vh-visit')).toContainText('Kingston');
    await expect(page.getByTestId('vh-visit')).toContainText('Analytics accepted');
    // the pages after the cookie choice: the car, the FAQ, the request sent
    await expect(page.getByTestId('vh-page').filter({ hasText: 'Car page' }).first()).toBeVisible();
    await expect(page.getByTestId('vh-page').filter({ hasText: '/faq' }).first()).toBeVisible();
    expect(await page.getByTestId('vh-page').count()).toBeGreaterThanOrEqual(3);
    await expect(page.getByTestId('vh-page').filter({ hasText: '/faq' }).first()).toContainText(/\d+ (s|min)/);
    await check(page, 'a visit');
    await page.context().close();

    // customer service: not theirs
    const cs = await ctx(browser);
    await signIn(cs, csEmail);
    await cs.goto('/admin/live/history', { waitUntil: 'networkidle' });
    await expect(cs.getByTestId('vh-list')).toHaveCount(0);
    await cs.context().close();
  } finally {
    await sql.end();
  }
});

// 0121: the lawyer approved the 13 months; the privacy policy says so, with its new date
test('privacy policy: visit summaries kept 13 months, last updated October 23, 2026', async ({ page }) => {
  await page.goto('/privacy');
  const row = page.locator('tr').filter({ hasText: 'Site visit summaries' });
  await expect(row).toHaveCount(1);
  await expect(row).toContainText('13 months; daily totals without personal information are kept');
  await expect(page.locator('body')).toContainText('Last updated October 23, 2026.');
  await check(page, '/privacy');
});
