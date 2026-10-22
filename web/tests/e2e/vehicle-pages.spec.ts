import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { acceptCookies, db, noOverflow } from './helpers';

// The vehicle pages (migration 0097) on the fixture catalog (supabase/seed/vehicle_catalog_fixture.sql): make, model,
// year and Canadian trim pages render with their own H1, specs, inventory and request link, at 375 and 1440, pass axe,
// never scroll sideways, are indexed and self-canonical by default; under the rules a trim page with no car of ours is
// noindex with its year as canonical and flips to indexed when our car of that trim is published; the vehicle sitemaps
// list only indexed pages; the old hub answers 301; unknown slugs are 404.
const jobToken = () => {
  const env = readFileSync(path.join(process.cwd(), '.env.local'), 'utf8');
  return createHmac('sha256', /^LINK_SIGNING_KEY=(.*)$/m.exec(env)![1]!.trim()).update('carmacars-listing-worker-v1').digest('hex');
};

// Two tests change the site-wide index settings for a while (the rules, the tier switches); every other test here reads
// pages whose indexing they change. A Postgres advisory lock keeps them apart across the workers: the settings tests
// hold it alone, the others share it (each on its own connection, released when the test ends).
const SETTINGS_TESTS = /^under the rules|^the Admin switches/;
let held: ReturnType<typeof db> | null = null;
test.beforeEach(async ({}, info) => {
  info.setTimeout(info.timeout + 180_000);
  held = db();
  if (SETTINGS_TESTS.test(info.title)) await held`select pg_advisory_lock(920097)`;
  else await held`select pg_advisory_lock_shared(920097)`;
});
test.afterEach(async () => { await held?.end(); held = null; });

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes[0]?.target}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text.match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(text, `${where}: never the numbered company`).not.toMatch(/18122211|Canada Inc/);
  expect(text, `${where}: brand spelling`).not.toMatch(/\bCarma Cars\b|\bCarmacars\b/);
}
const meta = async (page: Page) => page.evaluate(() => ({
  robots: document.querySelector('meta[name="robots"]')?.getAttribute('content') ?? null,
  canonical: document.querySelector('link[rel="canonical"]')?.getAttribute('href') ?? null,
  title: document.title,
  description: document.querySelector('meta[name="description"]')?.getAttribute('content') ?? null
}));

const PAGES: Array<[string, string, string]> = [
  ['make', '/cars/volkswagen', 'Rent a Volkswagen in Toronto'],
  ['model', '/cars/volkswagen/jetta', 'Rent a Volkswagen Jetta in Toronto'],
  ['year', '/cars/volkswagen/jetta/2020', 'Rent a 2020 Volkswagen Jetta in Toronto'],
  ['trim', '/cars/volkswagen/jetta/2020/sportline', 'Rent a 2020 Volkswagen Jetta Sportline in Toronto']
];

for (const [level, url, h1] of PAGES) {
  test(`the ${level} page renders, indexed and self-canonical, with inventory and the request link`, async ({ page }) => {
    test.setTimeout(120_000);
    const res = await page.goto(url);
    expect(res?.status(), url).toBe(200);
    await acceptCookies(page);
    await expect(page.locator('h1')).toHaveText(h1);
    const m = await meta(page);
    expect(m.robots ?? '', `${url} robots`).not.toContain('noindex');
    expect(m.canonical, `${url} canonical`).toMatch(new RegExp(`${url.replace(/\//g, '\\/')}$`));
    expect(m.title).toContain('CarmaCars');
    await expect(page.getByTestId('vp-inventory')).toBeVisible();
    await expect(page.getByTestId('vp-request').getByRole('link', { name: 'Request it' })).toHaveAttribute('href', /\/contact\?topic=car&car=/);
    // breadcrumbs up the tree, and JSON-LD with the breadcrumb and the questions
    await expect(page.locator('nav.crumbs a').first()).toBeVisible();
    const ld = (await page.locator('script[type="application/ld+json"]').allInnerTexts()).join(' ');
    expect(ld).toContain('BreadcrumbList');
    expect(ld).toContain('FAQPage');
    await check(page, url);
  });
}

test('every level has its own title and description', async ({ request }, info) => {
  test.skip(info.project.name.startsWith('phone'), 'once is enough');
  const seen = new Map<string, string>();
  for (const url of [...PAGES.map((x) => x[1]), '/cars/volkswagen/jetta/2021', '/cars/volkswagen/jetta/2020/highline']) {
    const html = await (await request.get(url)).text();
    for (const k of [/<title>(.*?)<\/title>/, /<meta name="description" content="(.*?)"/]) {
      const v = k.exec(html)?.[1] ?? '';
      expect(v, `${url}: ${k}`).not.toBe('');
      expect(seen.get(v), `${url}: shares "${v}"`).toBeUndefined();
      seen.set(v, url);
    }
  }
});

test('the year and trim pages carry their own data', async ({ page }) => {
  test.setTimeout(90_000);
  // the year page: specs, the Canadian trims, the other years
  await page.goto('/cars/volkswagen/jetta/2020');
  await acceptCookies(page);
  await expect(page.getByTestId('vp-specs')).toContainText('L/100 km');
  await expect(page.getByTestId('vp-trims')).toContainText('Sportline');
  await expect(page.getByTestId('vp-trims')).toContainText('Execline');
  await expect(page.getByTestId('vp-years')).toContainText('2019');
  // the trim page: how it compares, the siblings, the cost to drive
  await page.goto('/cars/volkswagen/jetta/2020/sportline');
  await expect(page.getByTestId('vp-diffs')).toContainText('trim 3 of 5');
  await expect(page.getByTestId('vp-diffs')).toContainText('The GLI has the 2.0L');
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
    // the fleet signature's rebuild (the Worker's cron tick; scripts/serve.mjs every 10 s), asked for at once here
    await expect.poll(async () => { await rebuild(); await page.goto(url); return (await meta(page)).robots ?? 'index'; }, { timeout: 60_000, intervals: [3_000] }).not.toContain('noindex');
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

// ---------------------------------------------------------------- city and colour pages, the /buy twins (0097)
const TIERS: Array<[string, string, RegExp]> = [
  ['city', '/cars/volkswagen/jetta/2020/sportline/mississauga', /^Rent a 2020 Volkswagen Jetta Sportline in Mississauga$/],
  ['city and colour', '/cars/volkswagen/jetta/2020/sportline/mississauga/black', /^Rent a black 2020 Volkswagen Jetta Sportline in Mississauga$/],
  ['colour', '/cars/volkswagen/jetta/2020/sportline/colour/gold', /^The 2020 Volkswagen Jetta Sportline in gold$/],
  ['for sale', '/buy/volkswagen/jetta/2020/sportline', /^2020 Volkswagen Jetta Sportline for sale$/],
  ['for sale in a city and colour', '/buy/volkswagen/jetta/2020/sportline/mississauga/black', /^Black 2020 Volkswagen Jetta Sportline for sale in Mississauga$/]
];
for (const [kind, url, h1] of TIERS) {
  test(`the ${kind} page renders, indexed and self-canonical, with every figure and its sources`, async ({ page }) => {
    test.setTimeout(120_000);
    const res = await page.goto(url);
    expect(res?.status(), url).toBe(200);
    await acceptCookies(page);
    await expect(page.locator('h1')).toHaveText(h1);
    const m = await meta(page);
    expect(m.robots ?? '', `${url} robots`).not.toContain('noindex');
    expect(m.canonical, `${url} canonical`).toMatch(new RegExp(`${url.replace(/\//g, '\\/')}$`));
    await expect(page.getByTestId('vp-figures')).toContainText('MPG combined (US)');
    await expect(page.getByTestId('vp-sources')).toContainText('fueleconomy.gov');
    const ld = (await page.locator('script[type="application/ld+json"]').allInnerTexts()).join(' ');
    expect(ld).toContain('BreadcrumbList');
    expect(ld).toContain('fuelConsumption');
    if (url.startsWith('/buy/')) {
      // honest: nothing for sale, no Offer; rent it for a week; find me this car
      await expect(page.getByTestId('buy-none')).toBeVisible();
      expect(ld).not.toMatch(/"Offer"|AggregateOffer/);
      await expect(page.getByTestId('buy-rent-first').getByRole('link', { name: /^Rent the / })).toHaveAttribute('href', `/cars${url.slice(4)}`);
      await expect(page.getByTestId('lead-form')).toBeVisible();
    } else {
      await expect(page.getByTestId('vp-inventory')).toBeVisible();
      if (url.includes('mississauga')) await expect(page.getByTestId('vp-city')).toContainText('Mississauga');
      await expect(page.locator('.vp-head__media img')).toHaveAttribute('src', url.endsWith('/black') ? /\/black\/lead\// : url.endsWith('/gold') ? /\/gold\/lead\// : /\/lead\//);
    }
    await check(page, url);
  });
}

test('city, colour and /buy pages: unique titles, descriptions and H1s, links between them, unknown ones 404', async ({ request }, info) => {
  test.skip(info.project.name.startsWith('phone'), 'once is enough');
  test.setTimeout(120_000);
  const seen = new Map<string, string>();
  const urls = ['/cars/volkswagen/jetta/2020/sportline', '/cars/volkswagen/jetta/2020/sportline/toronto', '/cars/volkswagen/jetta/2020/sportline/toronto/gold', '/cars/volkswagen/jetta/2020/sportline/colour/gold',
    '/cars/volkswagen/jetta/2020/sportline/mississauga', '/cars/volkswagen/jetta/2020/highline/mississauga', '/cars/volkswagen/jetta/2020/sportline/oakville/red',
    '/buy/volkswagen/jetta/2020/sportline', '/buy/volkswagen/jetta/2020/sportline/toronto', '/buy/volkswagen/jetta/2020/sportline/colour/gold', '/buy/volkswagen', '/buy/volkswagen/jetta'];
  for (const url of urls) {
    const r = await request.get(url);
    expect(r.status(), url).toBe(200);
    const html = await r.text();
    for (const [i, k] of [/<title>(.*?)<\/title>/, /<meta name="description" content="(.*?)"/, /<h1[^>]*>(.*?)<\/h1>/].entries()) {
      const v = k.exec(html)?.[1] ?? '';
      expect(v, `${url}: ${k}`).not.toBe('');
      expect(seen.get(`${i}|${v}`), `${url}: shares "${v}"`).toBeUndefined();
      seen.set(`${i}|${v}`, url);
    }
  }
  const trim = await (await request.get('/cars/volkswagen/jetta/2020/sportline')).text();
  expect(trim).toContain('href="/cars/volkswagen/jetta/2020/sportline/mississauga"');
  expect(trim).toContain('href="/cars/volkswagen/jetta/2020/sportline/colour/gold"');
  expect(trim).toContain('href="/buy/volkswagen/jetta/2020/sportline"');
  for (const u of ['/cars/volkswagen/jetta/2020/sportline/colour', '/cars/volkswagen/jetta/2020/sportline/nowhere', '/cars/volkswagen/jetta/2020/sportline/mississauga/plaid',
    '/cars/volkswagen/jetta/2020/sportline/colour/plaid', '/buy/nosuchmake', '/buy/volkswagen/jetta/2020/sportline/nowhere'])
    expect((await request.get(u)).status(), u).toBe(404);
});

test('sitemaps: the city, colour and /buy files, each under 50,000 addresses, read in slices; robots names the index', async ({ request }, info) => {
  test.skip(info.project.name.startsWith('phone'), 'once is enough');
  test.setTimeout(120_000);
  const index = await (await request.get('/sitemap.xml')).text();
  expect(index).toContain('/sitemap-vehicles/tiers-1.xml');
  expect(index).toContain('/sitemap-vehicles/buy-tiers-1.xml');
  expect(index).toContain('/sitemap-vehicles/buy-makes.xml');
  const tiers = await (await request.get('/sitemap-vehicles/tiers-1.xml')).text();
  const locs = [...tiers.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => new URL(m[1]!).pathname);
  expect(locs.length).toBeGreaterThan(1000);
  expect(locs.length).toBeLessThanOrEqual(50_000);
  expect(new Set(locs).size, 'no address twice across the keyset slices').toBe(locs.length);
  expect(locs).toContain('/cars/volkswagen/jetta/2020/sportline/mississauga/black');
  expect(locs).toContain('/cars/volkswagen/jetta/2020/sportline/colour/gold');
  const buy = await (await request.get('/sitemap-vehicles/buy-tiers-1.xml')).text();
  expect(buy).toContain('/buy/volkswagen/jetta/2020/sportline/mississauga/black</loc>');
  expect((await request.get('/sitemap-vehicles/tiers-999.xml')).status()).toBe(404);
  expect((await request.get('/sitemap-index/2.xml')).status()).toBe(404);
  expect(await (await request.get('/robots.txt')).text()).toMatch(/Sitemap: \S+\/sitemap\.xml/);
});

test('the Admin switches take the city and colour pages and the /buy tree out of search at once', async ({ request }, info) => {
  test.skip(info.project.name.startsWith('phone'), 'once is enough');
  test.setTimeout(150_000);
  const sql = db();
  const rebuild = () => request.post('/api/jobs/public-rebuild', { headers: { authorization: `Bearer ${jobToken()}`, 'content-type': 'application/json' }, data: {} });
  const robots = async (u: string) => /<meta name="robots" content="([^"]*)"/.exec(await (await request.get(u)).text())?.[1] ?? '';
  try {
    await sql`update program_settings set vpage_place_index = false, vpage_colour_index = false, vpage_buy_index = false where id = (app.settings()).id`;
    await expect.poll(async () => { await rebuild(); return robots('/cars/volkswagen/jetta/2020/sportline/oakville'); }, { timeout: 60_000, intervals: [2_000] }).toContain('noindex');
    await expect.poll(async () => robots('/buy/volkswagen/jetta/2020'), { timeout: 30_000, intervals: [2_000] }).toContain('noindex');
    const index = await (await request.get('/sitemap.xml')).text();
    expect(index).not.toMatch(/\/sitemap-vehicles\/(t-[a-z-]+-)?tiers-/);
    expect(index).not.toContain('/sitemap-vehicles/buy-');
    expect(await robots('/cars/volkswagen/jetta/2020/sportline')).not.toContain('noindex');
  } finally {
    await sql`update program_settings set vpage_place_index = true, vpage_colour_index = true, vpage_buy_index = true where id = (app.settings()).id`;
    await rebuild();
    await sql.end();
  }
});

test('"Find me this car" makes a buyer lead for Sales with a To do line', async ({ page }, info) => {
  test.skip(info.project.name.startsWith('phone'), 'once is enough');
  test.setTimeout(90_000);
  const sql = db();
  const email = `buyer-${randomBytes(3).toString('hex')}@example.com`;
  try {
    await page.goto('/buy/volkswagen/jetta/2020/sportline');
    await acceptCookies(page);
    const f = page.getByTestId('lead-form');
    await f.getByLabel('Your name').fill('Sam Buyer');
    await f.getByRole('textbox', { name: 'Email' }).fill(email);
    await f.getByLabel('Budget').fill('24000');
    await f.getByLabel('When do you want to buy?').selectOption('three');
    await f.getByRole('button', { name: 'Find me this car' }).click();
    await expect(page.getByTestId('lead-sent')).toBeVisible({ timeout: 20_000 });
    const [lead] = await sql`select l.kind, l.payload ->> 'vehicle' as car, t.queue from leads l join tasks t on t.related_id = l.id where l.email = ${email}`;
    expect(lead).toMatchObject({ kind: 'buyer', car: '2020 Volkswagen Jetta Sportline', queue: 'sales' });
  } finally {
    await sql.end();
  }
});

const TERMS: Array<[string, string, RegExp, string]> = [
  ['renting search', '/t/car-hire/volkswagen/jetta/2020/sportline/mississauga', /^2020 Volkswagen Jetta Sportline car hire in Mississauga$/, 'vp-inventory'],
  ['financing', '/t/financing/volkswagen/jetta/2020/sportline/oakville', /^2020 Volkswagen Jetta Sportline financing in Oakville$/, 'finance-disclaimer'],
  ['detailing', '/t/ceramic-coating/volkswagen/jetta/2020/sportline/mississauga/black', /^Ceramic coating for a black 2020 Volkswagen Jetta Sportline in Mississauga$/, 'svc-rent-first'],
  ['body shop', '/t/bumper-repair/volkswagen/jetta/2020/sportline/scarborough', /^Bumper repair for a 2020 Volkswagen Jetta Sportline in Scarborough$/, 'svc-rent-first']
];
for (const [kind, url, h1, block] of TERMS) {
  test(`a ${kind} page renders, indexed and self-canonical, with its own block`, async ({ page }) => {
    test.setTimeout(120_000);
    const res = await page.goto(url);
    expect(res?.status(), url).toBe(200);
    await acceptCookies(page);
    await expect(page.locator('h1')).toHaveText(h1);
    const m = await meta(page);
    expect(m.robots ?? '', `${url} robots`).not.toContain('noindex');
    expect(m.canonical, `${url} canonical`).toMatch(new RegExp(`${url.replace(/\//g, '\\/')}$`));
    await expect(page.getByTestId(block)).toBeVisible();
    const ld = (await page.locator('script[type="application/ld+json"]').allInnerTexts()).join(' ');
    expect(ld).not.toMatch(/"Offer"/);
    if (kind === 'financing') await expect(page.getByTestId('finance-disclaimer')).toContainText('not a lender');
    if (kind === 'body shop') await expect(page.getByTestId('svc-rent-first').getByRole('link', { name: 'See cars to rent' })).toHaveAttribute('href', '/t/insurance-replacement/volkswagen/jetta/2020/sportline/scarborough');
    if (kind !== 'renting search') await expect(page.getByTestId('lead-form')).toBeVisible();
    await check(page, url);
  });
}

test('the term index and an unknown term', async ({ request }, info) => {
  test.skip(info.project.name.startsWith('phone'), 'once is enough');
  expect((await request.get('/t/car-hire')).status()).toBe(200);
  expect(await (await request.get('/t/car-hire')).text()).toContain('href="/t/car-hire/volkswagen"');
  expect((await request.get('/t/nosuchterm/volkswagen')).status()).toBe(404);
  const idx = await (await request.get('/sitemap.xml')).text();
  expect(idx).toContain('/sitemap-vehicles/t-car-hire-makes.xml');
  expect(idx).toContain('/sitemap-vehicles/t-bumper-repair-tiers-1.xml');
  const f = await (await request.get('/sitemap-vehicles/t-ceramic-coating-volkswagen-trims.xml')).text();
  expect(f).toContain('/t/ceramic-coating/volkswagen/jetta/2020/sportline</loc>');
});
