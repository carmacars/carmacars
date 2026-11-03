import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow } from './helpers';

// Release 27 consolidation (docs/changes/2026-11-07-consolidation.md), at 375 and 1440 with axe: the one Visitors page
// (Live now, Chat, History) and the old Live chat addresses; the admin areas at five pages each with their actions as
// buttons and Ctrl+K reaching them; a Sales member's Visitors page, Marketplace and menu; and Call and Text through Quo
// (the composer sends through the local fake Quo line, src/integrations/phone/fake.ts, and the text and the call land in
// the person's conversation; off in Program settings, the buttons are the phone's own links). Every address example.test.
const SHOTS = 'test-results/consolidation';
const PW = 'correct horse battery';
mkdirSync(SHOTS, { recursive: true });
type Sql = ReturnType<typeof db>;
const phone = () => test.info().project.name.includes('phone');
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function mkUser(sql: Sql, kind: 'admin' | 'sales' | 'cs', name: string) {
  const id = randomUUID(); const email = `${kind}.cn.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  else {
    await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
    await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${kind}, 0)`;
  }
  return { id, email };
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: phone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone(), baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
}
async function openMenu(page: Page, nav: string) {
  if (phone()) await page.getByTestId(nav).getByTestId('nav-menu').click();
}

test.describe.configure({ mode: 'serial' });

test('Admin: one Visitors page with Live now, Chat and History; the old Live chat addresses land on Chat', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Cn Admin');
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await openMenu(page, 'admin-nav');
  const nav = page.getByTestId('admin-nav');
  await expect(nav.getByRole('link', { name: /^Visitors/ })).toBeAttached();
  await expect(nav.getByRole('link', { name: /^Live chat/ })).toHaveCount(0);
  if (phone()) await page.getByTestId('nav-menu').click();
  for (const [view, path] of [['live', '/admin/visitors'], ['chat', '/admin/visitors?view=chat'], ['history', '/admin/visitors?view=history']] as const) {
    const res = await page.goto(path, { waitUntil: 'networkidle' });
    expect(res?.status(), path).toBe(200);
    await expect(page.getByTestId(`vs-tab-${view}`)).toHaveAttribute('aria-current', 'page');
    await expect(page.getByRole('heading', { level: 1 })).toHaveText('Visitors');
    if (view === 'chat') { await expect(page.getByTestId('chat-inbox')).toBeVisible(); await expect(page.getByTestId('live-map')).toHaveCount(0); }
    else await expect(page.getByTestId('live-map')).toBeVisible();
    await check(page, `admin visitors ${view}`);
    await page.screenshot({ path: `${SHOTS}/${test.info().project.name}-admin-visitors-${view}.png`, fullPage: true });
  }
  // Texts and calls under Chat (the loop ends on History)
  await page.goto('/admin/visitors?view=chat', { waitUntil: 'networkidle' });
  await page.getByTestId('tab-phone').click();
  await page.waitForURL((u) => u.searchParams.get('view') === 'chat' && u.searchParams.get('inbox') === 'phone');
  await expect(page.getByTestId('phone-inbox')).toBeVisible();
  await check(page, 'admin visitors texts and calls');
  // the old addresses, the query kept
  for (const [from, want] of [['/admin/chat', { view: 'chat' }], ['/admin/chat?view=phone', { view: 'chat', inbox: 'phone' }], ['/admin/chat?id=00000000-0000-4000-8000-000000000000', { view: 'chat', id: '00000000-0000-4000-8000-000000000000' }],
    ['/admin/live', {}], ['/admin/live/history?device=phone', { view: 'history', device: 'phone' }]] as const) {
    await page.goto(from, { waitUntil: 'networkidle' });
    const u = new URL(page.url());
    expect(u.pathname, from).toBe('/admin/visitors');
    for (const [k, v] of Object.entries(want)) expect(u.searchParams.get(k), `${from} ${k}`).toBe(v);
  }
  await page.context().close();
  await sql.end();
});

test('Admin: each area at most five pages, actions are buttons, Ctrl+K finds every page, tab and action', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Cn Admin Two');
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  const rows: Array<[string, string, string[]]> = [
    ['/admin/applications', 'People', ['Owners', 'Partners', 'Renters', 'Team', 'Investors']],
    ['/admin/vehicles', 'Cars', ['Vehicles', 'Listings', 'Maintenance']],
    ['/admin/marketing/marketplace', 'Marketing', ['Marketplace', 'Ads', 'Channels', 'Owner recruitment']],
    ['/admin/money', 'Money', ['Payments', 'Owner money', 'Tolls and tickets', 'Company', 'Insurers']]
  ];
  for (const [path, area, items] of rows) {
    await page.goto(path, { waitUntil: 'networkidle' });
    const bar = page.getByTestId('section-bar');
    await expect(bar).toHaveAttribute('aria-label', area);
    const links = bar.locator('a');
    await expect(links).toHaveCount(items.length);
    for (const [i, l] of items.entries()) await expect(links.nth(i)).toHaveText(new RegExp(`^${l}`));
    await check(page, `${area} row`);
    await page.screenshot({ path: `${SHOTS}/${test.info().project.name}-area-${area.toLowerCase()}.png` });
  }
  // People > Owners: the four tabs; Add a car for an owner is a button on the page
  await page.goto('/admin/owners', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('hub-bar').locator('a')).toHaveText([/^Applications/, /^Owners/, /^Owner forms/, /^Paid and signed/]);
  await expect(page.getByTestId('add-car-for-owner')).toBeVisible();
  await page.getByTestId('add-car-for-owner').click();
  await page.waitForURL(/\/admin\/owners\/add-car/);
  await expect(page.getByTestId('section-bar').locator('a[aria-current]')).toHaveText(/^Owners/);
  // no in-page tab row repeats the area's rows (Marketing had three rows)
  await page.goto('/admin/marketing/social', { waitUntil: 'networkidle' });
  await expect(page.getByRole('navigation', { name: 'Marketing' })).toHaveCount(1);
  await expect(page.getByTestId('hub-bar')).toHaveAttribute('aria-label', 'Ads');
  // Ctrl+K: a tab of a group, an action and a Visitors tab
  if (!phone()) {
    for (const [q, href] of [['Add a car for', '/admin/owners/add-car'], ['Visitors: Chat', '/admin/visitors?view=chat'], ['Field pay', '/admin/money/field-pay'], ['Rates for many', '/admin/vehicles/bulk-rates']] as const) {
      await page.keyboard.press('Control+k');
      await page.getByTestId('admin-jump-input').fill(q);
      await page.keyboard.press('Enter');
      await page.waitForURL((u) => `${u.pathname}${u.search}` === href, { timeout: 15_000 });
    }
  }
  await page.context().close();
  await sql.end();
});

test('Sales: Visitors (the map, Live now, Chat, History), the Marketplace and a short menu', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const sales = await mkUser(sql, 'sales', 'Cn Sales');
  const page = await ctx(browser);
  await signIn(page, sales.email, '/staff');
  await page.goto('/staff/visitors', { waitUntil: 'networkidle' });
  const nav = page.getByTestId('va-nav');
  await openMenu(page, 'va-nav');
  const group = nav.getByTestId('nav-group-sales');
  await expect(group).toHaveAttribute('aria-expanded', 'true');
  for (const l of ['Requests and offers', 'Visitors', 'Marketplace', 'My sales', 'More sales']) await expect(nav.getByRole('link', { name: new RegExp(`^${l}`) })).toHaveCount(1);
  for (const gone of ['Live chat', 'Live visitors', 'Send an offer', 'New quote']) await expect(nav.getByRole('link', { name: gone, exact: true })).toHaveCount(0);
  await expect(nav.getByRole('link', { name: /^Visitors/ })).toHaveAttribute('aria-current', 'page');
  if (phone()) await page.getByTestId('nav-menu').click();
  for (const [view, path] of [['live', '/staff/visitors'], ['chat', '/staff/visitors?view=chat'], ['history', '/staff/visitors?view=history']] as const) {
    const res = await page.goto(path, { waitUntil: 'networkidle' });
    expect(res?.status(), path).toBe(200);
    await expect(page.getByTestId(`vs-tab-${view}`)).toHaveAttribute('aria-current', 'page');
    if (view !== 'chat') {
      await expect(page.getByTestId('live-map')).toBeVisible();
      // the staff map: no TV mode, no fleet layer
      await expect(page.getByRole('link', { name: 'Open TV mode' })).toHaveCount(0);
    }
    await check(page, `sales visitors ${view}`);
    await page.screenshot({ path: `${SHOTS}/${test.info().project.name}-sales-visitors-${view}.png`, fullPage: true });
  }
  const map = await page.request.get('/api/staff/live-map');
  expect(map.status()).toBe(200);
  expect((await map.json()).fleet ?? []).toEqual([]);
  // History rows open in the list; the visit's own page stays Admin's
  await page.goto('/staff/visitors?view=history', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('vh-open')).toHaveCount(0);
  // the old addresses
  await page.goto('/staff/live', { waitUntil: 'networkidle' });
  expect(new URL(page.url()).pathname).toBe('/staff/visitors');
  await page.goto('/staff/chat?view=phone', { waitUntil: 'networkidle' });
  expect(new URL(page.url()).searchParams.get('inbox')).toBe('phone');
  // the Marketplace is Sales's Marketing tab now (0510): the old address lands there, without Admin's settings
  await page.goto('/staff/marketplace', { waitUntil: 'networkidle' });
  expect(new URL(page.url()).pathname).toBe('/staff/marketing');
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Marketing');
  await expect(page.getByTestId('mp-settings')).toHaveCount(0);
  await expect(page.getByTestId('mk-inbox')).toBeVisible();
  await check(page, 'sales marketing');
  // the actions are buttons on Requests and offers
  await page.goto('/staff/requests', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('send-offer-link')).toBeVisible();
  await expect(page.getByTestId('new-quote-link')).toBeVisible();
  // customer service has no Marketplace
  const cs = await mkUser(sql, 'cs', 'Cn Cs');
  const p2 = await ctx(browser);
  await signIn(p2, cs.email, '/staff');
  const res = await p2.goto('/staff/marketplace', { waitUntil: 'networkidle' });
  expect(res?.status()).toBe(404);
  await p2.context().close();
  await page.context().close();
  await sql.end();
});

test('Call and Text through Quo: the composer sends from the CarmaCars number, the call is logged; off, the phone\'s own apps', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Cn Admin Three');
  const renterId = randomUUID();
  const mobile = `416555${String(Math.floor(1000 + Math.random() * 8999))}`;
  const e164 = `+1${mobile}`;
  await sql`insert into renters (id, legal_name, date_of_birth, mobile, email, identity_status) values (${renterId}, ${`Cn Rita ${tag()}`}, '1990-05-05', ${mobile}, ${`cn.rita.${tag()}@example.test`}, 'verified')`;
  await sql`update program_settings set phone_quo_buttons = true, phone_enabled = true`;
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/renters/${renterId}`, { waitUntil: 'networkidle' });
  // Text: the composer
  await page.getByTestId('renter-phone-text').click();
  const sheet = page.getByTestId('renter-phone-composer');
  await expect(sheet).toBeVisible();
  await expect(sheet).toContainText('from the CarmaCars number');
  await check(page, 'quo composer');
  await page.screenshot({ path: `${SHOTS}/${test.info().project.name}-quo-composer.png` });
  await page.getByTestId('quo-body').fill('Hi Rita, your car is ready at 10. CarmaCars');
  await page.getByTestId('quo-send').click();
  await expect(page.getByTestId('quo-sent')).toBeVisible({ timeout: 15_000 });
  const [sent] = await sql`select o.status, a.quo_id, a.sent_by from phone_outbox o join phone_threads t on t.id = o.thread_id left join phone_activity a on a.outbox_id = o.id
    where t.number = ${e164} and o.kind = 'staff' order by o.created_at desc limit 1`;
  expect(sent?.status).toBe('sent');
  expect(String(sent?.quo_id)).toMatch(/^ACfake/);
  expect(sent?.sent_by).toBe(admin.id);
  await page.getByRole('button', { name: 'Done' }).click();
  // Call: the Quo web app on a computer (stubbed here), the number copied, the call logged on the conversation
  await page.context().route('https://my.quo.com/**', (r) => r.fulfill({ status: 200, contentType: 'text/html', body: '<title>Quo</title>' }));
  const popup = page.context().waitForEvent('page');
  await page.getByTestId('renter-phone').click();
  await (await popup).close();
  await expect(page.getByTestId('renter-phone-call-sheet')).toBeVisible();
  await expect(page.getByTestId('quo-call-number')).toHaveText(/\(416\) 555-/);
  await check(page, 'quo call sheet');
  await expect.poll(async () => (await sql`select count(*)::int n from phone_activity a join phone_threads t on t.id = a.thread_id where t.number = ${e164} and a.kind = 'call' and a.status = 'dialed'`)[0]!.n).toBe(1);
  await page.keyboard.press('Escape');
  // off in Program settings: the phone's own links, no composer
  await sql`update program_settings set phone_quo_buttons = false`;
  try {
    await page.goto(`/admin/renters/${renterId}`, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('renter-phone-text')).toHaveAttribute('href', `sms:${e164}`);
    await page.evaluate(() => document.addEventListener('click', (e) => { if ((e.target as Element).closest('a[href^="sms:"], a[href^="tel:"]')) e.preventDefault(); }));
    await page.getByTestId('renter-phone-text').click();
    await expect(page.getByTestId('renter-phone-composer')).toHaveCount(0);
  } finally {
    await sql`update program_settings set phone_quo_buttons = true`;
  }
  await page.context().close();
  await sql.end();
});
