import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Release 48, SEO (docs/changes/2026-11-20-r48-seo.md), at 375 and 1440: the tracker product page with its prices
// (free for vehicle owners and the first 100 pre-orders, then $90 and $175) and the waitlist (never "in stock"), its intent pages and install pages (gated like the place pages), the old
// address redirected, every search page carrying the other services and the phone's sticky action, the new landing pages
// with the add-on's own price, llms.txt, the sitemap; where a lead came from on the lead page; duplicate leads merged by
// the rule and with one click; the confirmation email queued.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const ld = async (page: Page) => (await page.locator('script[type="application/ld+json"]').allTextContents())
  .flatMap((s) => { const j = JSON.parse(s) as { '@graph'?: Record<string, unknown>[] }; return j['@graph'] ?? [j as Record<string, unknown>]; });
const node = (nodes: Record<string, unknown>[], type: string) => nodes.find((n) => ([] as unknown[]).concat(n['@type'] ?? []).includes(type));

async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('main').innerText();
  expect(text.match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
}
async function mkAdmin(sql: Sql) {
  const id = randomUUID(); const email = `admin.seo.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Seo Admin')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 60_000 });
}

test('the tracker product page: free for owners and the first 100 pre-orders then $90 and $175, the waitlist while trackers are not in hand, Product as PreOrder, never "in stock"', async ({ page, request }) => {
  await page.goto('/trackers');
  await expect(page.locator('h1')).toHaveText('GPS tracker and kill switch for your car');
  await expect(page.locator('[data-page="trackers"]')).toHaveAttribute('data-trackers-available', 'no');
  await expect(page.getByTestId('kit-pill')).toHaveText('Shipping soon');
  await expect(page.getByTestId('kit-lead')).toContainText('The tracker is free for the first 100 pre-orders, $90 on pre-order after that and $175 after launch; CarmaCars vehicle owners get the tracker free');
  await expect(page.getByTestId('kit-lead')).toContainText('$150 once per car to install');
  const prices = page.getByTestId('kit-prices').first();
  for (const [who, amt] of [['CarmaCars vehicle owners', 'Free'], ['The first 100 pre-orders', 'Free'], ['After launch', '$175']] as const) await expect(prices.locator('li.sk-price', { hasText: who })).toContainText(amt);
  await expect(page.getByTestId('kit-compare')).toBeVisible();
  await expect(page.getByTestId('kit-tiles').first()).toContainText('Kill switch');
  const main = await page.locator('main').innerText();
  expect(main).not.toMatch(/in stock|available now|buy now/i);
  const nodes = await ld(page);
  const product = node(nodes, 'Product') as { offers: { '@type': string; price: string; priceCurrency: string; availability: string } };
  expect(product.offers).toMatchObject({ '@type': 'Offer', price: '0.00', priceCurrency: 'CAD', availability: 'https://schema.org/PreOrder' });
  // the number that really closes the offer, a count and a monthly price are nowhere on the page
  expect(await page.locator('main').innerText()).not.toMatch(/\b250\b|spots? left|remaining|a month per car/i);
  expect((node(nodes, 'FAQPage') as { mainEntity: unknown[] }).mainEntity.length).toBeGreaterThanOrEqual(5);
  expect(node(nodes, 'BreadcrumbList')).toBeTruthy();
  expect(await page.locator('link[rel="canonical"]').getAttribute('href')).toMatch(/\/trackers$/);
  // the phone has one action within reach of the thumb; a wide screen has it in the page
  if (isPhone()) await expect(page.getByTestId('kit-sticky')).toBeVisible(); else await expect(page.getByTestId('kit-sticky')).toBeHidden();
  await axe(page, '/trackers');
  // the old address answers one permanent redirect
  const old = await request.get('/gps-tracker', { maxRedirects: 0 });
  expect(old.status()).toBe(308);
  expect(old.headers().location).toMatch(/\/trackers$/);
});

test('the waitlist: two fields, what the person pays as they choose, the tier and the owner flag on the lead, a lead for Sales with its source, the confirmation email queued', async ({ page }) => {
  const sql = db();
  const email = `host.${Date.now()}.${tag()}@example.test`;
  try {
    // a visit that ChatGPT sent, as its links are tagged
    await page.goto('/trackers/kill-switch-for-car?utm_source=chatgpt.com', { referer: 'https://chatgpt.com/' });
    await acceptCookies(page);
    await expect(page.locator('h1')).toHaveText('Kill switch for a car, worked from your phone');
    await page.goto('/trackers');
    await acceptCookies(page);
    const form = page.getByTestId('tracker-waitlist-form');
    await form.scrollIntoViewIfNeeded();
    await form.getByLabel('Email').fill(email);
    await form.getByLabel('How many cars').fill('4');
    await expect(page.getByTestId('tracker-waitlist-quote')).toContainText('The tracker is free for the first 100 pre-orders');
    await expect(page.getByTestId('tracker-waitlist-quote')).toContainText('$150');
    await expect(page.getByTestId('tracker-waitlist-quote')).toContainText('$600');
    // a vehicle owner sees the owner price, and back
    await page.getByTestId('tracker-waitlist-owner').check();
    await expect(page.getByTestId('tracker-waitlist-quote')).toContainText('The tracker is free for CarmaCars vehicle owners');
    await page.getByTestId('tracker-waitlist-owner').uncheck();
    await form.locator('input[name="want"][value="preorder"]').check();
    await page.getByTestId('tracker-waitlist-go').click();
    await expect(page.getByTestId('tracker-waitlist-sent')).toContainText('You are on the list');
    await expect(page.getByTestId('tracker-waitlist-tier')).toContainText('Pre-order: your tracker is free.');
    const [lead] = await sql`select l.id, app.sl_source(l) source, l.payload, (select c.channel || '|' || c.first_landing from contact_sources c where c.lead_id = l.id) src from leads l where l.email = ${email}`;
    expect(lead!.source).toBe('GPS tracker pre-order (free tracker)');
    expect(lead!.payload).toMatchObject({ cars: 4, tier: 'free_preorder', owner: false, owner_claimed: false, owner_matched: false, quoted_device_cents: 0, quoted_install_cents: 15000, trackers_available: false });
    expect(lead!.src).toBe('chatgpt|/trackers/kill-switch-for-car');
    await expect.poll(async () => (await sql`select count(*)::int n from app_events where code = 'tracker_waitlist_joined' and entity_id = ${lead!.id}`)[0]!.n).toBe(1);
    await sql`select app.process_events()`;
    const [mail] = await sql`select to_address, payload from notification_outbox where code = 'tracker_waitlist_joined' and entity_id = ${lead!.id}`;
    expect(mail!.to_address).toBe(email);
    expect(mail!.payload).toMatchObject({ tier_label: 'Pre-order', tracker_price: 'Free with your pre-order', install_price: '$150 once per car', cars_count: '4' });
  } finally { await sql.end(); }
});

test('the intent pages are their own pages, and the install pages follow the place pages\' gate', async ({ page, request }) => {
  const seen = new Set<string>();
  for (const slug of ['kill-switch-for-car', 'starter-interrupt-device', 'gps-tracker-for-rental-car', 'anti-theft-tracker-toronto', 'fleet-tracking', 'turo-host-gps-tracker', 'toll-and-ticket-billing']) {
    const r = await request.get(`/trackers/${slug}`);
    expect(r.status(), slug).toBe(200);
    const html = await r.text();
    const title = /<title>([^<]+)<\/title>/.exec(html)?.[1] ?? '';
    const h1 = /<h1[^>]*>([\s\S]*?)<\/h1>/.exec(html)?.[1] ?? '';
    expect(seen.has(title) || seen.has(h1), `${slug}: a title or heading repeats`).toBe(false);
    seen.add(title); seen.add(h1);
    expect(html).toContain(`<link rel="canonical" href="`);
    expect(html).toMatch(new RegExp(`rel="canonical" href="[^"]+/trackers/${slug}"`));
    expect(html).not.toMatch(/name="robots" content="[^"]*noindex/);
    expect(html).toContain('"FAQPage"');
  }
  expect((await request.get('/trackers/no-such-page')).status()).toBe(404);
  await page.goto('/trackers/turo-host-gps-tracker');
  await expect(page.getByTestId('kit-lead')).toContainText('not affiliated with Turo');
  await expect(page.getByTestId('kit-compare')).toBeVisible();
  await axe(page, '/trackers/turo-host-gps-tracker');
  // an Ontario place we reach: its own page with its own facts; a place whose region is off: 404, like the place pages
  await page.goto('/trackers/install/mississauga');
  await expect(page.locator('h1')).toHaveText('GPS tracker and kill switch install in Mississauga');
  await expect(page.getByTestId('kit-facts').first()).toContainText('Mississauga, Ontario');
  await expect(page.getByTestId('kit-facts').first()).toContainText(/About \d+ km/);
  expect(await page.locator('meta[name="robots"]').count()).toBe(0);
  expect(node(await ld(page), 'Service')).toMatchObject({ serviceType: 'GPS tracker installation' });
  await axe(page, '/trackers/install/mississauga');
  expect((await request.get('/trackers/install/buffalo-ny')).status()).toBe(404);
  expect((await request.get('/trackers/install/no-such-place-zz')).status()).toBe(404);
  await page.goto('/trackers/install');
  await expect(page.locator('#install a', { hasText: 'Tracker install in Mississauga' })).toBeVisible();
});

test('every search page carries the other services, with the tracker first, and the phone\'s sticky action', async ({ page }) => {
  for (const path of ['/car-rental/toronto', '/car-rental/monthly', '/car-rental/mississauga', '/services', '/chauffeur', '/delivery', '/list-your-car', '/cars/toyota/corolla']) {
    await page.goto(path);
    if (path === '/services') {
      for (const key of ['trackers', 'owner', 'chauffeur', 'delivery', 'coverage', 'monthly', 'replacement', 'rideshare', 'young', 'addons']) await expect(page.locator(`section#${key}`), key).toBeVisible();
      await expect(page.locator('section#trackers')).toContainText('Free for the first 100 pre-orders, then $90');
    } else {
      const promo = page.getByTestId('service-promo');
      await expect(promo, path).toBeVisible();
      if (path !== '/list-your-car') await expect(promo.locator('a[data-service]').first(), path).toHaveAttribute('data-service', 'trackers');
      await expect(promo.locator('a[data-service="trackers"]'), path).toContainText('Pre-order or join the waitlist');
      // the page's own service is never promoted to itself
      const own = path === '/chauffeur' ? 'chauffeur' : path === '/delivery' ? 'delivery' : path === '/list-your-car' ? 'owner' : path === '/car-rental/monthly' ? 'monthly' : null;
      if (own) await expect(promo.locator(`a[data-service="${own}"]`), path).toHaveCount(0);
    }
    if (isPhone() && path !== '/cars/toyota/corolla') await expect(page.getByTestId('kit-sticky'), path).toBeVisible();
    await noOverflow(page);
  }
  // every link of the module answers
  await page.goto('/car-rental/toronto');
  const hrefs = await page.getByTestId('service-promo').locator('a[href^="/"]').evaluateAll((as) => [...new Set(as.map((a) => a.getAttribute('href')!.split('#')[0]!))]);
  expect(hrefs.length).toBeGreaterThanOrEqual(6);
  for (const h of hrefs) expect((await page.request.get(h)).status(), h).toBe(200);
  await axe(page, '/car-rental/toronto');
});

test('the new landing pages: the add-on\'s own price card, the copy as folds, FAQ data, and the redesigned blocks', async ({ page, request }) => {
  await page.goto('/car-rental/with-flowers');
  await expect(page.locator('h1')).toHaveText('A rental car with flowers waiting inside');
  await expect(page.locator('#addons')).toContainText('Flowers');
  await expect(page.locator('#addons')).toContainText(/\$\d+/);
  const folds = page.getByTestId('landing-sections').locator('details');
  expect(await folds.count()).toBeGreaterThanOrEqual(3);
  await expect(folds.first()).toHaveAttribute('open', '');
  await expect(folds.nth(1)).not.toHaveAttribute('open', '');
  await folds.nth(1).locator('summary').click();
  await expect(folds.nth(1)).toHaveAttribute('open', '');
  await expect(page.getByTestId('kit-trust').first()).toContainText('No payment to request');
  expect((node(await ld(page), 'FAQPage') as { mainEntity: unknown[] }).mainEntity.length).toBeGreaterThanOrEqual(3);
  await axe(page, '/car-rental/with-flowers');
  for (const slug of ['rideshare', 'g2-licence', 'with-a-charger', 'with-child-seat']) {
    const r = await request.get(`/car-rental/${slug}`);
    expect(r.status(), slug).toBe(200);
    const html = await r.text();
    expect(html, slug).not.toMatch(/\{\{\w+\}\}/);
    expect(html, slug).not.toMatch(/name="robots" content="[^"]*noindex/);
  }
  await page.goto('/car-rental/with-child-seat');
  await expect(page.locator('#addons li.sk-price')).toHaveCount(3);
  await page.goto('/car-rental/rideshare');
  await expect(page.locator('h1')).toContainText('rideshare and delivery drivers');
});

test('llms.txt, the sitemap and the footer know the tracker and the services', async ({ page, request }) => {
  const t = await (await request.get('/llms.txt')).text();
  expect(t).toContain('## GPS tracker and kill switch');
  for (const line of ['Price of the tracker, CarmaCars vehicle owners: Free', 'Price of the tracker, the first 100 pre-orders: Free', 'Price of the tracker, Pre-orders after that: $90', 'Price of the tracker, After launch: $175', 'Install: $150 once per car to install']) expect(t, line).toContain(line);
  expect(t).not.toMatch(/a month per car|\b250\b/);
  expect(t).toMatch(/not sold from stock today/);
  expect(t).toMatch(/\/trackers\/kill-switch-for-car\)/);
  expect(t).not.toMatch(/\{\{|[–—]|\/gps-tracker\)/);
  const full = await (await request.get('/llms-full.txt')).text();
  expect(full).toContain('### Questions about the tracker');
  const fam = await (await request.get('/sitemap-families.xml')).text();
  for (const p of ['/trackers', '/trackers/kill-switch-for-car', '/trackers/install', '/trackers/install/mississauga']) expect(fam, p).toContain(`${p}</loc>`);
  expect(fam).not.toContain('/gps-tracker</loc>');
  expect(await (await request.get('/sitemap-pages.xml')).text()).toContain('/services</loc>');
  await page.goto('/');
  await expect(page.getByTestId('footer-trackers')).toHaveAttribute('href', '/trackers');
  await expect(page.getByTestId('footer-services')).toHaveAttribute('href', '/services');
});

test('the car page: the whole price under the daily rate, a direct request and trust badges', async ({ page }) => {
  await page.goto('/cars/tesla-model-3');
  await expect(page.getByTestId('car-price-clarity')).toContainText('a week');
  await expect(page.getByTestId('car-price-clarity')).toContainText('HST');
  await expect(page.getByTestId('car-price-clarity')).toContainText('deposit before pickup');
  // an example car keeps its own enquiry; a real car has the button straight to the request
  if (await page.getByTestId('example-car-badge').count()) await expect(page.getByTestId('car-request-direct')).toHaveCount(0);
  else await expect(page.getByTestId('car-request-direct')).toHaveAttribute('href', '/book/tesla-model-3');
  await expect(page.locator('.car-top__cta').getByTestId('kit-trust')).toContainText('No payment to request');
  await noOverflow(page);
});

test('a lead says where it came from; a second form joins it by itself; a later duplicate merges with one click', async ({ browser, page }) => {
  const sql = db();
  const email = `dup.${Date.now()}.${tag()}@example.test`;
  try {
    const admin = await mkAdmin(sql);
    // the first form, from a Google result on a landing page
    const mk = async (msg: string, src: object | null) => {
      const [r] = await sql`select public.submit_lead(${sql.json({ kind: 'contact', name: 'Dana Twice', email, message: msg })}, null) r`;
      const id = (r!.r as { lead_id: string }).lead_id;
      if (src) await sql`select public.server_contact_source_set(p_lead => ${id}, p => ${sql.json(src as never)})`;
      return id;
    };
    const first = await mk('Do you deliver to Mississauga?', { first: { ref: 'www.google.com/', landing: '/car-rental/mississauga', at: new Date().toISOString() } });
    const second = await mk('Also, is a child seat possible?', null);
    expect((await sql`select merged_into from leads where id = ${second}`)[0]!.merged_into).toBe(first);
    // handled, then the person writes again: a new lead, offered for a merge
    await sql`update leads set handled_at = now(), handled_by = ${admin.id} where id = ${first}`;
    const third = await mk('One more question about the deposit.', { first: { ref: 'chatgpt.com/', landing: '/requirements', utm: { source: 'chatgpt.com' } } });
    expect((await sql`select merged_into from leads where id = ${third}`)[0]!.merged_into).toBeNull();

    const p = await (await browser.newContext({ viewport: page.viewportSize()!, baseURL: test.info().project.use.baseURL })).newPage();
    await signIn(p, admin.email, '/admin');
    await p.goto(`/admin/sales-leads/${first}`);
    const src = p.getByTestId('lead-traffic-card');
    await expect(src).toContainText('Google search');
    await expect(src).toContainText('/car-rental/mississauga');
    await expect(p.getByTestId('lead-merged')).toContainText('Also, is a child seat possible?');
    await expect(p.getByTestId('lead-merged')).toContainText('merged automatically');
    await expect(p.getByTestId('lead-duplicates')).toContainText('same email');
    await noOverflow(p);
    // the newer lead's page: ChatGPT, and one click merges it into the older lead
    await p.goto(`/admin/sales-leads/${third}`);
    await expect(p.getByTestId('lead-traffic-card')).toContainText('ChatGPT');
    await expect(p.getByTestId('lead-traffic-card')).toContainText('/requirements');
    await p.getByTestId('lead-merge').click();
    await p.waitForURL((u) => u.pathname.endsWith(first), { timeout: 20_000 });
    await expect(p.getByTestId('lead-merged')).toContainText('One more question about the deposit.');
    await expect(p.getByTestId('lead-duplicates')).toHaveCount(0);
    expect((await sql`select merged_into from leads where id = ${third}`)[0]!.merged_into).toBe(first);
    // the merged lead's own address (an alert's link) opens the lead that was kept
    await p.goto(`/admin/sales-leads/${third}`);
    await p.waitForURL((u) => u.pathname.endsWith(first), { timeout: 60_000 });
    await expect(p.getByTestId('lead-page')).toHaveAttribute('data-lead', first);
    await noOverflow(p);
    await p.context().close();
  } finally { await sql.end(); }
});
