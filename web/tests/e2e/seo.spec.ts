import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, aiAllowanceLock, carByHand, db, noOverflow } from './helpers';

// Migration 0061 end to end (phone 375 and desktop 1440): a car added in Admin gets its page copy written by itself
// (the plain copy at once, the written copy from the model, nobody types), an edited field is locked and kept; landing
// pages render their live cars with valid structured data (location pages indexable, use pages noindex under the
// threshold); the guides with their Article; the sitemap index, robots and the IndexNow key file; Admin > Settings >
// Search and the business listings checklist. Every page: axe, overflow, the copy rules.
const SHOTS = 'test-results/seo';
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b/, 'brand misspelled'], [/18122211|Canada Inc/i, 'numbered company']];
type Sql = ReturnType<typeof db>;
mkdirSync(SHOTS, { recursive: true });

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
async function ld(page: Page): Promise<Array<Record<string, unknown>>> {
  const blocks = await page.locator('script[type="application/ld+json"]').allTextContents();
  return blocks.flatMap((b) => { const j = JSON.parse(b) as { '@graph'?: Array<Record<string, unknown>> }; return j['@graph'] ?? [j as Record<string, unknown>]; });
}
const types = (nodes: Array<Record<string, unknown>>) => nodes.flatMap((n) => ([] as unknown[]).concat(n['@type'] ?? []).map(String));
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone');
const vin = () => `3SEAU4EE${randomBytes(5).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');

async function mkAdmin(sql: Sql) {
  const id = randomUUID(); const email = `admin.seo.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${'Sam Search ' + tag()})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  const p = await c.newPage();
  p.on('dialog', (d) => void d.accept());
  return p;
}

test.describe.configure({ mode: 'serial' });

// the AI allowance lock (helpers.ts) of a car copy test, let go when it ends, passed or not
let unlockAi: (() => Promise<void>) | undefined;
test.afterEach(async () => { await unlockAi?.(); unlockAi = undefined; });

test('car copy: a car added in Admin gets its page copy by itself, nothing typed; an edited field is locked and kept', async ({ browser }) => {
  test.setTimeout(400_000);
  unlockAi = await aiAllowanceLock('shared');   // the AI copy: not while the usage guard tests use the allowance up
  const sql = db();
  await sql`update program_settings set seo_ai_writer_enabled = true`;   // 0133: the site's own copy writer is off by default (the daily Claude batch writes); this test checks the writer
  const admin = await mkAdmin(sql);
  const page = await ctx(browser);
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(admin.email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });

  // Add a car: the year, make and model, the plate and the rates. No copy field anywhere.
  await page.goto('/admin/vehicles/new', { waitUntil: 'networkidle' });
  await page.getByTestId('add-car-supply-company').check();
  await page.getByTestId('add-car-vin').fill(vin());
  await page.getByTestId('add-car-plate').fill(`SEO${randomBytes(2).toString('hex').toUpperCase()}`);
  await carByHand(page, 'add-car', { year: '2022', make: 'Mazda', model: `CX-${tag()}` });
  await page.getByTestId('add-car-daily').fill('83');
  await page.getByTestId('add-car-deposit').fill('300');
  await page.getByTestId('add-car-submit').click();
  await page.waitForURL(/\/admin\/vehicles\/[0-9a-f-]{36}\?added=1/, { timeout: 30_000 });
  const vid = page.url().match(/vehicles\/([0-9a-f-]{36})/)![1]!;
  // what a VIN decode or the listing review confirms (the facts the copy is written from)
  await sql`update vehicles set colour = 'Soul Red', body_type = 'SUV' where id = ${vid}`;
  await sql`update vehicle_listings set seats = 5, transmission = 'Automatic', body_style = 'SUV', drivetrain = 'All-wheel drive', home_area = 'North York' where vehicle_id = ${vid}`;

  // the listing tab shows the copy, written by itself: the plain copy first, then Write again runs the job now
  await page.goto(`/admin/vehicles/${vid}?tab=listing`, { waitUntil: 'networkidle' });
  const panel = page.getByTestId('car-copy');
  await expect(panel).toBeVisible();
  await expect(panel.locator('textarea')).toHaveCount(0);
  await page.getByTestId('cc-regenerate').click();
  await expect(panel.locator('.alert--ok')).toBeVisible({ timeout: 20_000 });
  let row: { status: string; source: string } | undefined;
  for (let i = 0; i < 40; i++) {
    [row] = await sql<{ status: string; source: string }[]>`select status, source from car_copy where vehicle_id = ${vid}`;
    if (row?.status === 'published' && row.source === 'ai') break;
    await page.waitForTimeout(500);
  }
  expect(`${row?.status}/${row?.source}`).toBe('published/ai');
  await page.reload({ waitUntil: 'networkidle' });
  await expect(page.getByTestId('car-copy-status')).toHaveAttribute('data-source', 'ai');
  await expect(page.getByTestId('cc-h1')).toContainText('Mazda');
  await check(page, 'car copy panel');
  await page.screenshot({ path: `${SHOTS}/car-copy-${test.info().project.name}.png`, fullPage: true });

  // a person changes the heading: it is locked, and the next version keeps it
  await page.getByTestId('cc-h1').getByRole('button', { name: 'Change' }).click();
  await page.locator('#cc-in-h1').fill('Our red Mazda in North York, ready to go');
  await page.getByTestId('cc-save-h1').click();
  await expect(page.getByTestId('cc-h1')).toHaveAttribute('data-locked', 'yes', { timeout: 20_000 });
  await sql`update car_copy set status = 'pending', next_attempt_at = now() where vehicle_id = ${vid}`;
  await page.getByTestId('cc-regenerate').click();
  for (let i = 0; i < 40; i++) {
    const [r] = await sql<{ status: string }[]>`select status from car_copy where vehicle_id = ${vid}`;
    if (r?.status === 'published') break;
    await page.waitForTimeout(500);
  }
  const [cc] = await sql<{ h1: string; locked: string[]; headline: string }[]>`select cc.copy ->> 'h1' h1, cc.locked, l.headline from car_copy cc join vehicle_listings l on l.vehicle_id = cc.vehicle_id where cc.vehicle_id = ${vid}`;
  expect(cc!.h1).toBe('Our red Mazda in North York, ready to go');
  expect(cc!.headline).toBe('Our red Mazda in North York, ready to go');
  expect(cc!.locked).toEqual(['h1']);
  await sql.end();
});

test('landing pages: live cars, prices and valid structured data; use pages noindex under the threshold', async ({ browser }) => {
  test.setTimeout(120_000);
  const page = await ctx(browser);
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto('/car-rental/toronto', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await expect(page.locator('h1')).toHaveText('Car rental in Toronto');
  const cards = page.locator('#cars .car-card');
  expect(await cards.count()).toBeGreaterThan(0);
  await expect(page.locator('.facts')).toContainText('a day');
  await expect(page.locator('link[rel="canonical"]')).toHaveAttribute('href', /\/car-rental\/toronto$/);
  await expect(page.locator('meta[name="robots"]')).toHaveCount(0);
  const nodes = await ld(page);
  for (const t of ['BreadcrumbList', 'FAQPage', 'ItemList', 'AutoRental', 'WebSite']) expect(types(nodes), t).toContain(t);
  const biz = nodes.find((n) => types([n]).includes('AutoRental'))!;
  expect(JSON.stringify(biz)).not.toMatch(/aggregateRating/);
  expect((biz.address as Record<string, string>).postalCode).toBeTruthy();
  const list = nodes.find((n) => types([n]).includes('ItemList'))!;
  expect((list.itemListElement as unknown[]).length).toBeGreaterThan(0);
  await check(page, 'landing toronto');
  await page.screenshot({ path: `${SHOTS}/landing-toronto-${test.info().project.name}.png`, fullPage: true });

  // a use page follows the database's rule: with fewer real matching cars than the setting it is shown but noindex (and
  // out of the sitemap); other specs publish real cars (new cars are published automatically, 0070), so read the rule
  const sql = db();
  const [ix] = await sql`select app.seo_page_indexable(p) i from seo_pages p where p.slug = 'monthly'`;
  await sql.end();
  await page.goto('/car-rental/monthly', { waitUntil: 'networkidle' });
  if (ix!.i) await expect(page.locator('meta[name="robots"]')).toHaveCount(0);
  else await expect(page.locator('meta[name="robots"]')).toHaveAttribute('content', /noindex/);
  await check(page, 'landing monthly');
  await page.goto('/car-rental', { waitUntil: 'networkidle' });
  await expect(page.locator('h1')).toHaveText('Car rental in Toronto and the GTA');
  await expect(page.locator('a[href="/car-rental/mississauga"]').first()).toBeVisible();
  await check(page, 'car rental hub');

  // the guides
  await page.goto('/guides', { waitUntil: 'networkidle' });
  expect(await page.locator('.art-list a').count()).toBeGreaterThanOrEqual(8);
  await check(page, 'guides');
  await page.goto('/guides/407-etr-tolls-in-a-rental-car', { waitUntil: 'networkidle' });
  await expect(page.locator('h1')).toContainText('407 ETR');
  await expect(page.locator('article.art__body')).not.toContainText('{{');
  const art = (await ld(page)).find((n) => types([n]).includes('Article'))!;
  for (const k of ['headline', 'datePublished', 'dateModified', 'author', 'publisher', 'image']) expect(art[k], k).toBeTruthy();
  await check(page, 'guide');
  await page.screenshot({ path: `${SHOTS}/guide-${test.info().project.name}.png`, fullPage: true });

  // the footer links the location pages from every page
  await page.goto('/', { waitUntil: 'networkidle' });
  await expect(page.locator('footer a[href="/car-rental/scarborough"]')).toHaveCount(1);
  expect(errors).toEqual([]);
});

test('search engines: sitemap index and parts, robots, the IndexNow key file, verification', async ({ request }) => {
  const sql = db();
  const idx = await (await request.get('/sitemap.xml')).text();
  expect(idx).toContain('<sitemapindex');
  for (const part of ['pages', 'cars', 'landing', 'guides']) expect(idx).toContain(`/sitemap-${part}.xml`);
  const landing = await (await request.get('/sitemap-landing.xml')).text();
  expect(landing).toContain('/car-rental/toronto</loc>');
  // a use page is in the sitemap only when the database's rule makes it indexable (other specs publish real cars)
  const [mi] = await sql`select app.seo_page_indexable(p) i from seo_pages p where p.slug = 'monthly'`;
  if (mi!.i) expect(landing).toContain('/car-rental/monthly</loc>'); else expect(landing).not.toContain('/car-rental/monthly</loc>');
  expect(landing).toMatch(/<lastmod>\d{4}-\d{2}-\d{2}T/);
  const guides = await (await request.get('/sitemap-guides.xml')).text();
  expect(guides).toContain('/guides/winter-driving-in-ontario-in-a-rental-car</loc>');
  const robots = await (await request.get('/robots.txt')).text();
  expect(robots).toMatch(/Sitemap: \S+\/sitemap\.xml/);
  const k = (await sql<{ k: string }[]>`select indexnow_key k from site_settings`)[0]!.k;
  const key = await request.get(`/${k}.txt`);
  expect(key.status()).toBe(200);
  expect((await key.text()).trim()).toBe(k);
  expect((await request.get('/0123456789abcdef0123456789abcdef.txt')).status()).toBe(404);
  // a Google verification value set in Admin > Settings > Site reaches the head (after the hourly rebuild; the
  // layout reads settings when the page is built, so a fresh page here)
  await sql`update site_settings set google_site_verification = 'e2e_token_abcdefgh', google_verification_file = 'google0e2eabcd12.html'`;
  const file = await request.get('/google0e2eabcd12.html');
  expect(file.status()).toBe(200);
  expect(await file.text()).toBe('google-site-verification: google0e2eabcd12.html');
  await sql`update site_settings set google_site_verification = null, google_verification_file = null`;
  await sql.end();
});

test('admin: Settings > Search lists the car copy, landing pages and guides; Site has the business listings', async ({ browser }) => {
  test.setTimeout(120_000);
  const sql = db();
  const admin = await mkAdmin(sql);
  const page = await ctx(browser);
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(admin.email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
  await page.goto('/admin/settings/search', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('seo-pages')).toContainText('Mississauga');
  await expect(page.getByTestId('seo-articles')).toContainText('407 ETR');
  await expect(page.getByTestId('seo-today')).toContainText('neurons');
  await check(page, 'settings search');
  await page.goto('/admin/settings/site', { waitUntil: 'networkidle' });
  const bl = page.getByTestId('business-listings');
  // one name, address and phone (0095): the business address is the street address the site shows
  await expect(bl).toContainText('1570 Midland Ave');
  await bl.getByTestId('listing-bing').getByRole('checkbox').check();
  await expect(bl.locator('.alert--ok')).toContainText('Bing Places', { timeout: 20_000 });
  const done = (await sql<{ done: boolean }[]>`select (business_listings -> 'bing' ->> 'done')::boolean done from site_settings`)[0]?.done;
  expect(done).toBe(true);
  await sql`update site_settings set business_listings = business_listings - 'bing'`;
  await check(page, 'settings site');
  await sql.end();
});
