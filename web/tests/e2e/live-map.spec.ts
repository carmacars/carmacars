import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';
// The Live map (migration 0242) end to end, on Today > Visitors (Release 26: Live visitors, Visitor history and the
// Live map in one page): the four numbers, the legend of the four stages with its counts, a dot per lead, Live now under
// it with phones and emails only behind Show contact, a row finding its lead on the map, hover and click cards; TV mode fills
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

test('Visitors: the map, Live now and Show contact on the page; the old addresses land there; TV mode fills the screen at 1080p and 4K', async ({ browser }, info) => {
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
    // Release 26: Live visitors, Visitor history and the Live map are one page, Visitors; the old addresses land on it
    await page.goto('/admin/live-map', { waitUntil: 'networkidle' });
    await expect(page).toHaveURL(/\/admin\/visitors$/);
    await page.goto('/admin/live', { waitUntil: 'networkidle' });
    await expect(page).toHaveURL(/\/admin\/visitors$/);
    await page.goto('/admin/live/history?city=Toronto', { waitUntil: 'networkidle' });
    await expect(page).toHaveURL(/\/admin\/visitors\?view=history&city=Toronto/);
    await expect(page.getByTestId('vs-tab-history')).toHaveAttribute('aria-current', 'page');
    await page.goto('/admin/visitors', { waitUntil: 'networkidle' });
    await expect(page.getByRole('heading', { level: 1, name: 'Visitors' })).toBeVisible();
    await expect(page.getByTestId('vs-tab-live')).toHaveAttribute('aria-current', 'page');
    // one menu entry: Visitors (the menu is folded on a phone: open it as a phone user does)
    if (phone) await page.getByTestId('admin-nav').getByRole('button', { name: /^Menu\. You are on/ }).click();
    const nav = page.getByTestId('admin-nav');
    await expect(nav.getByRole('link', { name: 'Visitors', exact: true })).toHaveCount(1);
    for (const old of ['Live map', 'Live visitors', 'Visitor history']) await expect(nav.getByRole('link', { name: old, exact: true })).toHaveCount(0);
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
    // Live now: the visitors on the site, with what they typed; phones and emails only with Show contact
    const erinEmail = `lm.erin.${t}@example.test`;
    const erinRow = page.getByTestId('live-row').filter({ hasText: `Erin Example${t}` }).first();
    await expect(erinRow).toBeVisible();
    await expect(erinRow).not.toContainText('4165550142');
    await expect(erinRow).not.toContainText('@example.test');
    // Show contact off (the default): no phone or email anywhere in the page's HTML or in what the page reads
    const sw = page.getByTestId('lm-contact');
    await expect(sw).toHaveAttribute('aria-checked', 'false');
    expect(await page.content()).not.toContain(erinEmail);
    expect(await page.content()).not.toContain('4165550142');
    for (const u of ['/api/staff/live-map', '/api/staff/live?what=live_visitors&contact=0']) {
      const body = await (await page.request.get(u)).text();
      expect(body, u).not.toContain(erinEmail);
      expect(body, u).not.toContain('4165550142');
    }
    // on: asked for from the server, shown in the list, and remembered on this device
    const asked = page.waitForResponse((r) => r.url().includes('/api/staff/live-map?contact=1'));
    const askedLive = page.waitForResponse((r) => r.url().includes('what=live_visitors') && r.url().includes('contact=1'));
    await sw.click();
    expect((await asked).status()).toBe(200);
    expect((await askedLive).status()).toBe(200);
    await expect(sw).toHaveAttribute('aria-checked', 'true');
    await expect(erinRow).toContainText('4165550142');
    await expect(erinRow).toContainText(erinEmail);
    expect(await page.evaluate(() => localStorage.getItem('carmacars.live-map.contact'))).toBe('1');
    // off again: gone at once, from the page and from its next read
    await sw.click();
    await expect(sw).toHaveAttribute('aria-checked', 'false');
    await expect(erinRow).not.toContainText('4165550142');
    expect(await page.getByTestId('visitors').innerHTML()).not.toContain(erinEmail);
    expect(await page.evaluate(() => localStorage.getItem('carmacars.live-map.contact'))).toBe('0');
    // hiding a stage takes its dots off the map
    const before = Number(await map.getAttribute('data-pins'));
    await legend.locator('[data-stage="site"]').click();
    await expect.poll(async () => Number(await map.getAttribute('data-pins'))).toBeLessThan(before);
    await legend.locator('[data-stage="site"]').click();
    await expect.poll(async () => Number(await map.getAttribute('data-pins'))).toBe(before);
    // a row finds its lead: "Show on the map" brings the Mississauga visitor to the map's middle and opens its card;
    // then a hover previews it, and a click on the dot pins it
    const mss = page.getByTestId('live-row').filter({ hasText: 'Mississauga' }).first();
    await mss.getByTestId('lv-locate').click();
    const card = page.getByTestId('lm-popup');
    await expect(card.getByTestId('lm-detail-name')).toHaveText('Visitor in Mississauga', { timeout: 15_000 });
    await expect(card.getByTestId('lm-detail-link')).toHaveAttribute('href', '/admin/visitors');
    await page.keyboard.press('Escape');
    await expect(card).toHaveCount(0);
    if (!phone) {
      const box = (await map.boundingBox())!;
      const mid = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
      await page.mouse.move(mid.x, mid.y + 120);
      await page.mouse.move(mid.x, mid.y, { steps: 4 });
      await expect(card).toHaveAttribute('data-pinned', '0');
      await expect(card.getByTestId('lm-detail-name')).toHaveText('Visitor in Mississauga');
      await page.mouse.move(mid.x, box.y + box.height - 10, { steps: 4 });
      await expect(card).toHaveCount(0);
      await page.mouse.click(mid.x, mid.y);
      await expect(card).toHaveAttribute('data-pinned', '1');
      await expect(card.getByTestId('lm-detail')).toContainText('On the site');
      await card.getByRole('button', { name: 'Close' }).click();
      await expect(card).toHaveCount(0);
    } else {
      // a tap (a click with no hover first) pins the card
      const b = (await map.boundingBox())!;
      await map.click({ position: { x: b.width / 2, y: b.height / 2 } });
      await expect(card).toHaveAttribute('data-pinned', '1');
    }
    await noOverflow(page);
    const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).exclude('.lm-map').analyze();
    expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
    const text = await page.locator('body').innerText();
    expect(text.match(/[–—]/)?.[0], 'long dash').toBeUndefined();
    await page.context().close();

    if (phone) return;
    // Release 26: with WebGL off (Chrome without hardware acceleration) the same map draws in Canvas 2D, with its note,
    // its pins clickable and no console error
    {
      const c = await browser.newContext({ viewport: { width: 1440, height: 900 }, baseURL: test.info().project.use.baseURL });
      await c.addInitScript(() => {
        const get = HTMLCanvasElement.prototype.getContext;
        HTMLCanvasElement.prototype.getContext = function (this: HTMLCanvasElement, t: string, ...a: unknown[]) {
          return /webgl/i.test(String(t)) ? null : (get as (...x: unknown[]) => unknown).call(this, t, ...a);
        } as typeof get;
      });
      const fb = await c.newPage();
      const errors: string[] = [];
      fb.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
      fb.on('pageerror', (e) => errors.push(String(e)));
      await signIn(fb, email);
      await fb.goto('/admin/visitors', { waitUntil: 'networkidle' });
      const m2 = fb.getByTestId('lm-map');
      await expect(m2).toHaveAttribute('data-mode', 'map', { timeout: 60_000 });
      await expect(m2).toHaveAttribute('data-renderer', 'canvas');
      await expect(fb.getByTestId('lm-slow')).toHaveText('Faster with hardware acceleration on (Chrome Settings > System)');
      await expect(fb.locator('.lm-map__note')).toHaveCount(0);
      await expect.poll(async () => Number(await m2.getAttribute('data-pins'))).toBeGreaterThanOrEqual(3);
      await fb.getByTestId('live-row').filter({ hasText: 'Mississauga' }).first().getByTestId('lv-locate').click();
      const pop = fb.getByTestId('lm-popup');
      await expect(pop.getByTestId('lm-detail-name')).toHaveText('Visitor in Mississauga', { timeout: 15_000 });
      await fb.keyboard.press('Escape');
      await expect(pop).toHaveCount(0);
      const b2 = (await m2.boundingBox())!;
      await fb.mouse.click(b2.x + b2.width / 2, b2.y + b2.height / 2);
      await expect(pop).toHaveAttribute('data-pinned', '1');
      await expect(pop.getByTestId('lm-detail-name')).toHaveText('Visitor in Mississauga');
      expect(errors, 'no console errors on the Canvas map').toEqual([]);
      await c.close();
    }
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
      // no phone or email on the wall while Show contact is off (the default on a new device)
      await expect(tv.getByTestId('live-map-tv')).not.toContainText('@example.test');
      await expect(tv.getByTestId('live-map-tv')).not.toContainText('0142');
      expect(await tv.content()).not.toContain('4165550142');
      // Release 26: a lead in the live feed opens its card on the wall, with its name
      await tv.getByTestId('lm-feed-row').first().getByRole('button').click();
      await expect(tv.getByTestId('lm-detail')).toBeVisible();
      await expect(tv.getByTestId('lm-detail-name')).not.toBeEmpty();
      await tv.keyboard.press('Escape');
      await expect(tv.getByTestId('lm-detail')).toHaveCount(0);
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
