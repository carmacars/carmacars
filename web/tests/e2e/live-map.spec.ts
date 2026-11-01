import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';
// The Live map (migration 0242) end to end: an Admin opens Today > Live map and sees the four numbers, the legend of the
// four stages with its counts, a dot per lead on the map and a row per lead (masked until Show details); TV mode fills
// 1920x1080 and 3840x2160 with no scrollbars and no admin menu, with the spotlight and the live feed. The map, its basemap
// and its font are the site's own files (no third-party network); WebGL comes from the browser's software renderer.
// simplified map (the same pins); the test never depends on a third-party network. Fixtures are example.test only.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
// MapLibre needs WebGL: the headless browser's software renderer
test.use({ launchOptions: { args: ['--no-proxy-server', '--force-prefers-reduced-motion', '--enable-unsafe-swiftshader', '--use-angle=swiftshader', '--ignore-gpu-blocklist'] } });

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
  return c.newPage();
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
    // the menu is folded on a phone: open it as a phone user does
    if (phone) await page.getByTestId('admin-nav').getByRole('button', { name: /^Menu\. You are on/ }).click();
    await expect(page.getByTestId('admin-nav').getByRole('link', { name: 'Live map' })).toHaveCount(1);
    if (phone) await page.getByTestId('admin-nav').getByRole('button', { name: /^Menu\. You are on/ }).click();
    await expect(page.getByTestId('lm-kpis')).toContainText('On site now');
    // the legend counts each stage
    const legend = page.getByTestId('lm-legend');
    await expect(legend.getByRole('button')).toHaveCount(4);
    expect(Number(await page.getByTestId('lm-count-progress').innerText())).toBeGreaterThanOrEqual(1);
    expect(Number(await page.getByTestId('lm-count-site').innerText())).toBeGreaterThanOrEqual(2);
    // the map draws the dots on the site's own basemap
    const map = page.getByTestId('lm-map');
    await expect(map).toHaveAttribute('data-mode', 'map', { timeout: 60_000 });
    await expect.poll(async () => Number(await map.getAttribute('data-pins'))).toBeGreaterThanOrEqual(3);
    // the table: masked until Show details; a row opens its signals
    const erin = page.getByTestId('lm-card').filter({ hasText: 'Erin E.' }).first();
    await expect(erin).toBeVisible();
    await expect(page.getByTestId('lm-card').filter({ hasText: 'Visitor in Mississauga' }).first()).toBeVisible();
    await erin.getByRole('button', { name: 'Erin E.' }).click();
    const more = page.locator('.lm-more').first();
    await expect(more).toContainText('ending 0142');
    await expect(more).toContainText(/\+15 Form started/);
    await expect(more).not.toContainText('@example.test');
    // hiding a stage takes its dots off the map and its rows out of the table
    const before = Number(await map.getAttribute('data-pins'));
    await legend.locator('[data-stage="site"]').click();
    await expect.poll(async () => Number(await map.getAttribute('data-pins'))).toBeLessThan(before);
    await expect(page.getByTestId('lm-card').filter({ hasText: 'Visitor in Mississauga' })).toHaveCount(0);
    await legend.locator('[data-stage="site"]').click();
    await page.getByTestId('lm-details').check();
    await expect(page.getByTestId('lm-card').filter({ hasText: `Erin Example${t}` }).first()).toBeVisible();
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
      await expect(tv.getByTestId('lm-map')).toHaveAttribute('data-mode', 'map', { timeout: 90_000 });
      await expect(tv.getByTestId('lm-spotlight')).toBeVisible();
      await expect(tv.locator('.ad__rail')).toBeHidden();
      await expect.poll(async () => Number(await tv.getByTestId('lm-map').getAttribute('data-pins'))).toBeGreaterThanOrEqual(3);
      const rows = await tv.getByTestId('lm-feed-row').count();
      expect(rows, 'the live feed: one line per event, at most 6').toBeGreaterThanOrEqual(1);
      expect(rows).toBeLessThanOrEqual(6);
      await expect(tv.getByTestId('lm-kpis').locator('li')).toHaveCount(4);
      await expect(tv.getByTestId('lm-film')).toBeVisible();
      // nothing personal beyond a first name and initial on the wall
      await expect(tv.getByTestId('live-map-tv')).not.toContainText('@example.test');
      await expect(tv.getByTestId('live-map-tv')).not.toContainText('0142');
      await noOverflow(tv);
      // Release 26: the view fits the pins inside the room the header and filmstrip leave, never closer than a city, and
      // no photo pin covers another or sits under the header or the filmstrip
      await expect.poll(async () => tv.getByTestId('lm-map').getAttribute('data-zoom'), { timeout: 30_000 }).not.toBeNull();
      expect(Number(await tv.getByTestId('lm-map').getAttribute('data-zoom'))).toBeLessThanOrEqual(9.6 + Math.log2(h / 1080) + 0.05);
      const layout = await tv.evaluate(() => {
        const ph = [...document.querySelectorAll('.lm-ph')].map((e) => e.getBoundingClientRect());
        const top = document.querySelector('[data-testid="lm-kpis"]')!.getBoundingClientRect().bottom, foot = document.querySelector('.lm-film')!.getBoundingClientRect().top;
        let overlaps = 0;
        for (let i = 0; i < ph.length; i++) for (let j = i + 1; j < ph.length; j++) { const a = ph[i]!, c = ph[j]!; if (a.left < c.right - 1 && c.left < a.right - 1 && a.top < c.bottom - 1 && c.top < a.bottom - 1) overlaps++; }
        return { overlaps, under: ph.filter((r) => r.top < top || r.bottom > foot).length };
      });
      expect(layout, 'photo pins clear of each other and of the header and filmstrip').toEqual({ overlaps: 0, under: 0 });
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
    // Release 25: the GTA's highways come from the site itself; a booking with no car shows "Car not assigned", never "Car ?"
    const tv = await ctx(browser, 1920, 1080);
    const hwy = tv.waitForResponse((r) => r.url().endsWith('/live-map/highways.geojson'), { timeout: 90_000 });
    const regions = tv.waitForResponse((r) => r.url().endsWith('/live-map/regions.geojson'), { timeout: 90_000 });
    await signIn(tv, email);
    await tv.goto('/admin/live-map?tv=1', { waitUntil: 'networkidle' });
    expect((await hwy).status()).toBe(200);
    // Release 26: the regions, the glow and the ridges come from the site itself too
    expect((await regions).status()).toBe(200);
    await expect(tv.getByTestId('lm-map')).toHaveAttribute('data-mode', 'map', { timeout: 90_000 });
    await expect(tv.getByTestId('lm-map')).toHaveAttribute('data-blockers', /^\d+$/);
    await tv.route('**/api/staff/live-map*', async (route) => {
      const r = await route.fetch();
      const j = await r.json() as { pins: Array<Record<string, unknown>> };
      j.pins.unshift({ ...(j.pins[0] ?? {}), id: 'lm-no-car', type: 'on_rent', types: ['on_rent'], at: new Date().toISOString(), who: 'Una U.', name: 'Una Unassigned',
        booking_number: 'CC-00000', return_at: new Date(Date.now() + 86_400_000).toISOString(), pickup_at: new Date().toISOString(), car: null, lat: 43.7, lng: -79.4, signals: [] });
      await route.fulfill({ response: r, json: j });
    });
    await tv.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
    const film = tv.getByTestId('lm-film-card').filter({ hasText: 'Una U.' });
    await expect(film).toContainText('Car not assigned');
    await expect(film.locator('.lm-shape svg')).toBeVisible();
    await expect(tv.getByTestId('lm-film')).not.toContainText('Car ?');
    await noOverflow(tv);
    await tv.context().close();
  } finally {
    await sql`delete from game_plays where visitor_id = any(${vids})`;
    await sql`delete from contact_captures where visitor_id = any(${vids})`;
    await sql`delete from visitor_sessions where visitor_id = any(${vids})`;
    await sql`delete from user_roles where user_id = ${admin}`.catch(() => undefined);
    await sql.end();
  }
});
