import { expect, test, type APIRequestContext, type Page } from '@playwright/test';
import { noOverflow } from './helpers';

// Migration 0115 end to end (phone 375 and desktop 1440): a new term with its own page, a synonym served with its
// term's page as canonical and kept out of search (rental and /buy), the chauffeur terms taking a request, body repair
// that says it is not mechanical work. Uses the test places of the local stack (scripts/places/fixtures).
const canonical = (page: Page) => page.locator('link[rel="canonical"]').first().getAttribute('href');
const robots = async (page: Page) => ((await page.locator('meta[name="robots"]').count()) ? page.locator('meta[name="robots"]').first().getAttribute('content') : null);

test('new terms: own pages indexable as their tier allows; synonyms point to their term and stay out of search', async ({ page }) => {
  await page.goto('/car-rental/loaner-car/kingston-on');
  await expect(page.locator('h1')).toHaveText('Loaner Car in Kingston');
  expect(await canonical(page)).toMatch(/\/car-rental\/loaner-car\/kingston-on$/);
  await noOverflow(page);

  await page.goto('/car-rental/car-rentals/kingston-on');
  await expect(page.locator('h1')).toHaveText('Car Rentals in Kingston');
  expect(await robots(page)).toMatch(/noindex/);
  expect(await canonical(page)).toMatch(/\/car-rental\/kingston-on$/);

  const r = await page.goto('/buy/car-loan/kingston-on');
  expect(r?.status()).toBe(200);
  expect(await robots(page)).toMatch(/noindex/);
  expect(await canonical(page)).toMatch(/\/buy\/auto-loans\/kingston-on$/);
  await expect(page.locator('body')).toContainText(/do not lend/i);
});

test('chauffeur terms take a request; body repair never promises mechanical work', async ({ page }) => {
  await page.goto('/car-rental/black-car-service/kingston-on');
  await expect(page.locator('h1')).toHaveText('Black Car Service in Kingston');
  await expect(page.locator('body')).toContainText('chauffeur service');
  await expect(page.locator('form').first()).toBeVisible();
  await page.goto('/body-shop/car-repair/kingston-on');
  await expect(page.locator('body')).toContainText('We do not do mechanical work');
  await noOverflow(page);
});

const locs = (xml: string) => [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => new URL(m[1]!.replace(/&amp;/g, '&')).pathname);
// 0124: the priority sitemap is /sitemap-priority-1.xml, -2.xml... (10,000 addresses each), first in the index
const priority = async (request: APIRequestContext) => {
  const parts = locs(await (await request.get('/sitemap.xml')).text()).filter((p) => /^\/sitemap-priority-\d+\.xml$/.test(p));
  const all: string[] = [];
  for (const p of parts) all.push(...locs(await (await request.get(p)).text()));
  return all;
};

test('crawl priority: the priority sitemap is first in the index, under 50,000 addresses, with cars, makes and place pages', async ({ request }) => {
  test.skip(test.info().project.name !== 'desktop-1440', 'one width is enough for files');
  const idx = locs(await (await request.get('/sitemap.xml')).text());
  expect(idx[0]).toBe('/sitemap-priority-1.xml');
  const res = await request.get('/sitemap-priority-1.xml');
  expect(res.status()).toBe(200);
  expect(res.headers()['cache-control']).toContain('stale-while-revalidate');
  const first = locs(await res.text());
  expect(first.length).toBeLessThanOrEqual(10_000);
  const urls = await priority(request);
  expect(urls.slice(0, first.length)).toEqual(first);
  // the old single file and the old index and child addresses move for good to their root names
  const old = await request.get('/sitemap-priority.xml', { maxRedirects: 0 });
  expect(old.status()).toBe(301);
  expect(old.headers()['location']).toMatch(/\/sitemap-priority-1\.xml$/);
  expect((await request.get('/sitemap-index/2.xml', { maxRedirects: 0 })).headers()['location'] ?? '').toMatch(/\/sitemap-index-2\.xml$/);
  expect((await request.get('/sitemap-places/rental.car-rental.1.xml', { maxRedirects: 0 })).headers()['location'] ?? '').toMatch(/\/sitemap-places-rental\.car-rental\.1\.xml$/);
  // every child of the index is at the site's root (an index may only list files in its directory or below)
  expect(idx.every((p) => /^\/sitemap-[a-z0-9.-]+\.xml$/.test(p)), 'every sitemap at the root').toBe(true);
  expect(urls.length).toBeGreaterThan(0);
  expect(urls.length).toBeLessThanOrEqual(50_000);
  expect(new Set(urls).size).toBe(urls.length);
  const cars = locs(await (await request.get('/sitemap-cars.xml')).text());
  expect(cars.length).toBeGreaterThan(0);
  expect(cars.every((c) => urls.includes(c)), 'every car of the fleet').toBe(true);
  expect(urls.some((u) => /^\/car-rental\/[a-z0-9-]+$/.test(u)), 'a place page nearest us').toBe(true);
});

test('click depth: footer Browse leads to every place (directory) and every make and model, in plain links', async ({ page }) => {
  await page.goto('/');
  const browse = page.getByRole('navigation', { name: 'Browse' });
  await expect(browse.getByRole('link', { name: 'Every place we cover' })).toHaveAttribute('href', '/places');
  await expect(browse.getByRole('link', { name: 'Every make and model' })).toHaveAttribute('href', '/makes');
  // 0124: the popular hubs of the priority list on every page: the cities nearest us and the services, in one click
  await expect(page.getByRole('navigation', { name: 'Cities' }).getByRole('link').first()).toHaveAttribute('href', /^\/car-rental\/[a-z0-9-]+$/);
  await expect(page.getByRole('navigation', { name: 'Services' }).getByRole('link').first()).toHaveAttribute('href', /^\/[a-z-]+\/[a-z0-9-]+\/[a-z0-9-]+$/);
  await page.goto('/places');
  const first = page.getByTestId('directory-pages').getByRole('link').first();
  await expect(first).toBeVisible();
  await first.click();
  await expect(page.locator('h1')).toHaveText(/^Places, page \d+$/);
  const place = page.locator('a.chip[href^="/car-rental/"]').first();
  const href = await place.getAttribute('href');
  await page.goto(href!);
  // the place page links to every term's page for it: four clicks from home
  const all = page.getByTestId('hub-all-terms');
  await expect(all.locator(`a[href^="/detailing/"][href$="${href!.split('/').pop()}"]`).first()).toBeVisible();
  await expect(all.locator(`a[href^="/buy/"]`).first()).toBeVisible();
  await page.goto('/makes');
  const model = page.locator('a.chip[href^="/cars/"]').first();
  await expect(model).toBeVisible();
  expect((await page.goto((await model.getAttribute('href'))!))?.status()).toBe(200);
  await noOverflow(page);
});

test('structured data: a rental page for a place we deliver to has its Service; a far one does not; no rating without reviews', async ({ page, request }) => {
  const ld = async () => (await page.locator('script[type="application/ld+json"]').allTextContents()).join(' ');
  const near = (await priority(request)).find((u) => /^\/car-rental\/rent-a-car\/(?!gta$)[a-z0-9-]+$/.test(u));
  expect(near).toBeTruthy();
  await page.goto(near!);
  expect(await ld()).toContain('"serviceType":"Car rental"');
  await page.goto('/car-rental/loaner-car/kingston-on');
  expect(await ld()).not.toContain('"serviceType":"Car rental"');
  expect(await ld()).not.toContain('AggregateRating');
});

// 0121: mechanical work has pages, never as our work: a request we arrange, a rental meanwhile, no questions, no Service
test('mechanical work we arrange: a request, never our work, no questions; synonyms point to their term', async ({ page, request }) => {
  const ld = async () => (await page.locator('script[type="application/ld+json"]').allTextContents()).join(' ');
  const near = (await priority(request)).find((u) => /^\/body-shop\/oil-change\/[a-z0-9-]+$/.test(u));
  expect(near, 'an oil change page in the priority sitemap').toBeTruthy();
  await page.goto(near!);
  await expect(page.locator('h1')).toHaveText(/^Oil Change in /);
  await expect(page.locator('body')).toContainText('does not do this work itself');
  await expect(page.locator('body')).toContainText('trusted shop');
  await expect(page.locator('#h-faq')).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Request the work' })).toBeVisible();
  await expect(page.getByTestId('auto-service-note')).toBeVisible();
  await expect(page.locator('#h-rent')).toContainText('Keep moving with a rental');
  await expect(page.locator('#h-rent')).not.toContainText('insurance');
  expect(await ld()).not.toContain('FAQPage');
  expect(await ld()).not.toContain('"@type":"Service"');
  await expect(page.locator('nav[aria-label^="Auto services we arrange"]').first()).toBeVisible();
  await noOverflow(page);
  // the request goes to the team
  await page.locator('#pl-request-name').fill('Auto Service Test');
  await page.locator('#pl-request-email').fill(`auto-${Date.now()}@example.com`);
  await page.locator('#pl-request-vehicle').fill('2019 Honda Civic');
  await page.getByRole('button', { name: 'Send the request' }).click();
  await expect(page.getByTestId('place-lead-sent')).toBeVisible();

  await page.goto('/body-shop/towing/kingston-on');
  await expect(page.locator('h1')).toHaveText('Towing in Kingston');
  await expect(page.locator('body')).toContainText('call 911 first');
  await expect(page.locator('body')).toContainText('honestly whether we know a shop there');
  await page.goto('/body-shop/tow-truck/kingston-on');
  expect(await robots(page)).toMatch(/noindex/);
  expect(await canonical(page)).toMatch(/\/body-shop\/towing\/kingston-on$/);

  await page.goto('/body-shop');
  await expect(page.getByTestId('arranged-terms').getByRole('link', { name: 'Oil Change in Toronto' })).toHaveAttribute('href', '/body-shop/oil-change/toronto');
});

// 0123 (owner: "Include them in the per car pages."): the per car pages of the mechanical work we arrange, honest the same way
test('mechanical work we arrange on the per car pages: a trusted shop, a rental meanwhile, no questions; in the vehicle sitemaps', async ({ page, request }) => {
  const ld = async () => (await page.locator('script[type="application/ld+json"]').allTextContents()).join(' ');
  expect((await page.goto('/t/oil-change/volkswagen/jetta/2020/sportline/scarborough'))?.status()).toBe(200);
  await expect(page.locator('h1')).toHaveText(/^Oil change for a 2020 Volkswagen Jetta Sportline in Scarborough$/);
  await expect(page.locator('body')).toContainText('CarmaCars does not do this work itself');
  await expect(page.locator('body')).toContainText('trusted shop');
  await expect(page.locator('body')).not.toContainText('insurance replacement');
  await expect(page.locator('#h-q')).toHaveCount(0);
  expect(await ld()).not.toContain('FAQPage');
  expect(await ld()).not.toContain('"@type":"Service"');
  expect(await ld()).not.toContain('AggregateRating');
  await expect(page.getByTestId('svc-rent-first').getByRole('link', { name: 'See cars to rent' })).toHaveAttribute('href', '/t/rental-car-while-car-is-in-the-shop/volkswagen/jetta/2020/sportline/scarborough');
  const form = page.getByTestId('lead-form');
  await expect(form.locator('input[name="marketing"]')).toHaveCount(0);
  await form.locator('#vl-name').fill('Auto Car Test');
  await form.locator('#vl-email').fill(`autocar-${Date.now()}@example.com`);
  await form.getByRole('button', { name: 'Request it' }).click();
  await expect(page.getByTestId('lead-sent')).toBeVisible();
  await noOverflow(page);
  if (test.info().project.name !== 'desktop-1440') return;
  // the vehicle sitemaps list the tree's files, and a file lists its pages
  const files = locs(await (await request.get('/sitemap.xml')).text()).filter((u) => u.startsWith('/sitemap-vehicles/t-oil-change-'));
  expect(files.length).toBeGreaterThan(0);
  const res = await request.get(files[0]!);
  expect(res.status()).toBe(200);
  const urls = locs(await res.text());
  expect(urls.length).toBeGreaterThan(0);
  expect(urls.length).toBeLessThanOrEqual(50_000);
  expect(urls.every((u) => u.startsWith('/t/oil-change/'))).toBe(true);
});
