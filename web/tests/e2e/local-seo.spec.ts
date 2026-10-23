import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0095 end to end (phone 375 and desktop 1440): the home page's search targeting and its business node, the
// new intent landing pages, the place pages of every family (near, far, outside Canada), the service pages with their
// requests (a lead and a task in Today), the place data page and the sitemaps of the place pages. Every page: renders,
// JSON-LD that parses, axe, no horizontal overflow, the copy rules. Uses the test places of the local stack
// (scripts/places/fixtures).
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b/, 'brand misspelled'], [/18122211|Canada Inc/i, 'numbered company']];

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
const robots = async (page: Page) => ((await page.locator('meta[name="robots"]').count()) ? page.locator('meta[name="robots"]').first().getAttribute('content') : null);

test('home: "Car Rental Toronto" title, the h1 and first paragraph, one name, address and phone in the schema, footer and contact page', async ({ page }) => {
  await page.goto('/', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await expect(page).toHaveTitle(/^Car Rental Toronto \| Delivered or Pickup, No Deposit Surprises/);
  await expect(page.locator('h1')).toHaveText('Car rental in Toronto');
  await expect(page.locator('.hero .lead')).toContainText('car rental in Toronto');
  await expect(page.locator('.hero .d-hero')).toContainText('What goes around');
  const biz = (await ld(page)).find((n) => types([n]).includes('AutoRental')) as { address: { streetAddress: string; postalCode?: string }; telephone: string; openingHoursSpecification: unknown[]; areaServed: unknown[]; priceRange: string; aggregateRating?: unknown };
  expect(biz.address.streetAddress).toBe('1570 Midland Ave');
  expect(biz.telephone).toBe('+12893125991');
  expect(biz.openingHoursSpecification.length).toBeGreaterThan(0);
  expect(biz.areaServed.length).toBeGreaterThan(3);
  expect(biz.aggregateRating, 'no rating while there are fewer published reviews than the threshold').toBeUndefined();
  await expect(page.getByTestId('footer-address')).toContainText('1570 Midland Ave');
  // no link section on the home page (owner, October 22): the footer's quiet Browse links lead to the place pages
  await expect(page.locator('#h-ways')).toHaveCount(0);
  await expect(page.getByRole('navigation', { name: 'Browse' })).toBeVisible();
  await expect(page.locator('a[href="/car-rental/gta"]').first()).toBeVisible();
  await check(page, 'home');
  await page.goto('/contact', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('nap-address')).toContainText('1570 Midland Ave');
  await expect(page.locator('a[href="tel:+12893125991"]').first()).toBeVisible();
});

test('intent landing pages: render with their facts, FAQPage, breadcrumbs; the flagged-car pages stay out of search without their cars', async ({ page }) => {
  test.setTimeout(300_000);
  // the flagged-car pages (vehicles.no_credit_card and insurance_included of 0093) are in search only with enough such real cars
  const sql = db();
  const ix = Object.fromEntries((await sql<{ slug: string; ix: boolean; n: number }[]>`select slug, app.seo_page_indexable(p) ix, app.seo_real_count(p.match) n from seo_pages p where slug in ('no-credit-card', 'insurance-included')`).map((r) => [r.slug, r]));
  for (const slug of ['airport', 'under-25', 'young-drivers', 'monthly', 'weekend', 'car-delivery', 'luxury', 'exotic', 'economy', 'suv', 'minivan', 'convertible', 'no-credit-card', 'insurance-included', 'toronto']) {
    const res = await page.goto(`/car-rental/${slug}`, { waitUntil: 'networkidle' });
    expect(res?.status(), slug).toBe(200);
    await acceptCookies(page);
    await expect(page.locator('h1')).toHaveCount(1);
    const t = types(await ld(page));
    expect(t, slug).toContain('BreadcrumbList');
    expect(t, slug).toContain('FAQPage');
    if (slug === 'toronto') {
      const biz = (await ld(page)).find((n) => types([n]).includes('AutoRental')) as { areaServed: unknown[] };
      expect(biz.areaServed.length, 'Toronto serves every city landing page').toBeGreaterThan(3);
    }
    if (slug === 'no-credit-card' || slug === 'insurance-included') {
      const r = ix[slug]!;
      if (r.ix) {
        expect(await robots(page) ?? '', slug).not.toContain('noindex');
        expect(await page.locator('main a[href^="/cars/"]').count(), `${slug}: its ${r.n} cars are listed`).toBeGreaterThan(0);
      } else expect(await robots(page), slug).toContain('noindex');
    }
    await check(page, slug);
  }
});

test('place pages: a neighbourhood near us, a far city, a US city, the GTA; honest distance and delivery, never a branch', async ({ page }) => {
  test.setTimeout(180_000);
  await page.goto('/car-rental/port-credit-mississauga-on', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await expect(page.locator('h1')).toHaveText('Car Rental in Port Credit, Mississauga');
  await expect(page.locator('body')).toContainText('No. CarmaCars has one location, in Toronto, and we deliver to Port Credit, Mississauga.');
  expect(types(await ld(page))).toEqual(expect.arrayContaining(['BreadcrumbList', 'FAQPage']));
  await expect(page.getByTestId('place-attribution')).toContainText('GeoNames');
  await check(page, 'port credit');

  await page.goto('/car-rental/kingston-on', { waitUntil: 'networkidle' });
  await expect(page.locator('body')).toContainText('rents cars in the Toronto area');
  await expect(page.locator('body')).toContainText('has no location in Kingston');
  await expect(page.getByTestId('place-lead-form')).toBeVisible();
  await check(page, 'kingston');

  await page.goto('/car-rental/suv-rental/buffalo-ny', { waitUntil: 'networkidle' });
  await expect(page.locator('h1')).toHaveText('SUV Rental in Buffalo, NY');
  await expect(page.locator('#cars')).toContainText('Canadian dollars');
  await check(page, 'buffalo');

  await page.goto('/car-rental/gta', { waitUntil: 'networkidle' });
  await expect(page.locator('h1')).toHaveText('Car Rental in Greater Toronto Area');
  await check(page, 'gta');

  // the base term has one address; a place nobody loaded is a 404
  const r = await page.goto('/car-rental/car-rental/kingston-on');
  expect(new URL(page.url()).pathname).toBe('/car-rental/kingston-on');
  expect(r?.status()).toBe(200);
  expect((await page.goto('/car-rental/suv-rental/nowhere-xx'))?.status()).toBe(404);
});

test('buying help: never a seller, lender or lessor; the notice, the rental offer and a buyer lead', async ({ page }) => {
  test.setTimeout(120_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  await page.goto('/buy/car-financing/mississauga', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await expect(page.getByTestId('sale-disclaimer')).toContainText('we are not a lender, a dealer or a leasing company');
  await expect(page.locator('body')).toContainText('Rent it before you buy it.');
  await check(page, 'financing');
  const email = `buyer.${Date.now()}@example.test`;
  await page.locator('[data-testid="place-lead-form"] input[name="name"]').fill('Pat Buyer');
  await page.locator('[data-testid="place-lead-form"] input[name="email"]').fill(email);
  await page.locator('[data-testid="place-lead-form"] input[name="vehicle"]').fill('2021 Honda Civic');
  await page.locator('[data-testid="place-lead-form"] button[type="submit"]').click();
  await expect(page.getByTestId('place-lead-sent')).toBeVisible();
  const [lead] = await sql`select l.kind, l.payload ->> 'term' as term, (select t.task_type from tasks t where t.related_id = l.id) as task from leads l where l.email = ${email}`;
  expect(lead).toMatchObject({ kind: 'finance', term: 'car-financing', task: 'finance_lead' });
  await sql.end();
});

test('detailing and body shop: service pages, a request becomes a lead with a task for today, rentals offered first', async ({ page }) => {
  test.setTimeout(180_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  await page.goto('/detailing', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await expect(page.locator('h1')).toHaveText('Car detailing in Toronto');
  await expect(page.locator('body')).toContainText('Price on request');
  await expect(page.locator('body')).toContainText('Need a car while yours is detailed? Rent one, delivered.');
  expect(types(await ld(page))).toContain('ItemList');
  await check(page, 'detailing');

  await page.goto('/body-shop', { waitUntil: 'networkidle' });
  await expect(page.locator('body')).toContainText('Your car is in the shop? Get an insurance replacement rental, delivered.');
  await check(page, 'body shop');
  const email = `body.${Date.now()}@example.test`;
  const f = page.getByTestId('place-lead-form');
  await f.locator('input[name="name"]').fill('Jo Dent');
  await f.locator('input[name="email"]').fill(email);
  await f.locator('input[name="vehicle"]').fill('2019 Toyota Corolla');
  await f.locator('input[name="damage"]').fill('Rear bumper cracked');
  await f.getByLabel('Yes').check();
  await f.locator('button[type="submit"]').click();
  await expect(page.getByTestId('place-lead-sent')).toBeVisible();
  const [lead] = await sql`select l.kind, l.payload ->> 'insurance_claim' as claim, t.task_type, t.status from leads l join tasks t on t.related_id = l.id where l.email = ${email}`;
  expect(lead).toMatchObject({ kind: 'bodyshop', claim: 'yes', task_type: 'bodyshop_request', status: 'open' });
  await sql.end();

  for (const p of ['/detailing/ceramic-coating/toronto', '/body-shop/collision-repair/oakville', '/place-data']) {
    expect((await page.goto(p, { waitUntil: 'networkidle' }))?.status(), p).toBe(200);
    await check(page, p);
  }
});

test('sitemaps: the index lists the place files; a file lists place pages by address; no page is rendered for it', async ({ request }) => {
  const idx = await (await request.get('/sitemap.xml')).text();
  const files = [...idx.matchAll(/<loc>([^<]*sitemap-places[^<]*)<\/loc>/g)].map((m) => new URL(m[1]!).pathname);
  expect(files.length).toBeGreaterThan(50);
  expect(files).toContain('/sitemap-places-rental.suv-rental.1.xml');
  expect(files).toContain('/sitemap-places-bodyshop.collision-repair.1.xml');
  const one = await (await request.get('/sitemap-places-rental.suv-rental.1.xml')).text();
  expect(one).toContain('/car-rental/suv-rental/port-credit-mississauga-on');
  expect(one).not.toContain('/car-rental/suv-rental/cn-tower');
  expect((await request.get('/sitemap-places-rental.nope.1.xml')).status()).toBe(200);
  expect((await request.get('/sitemap-places-bad.xml')).status()).toBe(404);
  const pages = await (await request.get('/sitemap-pages.xml')).text();
  for (const p of ['/detailing', '/body-shop', '/place-data']) expect(pages).toContain(p);
});
