import { expect, test } from '@playwright/test';
import { acceptCookies, db, watch } from './helpers';

// Public forms are rate limited per address (submit_lead, 0022); the tests share one address.
test.beforeEach(async () => { const sql = db(); await sql`delete from app.rate_limit_hits`; await sql.end(); });

test('cookie banner: shown first, choice stored in the database, not shown again', async ({ page, context }) => {
  await context.clearCookies();
  await page.goto('/faq');
  const banner = page.getByRole('region', { name: 'Cookies on CarmaCars' }).or(page.locator('section.cookie'));
  await expect(banner.first()).toBeVisible();
  await page.getByRole('button', { name: 'Accept all' }).click();
  await expect(page.locator('section.cookie')).toHaveCount(0);
  const vid = (await context.cookies()).find((c) => c.name === 'cc_vid')?.value;
  expect(vid).toBeTruthy();
  await page.waitForTimeout(800);
  const sql = db();
  const r = await sql`select choice, analytics from cookie_consents where visitor_id = ${vid!} order by recorded_at desc limit 1`;
  await sql.end();
  expect(r[0]?.choice).toBe('accept_all');
  expect(r[0]?.analytics).toBe(true);
  await page.goto('/delivery');
  await expect(page.locator('section.cookie')).toHaveCount(0);
  // the footer reopens the preferences
  await page.getByRole('button', { name: 'Cookie choices' }).click();
  await expect(page.getByRole('dialog', { name: 'Cookies on CarmaCars' })).toBeVisible();
});

test('cookie notice: Ontario gets a notice with analytics on and can opt out; Quebec is asked first', async ({ page, context, baseURL }) => {
  const host = new URL(baseURL ?? 'http://localhost:3000').hostname;
  await context.clearCookies();
  await context.addCookies([{ name: 'cc_geo', value: 'CA-ON', domain: host, path: '/' }]);
  await page.goto('/faq');
  await expect(page.getByTestId('cookie-notice')).toBeVisible();
  await expect(page.getByTestId('cookie-banner')).toHaveCount(0);
  let choice = (await context.cookies()).find((c) => c.name === 'cc_cookie_choice')?.value ?? '';
  expect(decodeURIComponent(choice)).toContain('"analytics":true');
  await page.waitForTimeout(800);
  const vid = (await context.cookies()).find((c) => c.name === 'cc_vid')?.value;
  const sql = db();
  const r = await sql`select choice, analytics, region from cookie_consents where visitor_id = ${vid!} order by recorded_at desc limit 1`;
  expect(r[0]?.choice).toBe('implied');
  expect(r[0]?.region).toBe('CA-ON');
  await page.getByTestId('cookie-optout').click();
  choice = (await context.cookies()).find((c) => c.name === 'cc_cookie_choice')?.value ?? '';
  expect(decodeURIComponent(choice)).toContain('"analytics":false');
  await page.goto('/delivery');
  await expect(page.locator('section.cookie')).toHaveCount(0);

  await context.clearCookies();
  await context.addCookies([{ name: 'cc_geo', value: 'CA-QC', domain: host, path: '/' }]);
  await page.goto('/faq');
  await expect(page.getByTestId('cookie-banner')).toBeVisible();
  await expect(page.getByTestId('cookie-notice')).toHaveCount(0);
  expect((await context.cookies()).find((c) => c.name === 'cc_cookie_choice')).toBeUndefined();
  await sql.end();
});

test('fleet: dates ask the database which cars are free; filters and sort', async ({ page }) => {
  const errors = watch(page);
  const d = new Date(); d.setUTCDate(d.getUTCDate() + 20); const from = d.toISOString().slice(0, 10); d.setUTCDate(d.getUTCDate() + 2); const to = d.toISOString().slice(0, 10);
  await page.goto(`/cars?from=${from}&to=${to}&tf=10:00&tt=10:00`);
  await acceptCookies(page);
  await expect(page.locator('.fleet-results__head .d3')).toContainText('free');
  await expect(page.locator('#fleet-grid .car-card__price span').first()).toContainText('before HST');
  await page.locator('#fl-sort').selectOption('price-desc');
  // real cars always come before the sample cars (0104), whatever the sort; each group is sorted on its own
  const cards = await page.locator('#fleet-grid .car-card').evaluateAll((els) => els.map((e) => ({
    sample: !!e.querySelector('[data-testid="example-car-badge"]'),
    price: Number((e.querySelector('.car-card__price b')?.textContent ?? '').replace(/[^0-9.]/g, ''))
  })));
  const firstSample = cards.findIndex((c) => c.sample);
  if (firstSample >= 0) expect(cards.slice(firstSample).every((c) => c.sample)).toBe(true);
  for (const group of [cards.filter((c) => !c.sample), cards.filter((c) => c.sample)]) {
    const n = group.map((c) => c.price);
    expect([...n].sort((a, b) => b - a)).toEqual(n);
  }
  expect(errors).toEqual([]);
});

test('contact form sends a lead through submit_lead', async ({ page }) => {
  await page.goto('/contact?topic=dates');
  await acceptCookies(page);
  await expect(page.locator('#ct-topic')).toHaveValue('dates');
  const email = `contact.${Date.now()}@example.test`;
  await page.getByRole('button', { name: 'Send message' }).click();
  await expect(page.getByText('Enter your name.')).toBeVisible();
  await page.locator('#ct-name').fill('Casey Contact');
  await page.locator('#ct-email').fill(email);
  await page.locator('#ct-msg').fill('Is the Civic free next weekend?');
  await page.getByRole('button', { name: 'Send message' }).click();
  await expect(page.getByText('Message sent.')).toBeVisible();
  const sql = db();
  const r = await sql`select kind from leads where email = ${email}`;
  await sql.end();
  expect(r[0]?.kind).toBe('contact');
});

test('owner application with address lookup sends an owner_program lead', async ({ page }) => {
  await page.goto('/list-your-car#apply');
  await acceptCookies(page);
  const email = `owner.${Date.now()}@example.test`;
  await page.locator('#ow-name').fill('Olive Owner');
  await page.locator('#ow-phone').fill('416-555-0177');
  await page.locator('#ow-email').fill(email);
  await page.locator('#ow-addr').fill('yorkdale');
  await page.getByRole('option', { name: /Yorkdale/ }).click();
  await page.locator('#ow-year').fill('2021');
  await page.locator('#ow-make').fill('Honda');
  await page.locator('#ow-model').fill('Accord');
  await page.locator('#ow-own').selectOption('Financed');
  await page.locator('#ow-who').selectOption('Me, personally');
  await page.getByRole('button', { name: 'Send application' }).click();
  await expect(page.getByText('Application sent.')).toBeVisible();
  const sql = db();
  // the application's lead (the details typed are also kept as a contact capture of their own)
  const r = await sql`select kind, payload ->> 'car_address' a from leads where email = ${email} order by (kind = 'owner_program') desc, created_at desc`;
  await sql.end();
  expect(r[0]?.kind).toBe('owner_program');
  expect(r[0]?.a).toMatch(/Yorkdale/);
});

test('security headers and a nonce on every script', async ({ request, page }) => {
  const res = await request.get('/');
  const csp = res.headers()['content-security-policy'] ?? '';
  expect(csp).toMatch(/script-src 'self' 'nonce-[A-Za-z0-9+/=]+'/);
  expect(csp).not.toContain('unsafe-inline\' https'); // scripts never allow unsafe-inline
  expect(csp).toContain("frame-ancestors 'none'");
  expect(res.headers()['x-content-type-options']).toBe('nosniff');
  const html = await res.text();
  const nonce = csp.match(/'nonce-([^']+)'/)![1];
  const scripts = html.match(/<script\b[^>]*>/g) ?? [];
  expect(scripts.length).toBeGreaterThan(0);
  for (const s of scripts) if (!/type="application\/ld\+json"/.test(s)) expect(s).toContain(`nonce="${nonce}"`);
  await page.goto('/');
});
