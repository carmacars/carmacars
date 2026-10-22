import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { db, noOverflow } from './helpers';

// Migration 0103 end to end, at 375 and 1440: a visitor who accepted analytics opens a car page and stays on it. Their
// last page view is made 10 minutes old (longer than the 5-minute live window), so without the heartbeat they would be
// gone; the page's heartbeat (lowered to 15 seconds here) brings them back on Admin > Live visitors, which refreshes by
// itself, with no new event recorded. "Live now" and "Visitors today" are on the page. Closing the tab ends the visit.
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
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await b.isVisible().catch(() => false)) await b.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
}
const isBeat = (body: string | null) => /"beat":1/.test(body ?? '');

test.describe.configure({ mode: 'serial' });

test('Heartbeat: a visitor idle on one page longer than the live window still shows as live in Admin, and closing the tab ends the visit', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const [before] = await sql`select visitor_heartbeat_seconds as beat, visitor_live_minutes as live from program_settings where id = (app.settings()).id`;
  await sql`update program_settings set visitor_heartbeat_seconds = 15 where id = (app.settings()).id`;
  try {
    const id = randomUUID(); const email = `admin.hb.${Date.now()}.${tag()}@example.test`;
    await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
    await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Hana Beat ${tag()}`})`;
    await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
    expect(Number(before!.live), 'the live window is 5 minutes').toBe(5);

    // the visitor: analytics accepted, on one car page
    const v = await ctx(browser, { 'x-cc-city': 'Hamilton', 'x-cc-region': 'ON', 'x-cc-country': 'CA' });
    await v.goto('/', { waitUntil: 'networkidle' });
    await v.getByRole('button', { name: 'Accept all' }).first().click();
    const [car] = await sql`select slug from public_vehicle_listings order by slug limit 1`;
    const first = v.waitForResponse((r) => r.url().endsWith('/api/t') && !isBeat(r.request().postData()), { timeout: 25_000 });
    await v.goto(`/cars/${car!.slug}`, { waitUntil: 'load' });
    expect((await first).status()).toBe(200);
    const sid = await v.evaluate(() => (JSON.parse(sessionStorage.getItem('cc_sid') ?? '{}') as { id?: string }).id ?? '');
    expect(sid).toMatch(/^[0-9a-f-]{36}$/);
    await expect.poll(async () => (await sql`select current_path from visitor_sessions where id = ${sid}`)[0]?.current_path, { timeout: 20_000 }).toBe(`/cars/${car!.slug}`);

    // they have been reading this page for 10 minutes: longer than the live window
    await sql`update visitor_sessions set last_seen_at = now() - interval '10 minutes', started_at = now() - interval '10 minutes' where id = ${sid}`;
    const events = Number((await sql`select count(*)::int as n from visitor_events where session_id = ${sid}`)[0]!.n);
    const liveIds = async () => ((await sql`select app.live_visitors(${id}::uuid) -> 'now' as now`)[0]!.now as Array<{ id: string }>).map((x) => x.id);
    expect(await liveIds(), 'without a heartbeat they would not be live').not.toContain(sid);

    // Admin > Live visitors, open before the heartbeat: the visitor appears by itself (the page refreshes every 15 seconds)
    const page = await ctx(browser);
    await signIn(page, email, '/admin');
    await page.goto('/admin/live', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('live-visitors')).toBeVisible();
    await expect(page.locator('.ad-tile').filter({ hasText: 'Live now' })).toBeVisible();
    await expect(page.locator('.ad-tile').filter({ hasText: 'Visitors today' }).getByTestId('visitors-today')).toHaveText(/^\d+$/);
    await expect(page.locator(`#lv-${sid}`)).toHaveCount(0);

    // the visitor's heartbeat (15 seconds here): one small request, answered at once
    const beat = await v.waitForResponse((r) => r.url().endsWith('/api/t') && isBeat(r.request().postData()), { timeout: 45_000 });
    expect([200, 204]).toContain(beat.status());
    await expect.poll(liveIds, { timeout: 15_000 }).toContain(sid);
    const after = Number((await sql`select count(*)::int as n from visitor_events where session_id = ${sid}`)[0]!.n);
    expect(after, 'a heartbeat records no event').toBe(events);

    await expect(page.locator(`#lv-${sid}`)).toBeVisible({ timeout: 30_000 });
    await expect(page.locator(`#lv-${sid}`)).toContainText('Hamilton');
    expect(Number(await page.getByTestId('live-count').innerText())).toBeGreaterThanOrEqual(1);
    await check(page, 'admin live visitors with a heartbeat visitor');

    // the tab closes: the last beacon ends the visit, and the visitor leaves the list
    await v.close({ runBeforeUnload: true });
    await expect.poll(async () => (await sql`select ended_at is not null as ended from visitor_sessions where id = ${sid}`)[0]?.ended, { timeout: 20_000 }).toBe(true);
    expect(await liveIds()).not.toContain(sid);
    await expect(page.locator(`#lv-${sid}`)).toHaveCount(0, { timeout: 30_000 });
    await page.context().close();
  } finally {
    await sql`update program_settings set visitor_heartbeat_seconds = ${before!.beat} where id = (app.settings()).id`;
    await sql.end();
  }
});
