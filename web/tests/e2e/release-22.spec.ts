import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Release 22 end to end, at both widths: the renter's Rewards page (points, a follow on the click, a code from points,
// given back), Admin > Settings > Rewards (a way to earn turned off, an adjustment), the listing channels (the checklist and
// a feed with no partner car), the owner pipeline (Admin and Sales: a lead added and moved), and the Setup checklist.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const quiet = (errors: string[]) => errors.filter((x) => !/favicon|Failed to load resource|net::ERR/.test(x));

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text.match(/[–—]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(text, `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function mkUser(sql: Sql, role: 'admin' | 'va' | 'renter', va?: string) {
  const id = randomUUID(); const email = `r22.${role}.${Date.now()}.${tag()}@example.test`; const name = role === 'admin' ? 'Ada Admin' : role === 'renter' ? `Rhea Renter ${tag()}` : `Sam Sales ${tag()}`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${va!}, 50000)`;
  let renterId: string | null = null;
  if (role === 'renter') renterId = (await sql`insert into renters (user_id, legal_name, email, mobile) values (${id}, ${name}, ${email}, '6475550199') returning id`)[0]!.id as string;
  return { id, email, name, renterId };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 60_000 });
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}

test('rewards: the renter earns on a follow, makes a code from points and gives it back; Admin turns a way to earn off and adjusts', async ({ browser }, info) => {
  test.setTimeout(240_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  await sql`update site_settings set social_links = coalesce(social_links, '{}'::jsonb) || '{"instagram": "https://instagram.com/carmacars.ca"}'::jsonb where singleton`;
  await sql`update reward_actions set enabled = true where code in ('social_instagram', 'review_google')`;
  const renter = await mkUser(sql, 'renter');
  await sql`select app.rewards_account(${renter.renterId})`;
  await sql`insert into reward_ledger (renter_id, points, kind, action, source_key, reason) values (${renter.renterId}, 1200, 'adjust', 'adjust', ${'adjust:e2e:' + renter.renterId}, 'Welcome points')`;

  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, renter.email, '/account');
  await page.goto('/account/rewards', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('rewards-balance')).toContainText('1,200 points');
  await expect(page.getByTestId('rewards-balance')).toContainText('$12.00');
  await expect(page.getByTestId('rewards-referral')).toContainText('/r/R');
  await check(page, 'rewards');
  // a follow: the points come on the click (it opens a new tab to the platform; the request is enough)
  const res = await page.request.get('/account/rewards/follow/instagram', { maxRedirects: 0 });
  expect(res.status()).toBe(302);
  expect(res.headers()['location']).toContain('instagram.com');
  await page.reload({ waitUntil: 'networkidle' });
  await expect(page.getByTestId('rewards-balance')).toContainText('1,250 points');
  await expect(page.getByTestId('rewards-follow-instagram')).toContainText('points added');
  // a code from 500 points, then given back
  await page.getByTestId('rewards-redeem').getByLabel('Points to use').selectOption('500');
  await page.getByRole('button', { name: 'Get my code' }).click();
  await expect(page.getByTestId('rewards-code-new')).toContainText('$5.00 off');
  await page.reload({ waitUntil: 'networkidle' });
  await expect(page.getByTestId('rewards-balance')).toContainText('750 points');
  await expect(page.getByTestId('rewards-codes')).toContainText('PTS');
  await page.getByRole('button', { name: 'Give back for points' }).first().click();
  await expect(page.getByTestId('rewards-balance')).toContainText('1,250 points');
  await expect(page.getByTestId('rewards-history')).toContainText('Followed CarmaCars on Instagram');
  await check(page, 'rewards after');
  expect(quiet(errors)).toEqual([]);

  // ---- Admin
  const admin = await mkUser(sql, 'admin');
  const ap = await ctx(browser, phone);
  const aerr = watch(ap);
  await signIn(ap, admin.email, '/admin');
  await ap.goto('/admin/settings/rewards', { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('rw-settings')).toContainText('On');
  await check(ap, 'admin rewards');
  await ap.getByTestId('rw-action-review_google').click();
  await ap.getByRole('dialog').getByLabel('On', { exact: true }).uncheck();
  await ap.getByTestId('rw-action-review_google-submit').click();
  await expect(ap.getByTestId('rw-actions').locator('tr', { hasText: 'Review us on Google' })).toContainText('Off', { timeout: 30_000 });
  await ap.goto(`/admin/settings/rewards?renter=${renter.renterId}`, { waitUntil: 'networkidle' });
  await ap.getByTestId('rw-adjust').click();
  await ap.getByRole('dialog').getByLabel(/^Points/).fill('25');
  await ap.getByRole('dialog').getByLabel(/^Reason/).fill('Sorry for the wait at pickup');
  await ap.getByTestId('rw-adjust-submit').click();
  await expect(ap.getByRole('dialog')).toHaveCount(0, { timeout: 30_000 });
  await expect(ap.getByTestId('rw-renter')).toContainText('1,275 points', { timeout: 30_000 });
  await check(ap, 'admin rewards renter');
  await sql`update reward_actions set enabled = true where code = 'review_google'`;
  // the setup checklist names Apple Wallet while it is not set up
  await ap.goto('/admin/settings', { waitUntil: 'networkidle' });
  await expect(ap.getByText('Setup checklist')).toBeVisible();
  await expect(ap.locator('main')).toContainText('Apple Pass Type ID');
  expect(quiet(aerr)).toEqual([]);
  await sql.end();
});

test('listing channels: the checklist, a channel updated, the feeds never carry a partner car; a car kept out', async ({ browser, request }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  await sql`update listing_channels set feed_enabled = true where slug in ('meta_catalog', 'google_vehicle_ads')`;
  await sql`delete from listing_channel_feed_stats where true`;
  const admin = await mkUser(sql, 'admin');
  const ap = await ctx(browser, phone);
  const errors = watch(ap);
  await signIn(ap, admin.email, '/admin');
  await ap.goto('/admin/marketing/channels', { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('channels')).toContainText('Turo');
  await expect(ap.getByTestId('channels')).toContainText('Kijiji');
  await check(ap, 'channels');
  await ap.getByTestId('channel-kijiji').click();
  await ap.getByRole('dialog').getByLabel('Status').selectOption('applied');
  await ap.getByRole('dialog').getByLabel('Who holds the login').fill('Sales desk');
  await ap.getByTestId('channel-kijiji-submit').click();
  await expect(ap.getByTestId('channels').locator('tr', { hasText: 'Kijiji' })).toContainText('Applied', { timeout: 30_000 });
  expect(quiet(errors)).toEqual([]);

  const token = (await sql`select feed_token from listing_channels where slug = 'meta_catalog'`)[0]!.feed_token as string;
  const json = await request.get(`/api/feeds/${token}?format=json`);
  expect(json.status()).toBe(200);
  const body = await json.json() as { cars: Array<{ id: string; link: string }> };
  const partnerCodes = (await sql`select coalesce(car_code, id::text) c from vehicles where supply_type = 'partner' or partner_id is not null`).map((r) => String(r.c));
  expect(body.cars.filter((c) => partnerCodes.includes(c.id))).toEqual([]);
  if (body.cars.length) expect(body.cars[0]!.link).toContain('utm_source=meta_catalog');
  const xml = await request.get(`/api/feeds/${token}?format=xml`);
  expect(xml.headers()['content-type']).toContain('xml');
  expect(await xml.text()).toContain('xmlns:g="http://base.google.com/ns/1.0"');
  const csv = await request.get(`/api/feeds/${token}?format=csv`);
  expect((await csv.text()).split('\r\n')[0]).toContain('daily_rate_cad');
  expect((await request.get(`/api/feeds/${randomUUID()}?format=json`)).status()).toBe(404);
  await sql.end();
});

test('owner pipeline: Admin adds a lead and moves it; Sales sees the board; the follow-up is queued', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const sales = await mkUser(sql, 'va', 'sales');
  const who = `Olive Owner ${tag()}`;
  const ap = await ctx(browser, phone);
  const errors = watch(ap);
  await signIn(ap, admin.email, '/admin');
  await ap.goto('/admin/marketing/owner-pipeline', { waitUntil: 'networkidle' });
  await check(ap, 'owner pipeline');
  await ap.getByTestId('op-add').click();
  const dlg = ap.getByRole('dialog');
  await dlg.getByLabel('Name', { exact: true }).fill(who);
  await dlg.getByLabel('Email', { exact: true }).fill(`${tag()}.olive@example.test`);
  await dlg.getByLabel('The car (for example 2021 Honda Civic)').fill('2022 Toyota RAV4');
  await ap.getByTestId('op-add-submit').click();
  const card = ap.getByTestId('op-col-new').getByTestId('op-lead').filter({ hasText: who });
  await expect(ap.getByRole('dialog')).toHaveCount(0, { timeout: 30_000 });
  await expect(card).toContainText('Follow-up 1 of 4', { timeout: 30_000 });
  await sql`select app.job_owner_pipeline()`;
  const sent = await sql`select count(*)::int n from notification_outbox o join leads l on l.id = o.entity_id where l.name = ${who} and o.code = 'owner_recruit_outreach'`;
  expect(sent[0]!.n).toBe(1);
  await ap.reload({ waitUntil: 'networkidle' });
  await ap.getByTestId('op-col-new').getByTestId('op-lead').filter({ hasText: who }).getByRole('button', { name: 'Move' }).click();
  await ap.getByRole('dialog').getByLabel('Stage').selectOption('call_booked');
  await ap.getByRole('dialog').getByRole('button', { name: 'Move' }).click();
  await expect(ap.getByTestId('op-col-call_booked').getByTestId('op-lead').filter({ hasText: who })).toContainText('Follow-ups stopped', { timeout: 30_000 });
  await check(ap, 'owner pipeline moved');
  expect(quiet(errors)).toEqual([]);

  const sp = await ctx(browser, phone);
  const serr = watch(sp);
  await signIn(sp, sales.email, '/staff');
  await sp.goto('/staff/owner-pipeline', { waitUntil: 'networkidle' });
  await expect(sp.getByTestId('op-col-call_booked')).toContainText(who);
  await expect(sp.getByTestId('op-credits')).toHaveCount(0);
  await check(sp, 'staff owner pipeline');
  expect(quiet(serr)).toEqual([]);
  await sql.end();
});
