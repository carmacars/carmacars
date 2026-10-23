import { expect, test, type Page } from '@playwright/test';
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

test('crawl priority: the priority sitemap is first in the index, under 50,000 addresses, with cars, makes and place pages', async ({ request }) => {
  test.skip(test.info().project.name !== 'desktop-1440', 'one width is enough for files');
  const idx = locs(await (await request.get('/sitemap.xml')).text());
  expect(idx[0]).toBe('/sitemap-priority.xml');
  const res = await request.get('/sitemap-priority.xml');
  expect(res.status()).toBe(200);
  const urls = locs(await res.text());
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
  const near = locs(await (await request.get('/sitemap-priority.xml')).text()).find((u) => /^\/car-rental\/rent-a-car\/(?!gta$)[a-z0-9-]+$/.test(u));
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
  const near = locs(await (await request.get('/sitemap-priority.xml')).text()).find((u) => /^\/body-shop\/oil-change\/[a-z0-9-]+$/.test(u));
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
  // no vehicle page tree for it
  expect((await request.get('/sitemap.xml')).ok()).toBe(true);
  expect(await (await request.get('/sitemap.xml')).text()).not.toContain('t-oil-change');
});
