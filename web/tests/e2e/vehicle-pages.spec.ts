import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { acceptCookies, db, noOverflow } from './helpers';

// The vehicle pages (migration 0092) on the fixture catalog (supabase/seed/vehicle_catalog_fixture.sql): make, model,
// year and Canadian trim pages render with their own H1, specs, inventory and request link, at 375 and 1440, pass axe,
// never scroll sideways, are indexed and self-canonical by default; under the rules a trim page with no car of ours is
// noindex with its year as canonical and flips to indexed when our car of that trim is published; the vehicle sitemaps
// list only indexed pages; the old hub answers 301; unknown slugs are 404.
const jobToken = () => {
  const env = readFileSync(path.join(process.cwd(), '.env.local'), 'utf8');
  return createHmac('sha256', /^LINK_SIGNING_KEY=(.*)$/m.exec(env)![1]!.trim()).update('carmacars-listing-worker-v1').digest('hex');
};

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes[0]?.target}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text.match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(text, `${where}: never the numbered company`).not.toMatch(/18122211|Canada Inc/);
  expect(text, `${where}: brand spelling`).not.toMatch(/\bCarma Cars\b|\bCarmacars\b/);
}
const meta = async (page: Page) => ({
  robots: await page.locator('meta[name="robots"]').getAttribute('content').catch(() => null),
  canonical: await page.locator('link[rel="canonical"]').getAttribute('href').catch(() => null),
  title: await page.title(),
  description: await page.locator('meta[name="description"]').getAttribute('content')
});

const PAGES: Array<[string, string, string]> = [
  ['make', '/cars/volkswagen', 'Rent a Volkswagen in Toronto'],
  ['model', '/cars/volkswagen/jetta', 'Rent a Volkswagen Jetta in Toronto'],
  ['year', '/cars/volkswagen/jetta/2020', 'Rent a 2020 Volkswagen Jetta in Toronto'],
  ['trim', '/cars/volkswagen/jetta/2020/sportline', 'Rent a 2020 Volkswagen Jetta Sportline in Toronto']
];

test('make, model, year and trim pages render, indexed and self-canonical, with inventory and the request link', async ({ page }) => {
  test.setTimeout(120_000);
  const seen = new Map<string, string>();
  for (const [level, url, h1] of PAGES) {
    const res = await page.goto(url);
    expect(res?.status(), url).toBe(200);
    if (level === 'make') await acceptCookies(page);
    await expect(page.locator('h1')).toHaveText(h1);
    const m = await meta(page);
    expect(m.robots ?? '', `${url} robots`).not.toContain('noindex');
    expect(m.canonical, `${url} canonical`).toMatch(new RegExp(`${url.replace(/\//g, '\\/')}$`));
    for (const k of ['title', 'description'] as const) { expect(seen.has(m[k]!), `${url}: ${k} unique`).toBe(false); seen.set(m[k]!, url); }
    expect(m.title).toContain('CarmaCars');
    const inv = page.getByTestId('vp-inventory');
    await expect(inv).toBeVisible();
    await expect(page.getByTestId('vp-request').getByRole('link', { name: 'Request it' })).toHaveAttribute('href', /\/contact\?topic=car&car=/);
    // breadcrumbs up the tree, and JSON-LD with the breadcrumb and the questions
    const ld = await page.locator('script[type="application/ld+json"]').allInnerTexts();
    expect(ld.join(' ')).toContain('BreadcrumbList');
    expect(ld.join(' ')).toContain('FAQPage');
    await check(page, url);
  }
  // the year page: specs, the Canadian trims, the other years
  await page.goto('/cars/volkswagen/jetta/2020');
  await expect(page.getByTestId('vp-specs')).toContainText('L/100 km');
  await expect(page.getByTestId('vp-trims')).toContainText('Sportline');
  await expect(page.getByTestId('vp-trims')).toContainText('Execline');
  await expect(page.getByTestId('vp-years')).toContainText('2019');
  // the trim page: how it compares, the siblings, the cost to drive
  await page.goto('/cars/volkswagen/jetta/2020/sportline');
  await expect(page.getByTestId('vp-diffs')).toContainText('trim 3 of 5');
  await expect(page.getByTestId('vp-siblings')).toContainText('Comfortline');
  await expect(page.getByTestId('vp-cost')).toContainText('100 km');
  // no Jetta of ours: similar cars instead of an empty block
  await expect(page.getByTestId('vp-none')).toBeVisible();
  await expect(page.getByTestId('vp-inventory')).toContainText('Similar cars available now');
  await expect(page.getByTestId('vp-availability').first()).toContainText(/tomorrow/);
});

test('a car of ours sits on its exact trim page; offers only for real cars', async ({ page }) => {
  // the sample 2023 Toyota Corolla LE (seed) is on its trim page as an example car; JSON-LD carries no offer for a sample
  await page.goto('/cars/toyota/corolla/2023/le');
  await acceptCookies(page);
  const inv = page.getByTestId('vp-inventory');
  await expect(inv.locator('.car-card').first()).toContainText('Corolla');
  await expect(inv.getByTestId('example-car-badge').first()).toBeVisible();
  const ld = (await page.locator('script[type="application/ld+json"]').allInnerTexts()).join(' ');
  expect(ld).not.toContain('AggregateOffer');
  await check(page, '/cars/toyota/corolla/2023/le');
  // the model's other spelling answers 301; the old model hub answers 301; unknown slugs are 404
  const alias = await page.request.get('/cars/mercedes-benz/c300', { maxRedirects: 0 });
  expect([301, 308]).toContain(alias.status());
  expect(alias.headers().location).toMatch(/\/cars\/mercedes-benz\/c-class$/);
  const hub = await page.request.get('/rent/toyota-corolla', { maxRedirects: 0 });
  expect([301, 308]).toContain(hub.status());
  expect(hub.headers().location).toMatch(/\/cars\/toyota\/corolla$/);
  for (const u of ['/cars/nosuchmake', '/cars/volkswagen/nosuchmodel', '/cars/volkswagen/jetta/1999', '/cars/volkswagen/jetta/20x0', '/cars/volkswagen/jetta/2020/nosuchtrim', '/cars/Volkswagen/Jetta'])
    expect((await page.request.get(u)).status(), u).toBe(404);
});

test('the vehicle sitemaps list every indexed page, by make and level, with lastmod', async ({ request }, info) => {
  test.skip(info.project.name.startsWith('phone'), 'once is enough');
  const index = await (await request.get('/sitemap.xml')).text();
  expect(index).toContain('/sitemap-vehicles/makes.xml');
  expect(index).toContain('/sitemap-vehicles/volkswagen-trims.xml');
  const trims = await request.get('/sitemap-vehicles/volkswagen-trims.xml');
  expect(trims.status()).toBe(200);
  const xml = await trims.text();
  expect(xml).toContain('/cars/volkswagen/jetta/2020/sportline</loc><lastmod>');
  expect((xml.match(/<url>/g) ?? []).length).toBeLessThan(50_000);
  expect((await request.get('/sitemap-vehicles/nosuch-trims.xml')).status()).toBe(404);
  expect(await (await request.get('/sitemap-pages.xml')).text()).not.toContain('/rent/');
});

test('under the rules a trim page with no car is noindex with its year as canonical, and flips with our car', async ({ page, request }, info) => {
  test.skip(info.project.name.startsWith('phone'), 'once is enough');
  test.setTimeout(150_000);
  const sql = db();
  const rebuild = () => request.post('/api/jobs/public-rebuild', { headers: { authorization: `Bearer ${jobToken()}`, 'content-type': 'application/json' }, data: {} });
  const url = '/cars/volkswagen/jetta/2021/execline';
  const car = randomUUID();
  try {
    await sql`update program_settings set vpage_index_mode = 'rules' where id = (app.settings()).id`;
    await rebuild();
    await expect.poll(async () => { await page.goto(url); return (await meta(page)).robots ?? ''; }, { timeout: 30_000, intervals: [1_000] }).toContain('noindex');
    expect((await meta(page)).canonical).toMatch(/\/cars\/volkswagen\/jetta\/2021$/);
    expect(await (await request.get('/sitemap-vehicles/volkswagen-trims.xml')).text()).not.toContain(`${url}<`);
    // our real 2021 Jetta Execline is published: the page flips to indexed and joins its sitemap
    const [o] = await sql`select id from owners order by created_at limit 1`;
    await sql`insert into vehicles (id, owner_id, year, make, model, trim, colour, plate, class, status, management_mode, onboarding_method, body_type)
              values (${car}, ${o!.id}, 2021, 'Volkswagen', 'Jetta', 'Execline', 'White', ${'VP' + randomBytes(2).toString('hex').toUpperCase()}, 'standard', 'available', 'managed', 'transfer', 'Sedan')`;
    await sql`select app.ensure_listing(${car})`;
    await sql`update vehicle_listings set status = 'published', slug = app.listing_slug(${car}), first_published_at = now(), seats = 5, transmission = 'Automatic', body_style = 'Sedan' where vehicle_id = ${car}`;
    await expect.poll(async () => { await page.goto(url); return (await meta(page)).robots ?? 'index'; }, { timeout: 45_000, intervals: [2_000] }).not.toContain('noindex');
    expect((await meta(page)).canonical).toMatch(/\/cars\/volkswagen\/jetta\/2021\/execline$/);
    await expect(page.getByTestId('vp-inventory').locator('.car-card').first()).toContainText('Jetta');
    expect(await (await request.get('/sitemap-vehicles/volkswagen-trims.xml')).text()).toContain(`${url}<`);
  } finally {
    await sql`update program_settings set vpage_index_mode = 'all' where id = (app.settings()).id`;
    await sql`update vehicle_listings set status = 'unpublished', unpublished_at = now(), unpublished_reason = 'e2e fixture' where vehicle_id = ${car}`;
    await rebuild();
    await sql.end();
  }
});
