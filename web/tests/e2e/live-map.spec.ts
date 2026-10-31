import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// The Live map (migration 0242) end to end: an Admin opens Today > Live map and sees the KPI tiles, the legend with its
// counts, a pin per lead and a card per lead (masked until Show details); TV mode fills 1920x1080 and 3840x2160 with no
// scrollbars and no admin menu, with the spotlight. The map library and the tiles are blocked here, so the page draws its
// simplified map (the same pins); the test never depends on a third-party network. Fixtures are example.test only.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const offline = async (page: Page) => { await page.route(/cdn\.jsdelivr\.net|tiles\.openfreemap\.org/, (r) => r.abort()); };

async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 60_000 });
}
async function ctx(browser: Browser, w: number, h: number) {
  const c = await browser.newContext({ viewport: { width: w, height: h }, baseURL: test.info().project.use.baseURL });
  const page = await c.newPage();
  await offline(page);
  return page;
}

test.describe.configure({ mode: 'serial' });

test('Live map: pins, legend, cards and masking on the page; TV mode fills the screen at 1080p and 4K', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  const t = tag();
  const admin = randomUUID(), email = `lm.admin.${Date.now()}.${t}@example.test`;
  const vids = [randomUUID(), randomUUID(), randomUUID()];
  await sql`insert into local_auth.users (id, email, password_hash) values (${admin}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${admin}, ${email}, 'Lima Admin')`;
  await sql`insert into user_roles (user_id, role) values (${admin}, 'admin')`;
  try {
    // a visitor on the site now (Mississauga), one who typed their details into the request form (Toronto), a game player (Oakville)
    const pts: Array<[number, number, string]> = [[43.59, -79.64, 'Mississauga'], [43.65, -79.38, 'Toronto'], [43.45, -79.68, 'Oakville']];
    for (const [i, vid] of vids.entries()) {
      const [lat, lng, city] = pts[i]!;
      await sql`insert into visitor_sessions (id, visitor_id, consent, city, region, country, started_at, last_seen_at, page_views, geo_lat, geo_lng)
                values (${randomUUID()}, ${vid}, 'analytics', ${city}, 'ON', 'CA', now() - interval '6 minutes', now() - (${i} * interval '1 minute'), ${3 + i * 4}, ${lat}, ${lng})`;
    }
    await sql`insert into contact_captures (visitor_id, form, ref, name, email, phone) values (${vids[1]!}, 'booking_request', ${`lm-${t}`}, ${`Erin Example${t}`}, ${`lm.erin.${t}@example.test`}, '4165550142')`;
    await sql`insert into game_plays (visitor_id, game, prize) values (${vids[2]!}, 'wheel', '{"key": "pct10", "percent_bps": 1000}')`;

    const page = await ctx(browser, phone ? 375 : 1440, phone ? 812 : 900);
    await signIn(page, email);
    await page.goto('/admin/live-map', { waitUntil: 'networkidle' });
    await expect(page.getByRole('heading', { level: 1, name: 'Live map' })).toBeVisible();
    await expect(page.getByTestId('admin-nav').getByRole('link', { name: 'Live map' })).toHaveCount(1);
    await expect(page.getByTestId('lm-kpis')).toContainText('On the site now');
    // the legend counts each kind
    const legend = page.getByTestId('lm-legend');
    await expect(legend.getByRole('button')).toHaveCount(8);
    expect(Number(await page.getByTestId('lm-count-draft').innerText())).toBeGreaterThanOrEqual(1);
    expect(Number(await page.getByTestId('lm-count-game').innerText())).toBeGreaterThanOrEqual(1);
    // the simplified map (the library is blocked here) draws the pins
    await expect(page.getByTestId('lm-map')).toHaveAttribute('data-mode', 'schematic', { timeout: 30_000 });
    await expect(page.locator('.lm-pin--draft')).not.toHaveCount(0);
    await expect(page.locator('.lm-pin--game')).not.toHaveCount(0);
    // cards: masked until Show details
    const erin = page.getByTestId('lm-card').filter({ hasText: `Erin E.` }).first();
    await expect(erin).toBeVisible();
    await expect(erin).toContainText('ending 0142');
    await expect(erin).not.toContainText('@example.test');
    await expect(erin).toContainText(/\+15 Form started/);
    await expect(page.getByTestId('lm-card').filter({ hasText: 'Visitor in Mississauga' }).first()).toBeVisible();
    // a pin's card on hover
    await page.locator('.lm-pin--draft').first().focus();
    await expect(page.getByTestId('lm-popup')).toBeVisible();
    // hiding a kind removes its pins
    await legend.locator('[data-type="game"]').click();
    await expect(page.locator('.lm-pin--game')).toHaveCount(0);
    await legend.locator('[data-type="game"]').click();
    await page.getByTestId('lm-details').check();
    await expect(page.getByTestId('lm-card').filter({ hasText: `Erin Example${t}` }).first()).toContainText(`lm.erin.${t}@example.test`);
    await noOverflow(page);
    const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).exclude('.lm-map').analyze();
    expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
    const text = await page.locator('body').innerText();
    expect(text.match(/[–—]/)?.[0], 'long dash').toBeUndefined();
    await page.context().close();

    if (phone) return;
    // TV mode: 1920x1080 and 3840x2160, no scrollbars, no admin menu, the spotlight, details masked
    for (const [w, h] of [[1920, 1080], [3840, 2160]] as const) {
      const tv = await ctx(browser, w, h);
      await signIn(tv, email);
      await tv.goto('/admin/live-map?tv=1', { waitUntil: 'networkidle' });
      await expect(tv.getByTestId('live-map-tv')).toBeVisible();
      await expect(tv.getByTestId('lm-map')).toHaveAttribute('data-mode', /schematic|map/, { timeout: 30_000 });
      await expect(tv.getByTestId('lm-spotlight')).toBeVisible();
      await expect(tv.locator('.ad__rail')).toBeHidden();
      await expect(tv.locator('.lm-pin')).not.toHaveCount(0);
      await expect(tv.getByTestId('live-map-tv')).not.toContainText('@example.test');
      await noOverflow(tv);
      // no scrollbars: the page cannot scroll and none takes room (the admin frame behind is clipped)
      const m = await tv.evaluate(() => ({ cw: document.documentElement.clientWidth, ch: document.documentElement.clientHeight, iw: window.innerWidth, ih: window.innerHeight,
        sw: document.documentElement.scrollWidth, html: getComputedStyle(document.documentElement).overflow, body: getComputedStyle(document.body).overflow }));
      expect([m.cw, m.ch, m.html, m.body], 'no scrollbars').toEqual([m.iw, m.ih, 'hidden', 'hidden']);
      expect(m.sw, 'no horizontal scroll').toBeLessThanOrEqual(m.iw);
      const box = await tv.getByTestId('live-map-tv').boundingBox();
      expect(Math.round(box!.width)).toBe(w);
      expect(Math.round(box!.height)).toBe(h);
      await tv.context().close();
    }
  } finally {
    await sql`delete from game_plays where visitor_id = any(${vids})`;
    await sql`delete from contact_captures where visitor_id = any(${vids})`;
    await sql`delete from visitor_sessions where visitor_id = any(${vids})`;
    await sql`delete from user_roles where user_id = ${admin}`.catch(() => undefined);
    await sql.end();
  }
});
