import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// 01 Motors' GoHighLevel (docs/changes/2026-10-24-01-motors-ghl.md, migration 0136), against the GoHighLevel stand-in
// (CRM_PROVIDER=fake, the default outside production): Settings > Partners > 01 Motors, connect with a token (a password
// field, never shown again: only its last four characters), Test connection and the first sync, what they see (never a
// partner car), the partner price, Run sync now, the feed (no partner car) and the widget (the one page other sites may
// frame), at 375 and 1440 with axe. Run with one worker (the link is shared). Fictional people only.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function admin(sql: ReturnType<typeof db>) {
  const id = randomUUID(); const email = `admin.crm.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Casey Admin')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return email;
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 120_000 });
}

test('Settings > Partners > 01 Motors: connect, test, sync, what they see (no partner car), the price, the feed and the widget', async ({ page }) => {
  test.setTimeout(600_000);
  const errors = watch(page);
  const sql = db();
  const token = `pit-e2e${tag()}-1111-4222-8333-${randomBytes(6).toString('hex')}`;
  // one real (not sample) program owner's car on the site, so there is something to share; 01 Motors' 62 cars are on the site too
  const [car] = await sql`select v.id, v.car_code from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.supply_type = 'program_owner' and v.is_sample and l.status = 'published' order by v.make limit 1` as unknown as [{ id: string; car_code: string }];
  const [{ partner_id: partnerId }] = await sql`select id partner_id from partners where business_name = '01 Motors'` as unknown as [{ partner_id: string }];
  const partnerCodes = (await sql`select car_code from vehicles where supply_type = 'partner' and car_code is not null` as unknown as Array<{ car_code: string }>).map((r) => r.car_code);
  // other tests in this job may have published real cars of their own: they are made samples for this test (put back
  // after), so our one car is the only one shared
  const others = (await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id where l.status = 'published' and not v.is_sample and v.supply_type <> 'partner' and v.id <> ${car.id}` as unknown as Array<{ id: string }>).map((r) => r.id);
  try {
    if (others.length) await sql`update vehicles set is_sample = true where id = any(${others}::uuid[])`;
    await sql`update vehicles set is_sample = false where id = ${car.id}`;
    await sql`update partner_crm_connections set token_ref = null, token_store = null, token_hint = null, location_id = null, last_sync_at = null, last_sync_ok = null, last_error = null, failing_since = null,
              last_test_at = null, last_test = '{}', price_mode = 'site', price_adjust_bps = 0, enabled = true, running_since = null, detected_target = null where partner_id = ${partnerId}`;
    await sql`delete from partner_crm_records where connection_id in (select id from partner_crm_connections where partner_id = ${partnerId})`;
    await signIn(page, await admin(sql), '/admin/settings');

    await page.locator('a[href="/admin/settings/partners"]').first().click();
    await page.waitForURL('**/admin/settings/partners');
    await page.getByTestId('crm-partner-01-motors').click();
    await page.waitForURL(`**/admin/settings/partners/${partnerId}`);
    await expect(page.getByTestId('crm-status')).toContainText('Not connected');
    await expect(page.getByTestId('crm-sample')).toContainText(car.car_code);
    await expect(page.getByTestId('crm-shared-count')).toContainText('1 (0 CarmaCars, 1 program owners)');
    await expect(page.getByTestId('crm-test')).toBeDisabled();

    // connect: the token is a password field, cleared after sending, never on the page again
    await expect(page.getByTestId('crm-token')).toHaveAttribute('type', 'password');
    await page.getByTestId('crm-token').fill(token);
    await page.getByTestId('crm-location').fill('loc01motorsFAKE');
    await page.getByTestId('crm-connect').click();
    await expect(page.getByTestId('crm-connect-result')).toContainText('Test connection passed', { timeout: 60_000 });
    await expect(page.getByTestId('crm-connect-result')).toContainText('First sync done');
    await expect(page.getByTestId('crm-connect-result')).toContainText(`ending ${token.slice(-4)}`);
    await expect(page.getByTestId('crm-token')).toHaveValue('');
    await page.reload({ waitUntil: 'networkidle' });
    await expect(page.getByTestId('crm-status')).toContainText('Connected');
    await expect(page.getByTestId('crm-token-hint')).toContainText(`Ending ${token.slice(-4)}`);
    await expect(page.getByTestId('crm-last-test')).toContainText('Passed');
    await expect(page.getByTestId('crm-last-sync')).toContainText('Done');
    expect(await page.content()).not.toContain(token);
    const [row] = await sql`select token_hint, (to_jsonb(c)::text like ${'%' + token + '%'}) leaked from partner_crm_connections c where partner_id = ${partnerId}` as unknown as [{ token_hint: string; leaked: boolean }];
    expect([row.token_hint, row.leaked]).toEqual([token.slice(-4), false]);
    // the first sync put our one car in their CRM, never a partner car
    const recs = await sql`select v.supply_type from partner_crm_records r join partner_crm_connections c on c.id = r.connection_id join vehicles v on v.id = r.vehicle_id where c.partner_id = ${partnerId}` as unknown as Array<{ supply_type: string }>;
    expect(recs.map((r) => r.supply_type)).toEqual(['program_owner']);

    // the partner price
    await page.getByTestId('crm-price').click();
    await page.getByTestId('crm-price-form').getByLabel('They see').selectOption('percent');
    await page.getByTestId('crm-price-form').getByLabel(/Adjustment/).fill('-10');
    await page.getByTestId('crm-price-submit').click();
    await expect(page.getByTestId('crm-price-rule')).toContainText('less 10%', { timeout: 30_000 });

    // Run sync now
    await page.getByTestId('crm-sync-now').click();
    await expect(page.getByTestId('crm-run-result')).toContainText('Sync done', { timeout: 60_000 });
    await expect(page.getByTestId('crm-run-result')).toContainText('1 cars shared');
    await axe(page, 'partner crm');

    // the feed and the widget
    const feedUrl = new URL(await page.getByTestId('crm-feed-json').inputValue());
    const feed = await page.request.get(feedUrl.pathname + feedUrl.search);
    expect(feed.status()).toBe(200);
    const body = await feed.json() as { count: number; cars: Array<{ car_code: string; daily_rate: number | null; book_url: string }> };
    expect(body.count).toBe(1);
    expect(body.cars.map((c) => c.car_code)).toEqual([car.car_code]);
    expect(body.cars.some((c) => partnerCodes.includes(c.car_code))).toBe(false);
    expect(body.cars[0]!.book_url).toMatch(/\/p\/01-motors\//);
    expect((await page.request.get(feedUrl.pathname + '?key=wrong&format=json')).status()).toBe(404);
    const csv = await page.request.get(feedUrl.pathname + feedUrl.search.replace('format=json', 'format=csv'));
    expect(await csv.text()).toMatch(/^car_code,name,year,/);
    const iframe = await page.getByTestId('crm-widget').inputValue();
    const widgetUrl = new URL(/src="([^"]+)"/.exec(iframe)![1]!);
    const widget = await page.request.get(widgetUrl.pathname + widgetUrl.search);
    expect(widget.status()).toBe(200);
    // the security headers come from the Worker entry (scripts/serve.mjs locally); `next dev` has none
    const served = !!(await page.request.get('/')).headers()['content-security-policy'];
    if (served) {
      expect(widget.headers()['content-security-policy']).toContain('frame-ancestors https:');
      expect(widget.headers()['x-frame-options']).toBeUndefined();
      expect((await page.request.get('/')).headers()['x-frame-options']).toBe('DENY');
    }
    const html = await widget.text();
    expect(html).toContain('Book on CarmaCars');
    expect(/<script/i.test(html)).toBe(false);
    // the booking link keeps the partner's code and opens the car
    const link = await page.request.get(new URL(body.cars[0]!.book_url).pathname, { maxRedirects: 0 });
    expect(link.status()).toBe(302);
    expect(link.headers()['set-cookie'] ?? '').toContain('cc-partner=01-motors');

    // disconnect: the token is gone
    await page.getByTestId('crm-disconnect').click();
    await page.getByTestId('crm-disconnect-submit').click();
    await expect(page.getByTestId('crm-status')).toContainText('Not connected', { timeout: 30_000 });
    expect(errors.filter((e) => !/favicon|Failed to load resource.*404/.test(e))).toEqual([]);
  } finally {
    await sql`update vehicles set is_sample = true where id = ${car.id}`;
    if (others.length) await sql`update vehicles set is_sample = false where id = any(${others}::uuid[])`;
    await sql`update partner_crm_connections set price_mode = 'site', price_adjust_bps = 0, enabled = true where partner_id = ${partnerId}`;
    await sql.end();
  }
});
