import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow } from './helpers';

// Fewer pages (r27, docs/changes/2026-11-05-fewer-pages.md), at 375 and 1440: the admin menu's 20 links in seven groups,
// every merged page and each of its tabs (axe, no overflow, the tab row with the current tab), every old address
// redirecting to its tab with its query, the Settings page's sections, anchors and search, and the staff Finance Money link
// with its tabs. Every page is checked with axe and for overflow.
const SHOTS = 'test-results/fewer-pages';
const PW = 'correct horse battery';
mkdirSync(SHOTS, { recursive: true });
type Sql = ReturnType<typeof db>;

const phone = () => test.info().project.name.includes('phone');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function mkUser(sql: Sql, kind: 'admin' | 'finance' | 'cs' | 'fleet', name: string) {
  const id = randomUUID(); const email = `${kind}.fp.${Date.now()}.${randomBytes(3).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  else {
    await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
    await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${kind}, 0)`;
  }
  return { id, email };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
}
/** The tab row: its group's name and the current tab. */
async function tabRow(page: Page, group: string, tab: string) {
  const bar = page.getByTestId('hub-bar');
  await expect(bar).toHaveAttribute('aria-label', group);
  await expect(bar.locator('a[aria-current="page"]')).toHaveText(tab);
}

const MERGED: Array<[string, string, Array<[string, string]>]> = [
  ['/admin/money', 'Payments', [['day', 'By day'], ['payments', 'All payments'], ['refunds', 'Refunds'], ['deposits', 'Deposits'], ['disputes', 'Disputes'], ['reconciliation', 'Reconciliation']]],
  ['/admin/owner-money', 'Owner money', [['invoices', 'Invoices'], ['debits', 'Debits'], ['statements', 'Statements'], ['payouts', 'Payouts']]],
  ['/admin/insurers', 'Insurers', [['rates', 'Rates'], ['invoices', 'Invoices']]],
  ['/admin/damages', 'Damage and claims', [['damage', 'Damage'], ['incidents', 'Incidents'], ['claims', 'Claims']]],
  ['/admin/logs', 'Logs', [['emails', 'Emails'], ['blocked', 'Blocked addresses'], ['changes', 'Changes'], ['access', 'Data access']]],
  ['/admin/renters', 'Renters', [['renters', 'Renters'], ['leads', 'Leads']]]
];
// old address, where it goes (path and query)
const MOVED: Array<[string, string]> = [
  ['/admin/payments?from=2026-10-01&to=2026-10-02', '/admin/money?tab=day&from=2026-10-01&to=2026-10-02'],
  ['/admin/reconciliation', '/admin/money?tab=reconciliation'],
  ['/admin/invoices?status=paid', '/admin/owner-money?tab=invoices&status=paid'],
  ['/admin/debits', '/admin/owner-money?tab=debits'],
  ['/admin/statements?status=draft', '/admin/owner-money?tab=statements&status=draft'],
  ['/admin/payouts', '/admin/owner-money?tab=payouts'],
  ['/admin/insurer-invoices?status=sent', '/admin/insurers?tab=invoices&status=sent'],
  ['/admin/incidents', '/admin/damages?tab=incidents'],
  ['/admin/incidents?tab=claims', '/admin/damages?tab=claims'],
  ['/admin/messages?status=failed', '/admin/logs?tab=emails&status=failed'],
  ['/admin/messages?tab=suppressions', '/admin/logs?tab=blocked'],
  ['/admin/audit?q=bookings', '/admin/logs?tab=changes&q=bookings'],
  ['/admin/audit?tab=access', '/admin/logs?tab=access'],
  ['/admin/leads?status=unused', '/admin/renters?tab=leads&status=unused']
];

test.describe.configure({ mode: 'serial' });

test('admin: 20 menu links, the merged pages and their tabs, the old addresses, Settings in sections', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Fp Admin');
  const ctx = await browser.newContext({ viewport: phone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone(), baseURL: test.info().project.use.baseURL });
  const page = await ctx.newPage();
  await signIn(page, admin.email, '/admin');

  // the menu (r27, second cut): seven groups, 20 links; Cars, People, Marketing, Money and Settings are one link each
  await page.goto('/admin/owner-money', { waitUntil: 'networkidle' });
  const nav = page.getByTestId('admin-nav');
  if (phone()) await page.getByTestId('nav-menu').click();
  for (const g of ['today', 'bookings']) {
    const head = nav.getByTestId(`nav-group-${g}`);
    if ((await head.getAttribute('aria-expanded')) !== 'true') await head.click();
  }
  // 20 since r27 (other branches may shorten Today and Bookings further, never lengthen them)
  expect(await nav.locator('.gn__links a, a.gn__single').count()).toBeLessThanOrEqual(20);
  for (const l of ['Cars', 'People', 'Marketing', 'Money', 'Settings', 'Damage and claims', 'Reviews'])
    await expect(nav.getByRole('link', { name: new RegExp(`^${l}\\s*\\d*$`) })).toHaveCount(1);
  // Money is current on Owner money; the rows on top: Money's pages, then Owner money's tabs
  await expect(nav.locator('a[aria-current="page"]')).toHaveText(/^Money/);
  await expect(page.getByTestId('section-bar')).toHaveAttribute('aria-label', 'Money');
  await expect(page.getByTestId('section-bar').locator('a[aria-current="true"]')).toHaveText(/^Owner money/);
  for (const gone of ['Owner invoices', 'Owner debits', 'Payments by day', 'Insurer invoices', 'Email log', 'Audit log', 'All settings', 'Renter leads', 'Vehicles', 'Owners', 'Applications']) await expect(nav.getByRole('link', { name: gone, exact: true })).toHaveCount(0);
  await page.screenshot({ path: `${SHOTS}/${test.info().project.name}-menu.png`, fullPage: !phone() });
  if (phone()) await page.getByTestId('nav-menu').click();

  // every merged page, each tab: its own address, the tab row with the current tab, axe and no overflow
  for (const [path, group, tabs] of MERGED) {
    for (const [i, [key, label]] of tabs.entries()) {
      const res = await page.goto(`${path}?tab=${key}`, { waitUntil: 'networkidle' });
      expect(res?.status(), `${path}?tab=${key}`).toBe(200);
      await tabRow(page, group, label);
      await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
      // the revamped look (features/admin/revamp): on every page of the group
      await expect(page.locator('[data-revamp]')).toHaveCount(1);
      await check(page, `${path}?tab=${key}`);
      if (i === 0) {
        await page.screenshot({ path: `${SHOTS}/${test.info().project.name}-${group.toLowerCase().replace(/\W+/g, '-')}.png`, fullPage: true });
        // the address alone opens the first tab
        await page.goto(path, { waitUntil: 'networkidle' });
        await tabRow(page, group, label);
      }
    }
  }
  // a tab of the row goes to its tab
  await page.goto('/admin/owner-money', { waitUntil: 'networkidle' });
  await page.getByTestId('hub-bar').getByRole('link', { name: 'Payouts' }).click();
  await page.waitForURL(/\/admin\/owner-money\?tab=payouts/);
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Payouts');
  // a filter on a tab keeps the tab
  await page.getByRole('navigation', { name: 'Filter by status' }).getByRole('link', { name: 'Paid' }).click();
  await page.waitForURL((u) => u.searchParams.get('tab') === 'payouts' && u.searchParams.get('status') === 'paid');
  // a search on a tab keeps the tab
  await page.goto('/admin/logs?tab=changes', { waitUntil: 'networkidle' });
  await page.locator('#ad-q').fill('bookings');
  await page.locator('#ad-q').press('Enter');
  await page.waitForURL((u) => u.pathname === '/admin/logs' && u.searchParams.get('tab') === 'changes' && u.searchParams.get('q') === 'bookings');
  await tabRow(page, 'Logs', 'Changes');

  // pages other branches own keep their look
  await page.goto('/admin/bookings', { waitUntil: 'networkidle' });
  await expect(page.locator('[data-revamp]')).toHaveCount(0);
  // the old addresses: the page and the tab that now holds them, the query kept
  for (const [from, to] of MOVED) {
    await page.goto(from, { waitUntil: 'networkidle' });
    const want = new URL(to, 'http://x'); const got = new URL(page.url());
    expect(got.pathname, from).toBe(want.pathname);
    for (const [k, v] of want.searchParams) expect(got.searchParams.get(k), `${from}: ${k}`).toBe(v);
  }
  // detail pages keep their addresses and show no tab row
  const [inv] = await sql`select invoice_number from owner_invoices order by created_at desc limit 1`;
  if (inv) {
    await page.goto(`/admin/invoices/${encodeURIComponent(String(inv.invoice_number))}`, { waitUntil: 'networkidle' });
    expect(new URL(page.url()).pathname).toBe(`/admin/invoices/${encodeURIComponent(String(inv.invoice_number))}`);
    await expect(page.getByTestId('hub-bar')).toHaveCount(0);
  }

  // grouped pages keep their addresses and share a tab row
  // r27 consolidation: Company accounts and Staff pay are one Company group, Staff is Team, Ads and Channels are two groups
  for (const [path, group, tab] of [['/admin/expenses', 'Company', 'Expenses'], ['/admin/money/field-pay', 'Company', 'Field pay'], ['/admin/referral-partners', 'Partners', 'Referral partners'],
    ['/admin/owners?view=checklist', 'Owners', 'Paid and signed'], ['/admin/applications', 'Owners', 'Applications'], ['/admin/hiring', 'Team', 'Hiring'], ['/admin/similar-cars', 'Listings', 'Similar cars'],
    ['/admin/marketing/report', 'Channels', 'Bookings by channel'], ['/admin/marketing/social', 'Ads', 'Social drafts']] as const) {
    await page.goto(path, { waitUntil: 'networkidle' });
    await tabRow(page, group, tab);
    await check(page, path);
  }

  // Settings: six sections with anchors, a search that filters the cards, the logs and phone alerts on it
  await page.goto('/admin/settings', { waitUntil: 'networkidle' });
  const idx = page.getByTestId('settings-index');
  await expect(idx.locator('section')).toHaveCount(6);
  await expect(idx.getByRole('navigation', { name: 'Settings sections' }).getByRole('link')).toHaveCount(6);
  await expect(idx.locator('a[href="/admin/logs"]')).toBeVisible();
  await expect(idx.locator('a[href="/admin/alerts"]')).toBeVisible();
  await check(page, 'settings');
  await page.screenshot({ path: `${SHOTS}/${test.info().project.name}-settings.png`, fullPage: true });
  await page.getByTestId('settings-search').fill('review requests');
  await expect(idx.locator('section')).toHaveCount(1);
  await expect(page.getByTestId('settings-sec-messages')).toContainText('Reviews');
  await page.getByTestId('settings-search').fill('zzzz nothing');
  await expect(page.getByTestId('settings-none')).toBeVisible();
  await check(page, 'settings search');
  await ctx.close();
  await sql.end();
});

test('staff Finance: Money with Admin\'s tabs and Owner money, each at its own address; the old addresses redirect', async ({ browser }) => {
  test.setTimeout(120_000);
  const sql = db();
  const fin = await mkUser(sql, 'finance', 'Fp Finance');
  const ctx = await browser.newContext({ viewport: phone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone(), baseURL: test.info().project.use.baseURL });
  const page = await ctx.newPage();
  await signIn(page, fin.email, '/staff');
  await page.goto('/staff/money', { waitUntil: 'networkidle' });
  const nav = page.getByTestId('va-nav');
  if (phone()) await page.getByTestId('nav-menu').click();
  // the Finance group is always open, at most five links (r27 consolidation)
  await expect(nav.getByTestId('nav-group-finance')).toHaveAttribute('aria-expanded', 'true');
  await expect(nav.getByRole('link', { name: 'Money', exact: true })).toHaveAttribute('aria-current', 'page');
  for (const l of ['Owner money', 'Tolls and tickets', 'Turo trips', 'More finance', 'Bookings', 'Me']) await expect(nav.getByRole('link', { name: l, exact: true })).toHaveCount(1);
  await expect(nav.locator('.gn__links a, a.gn__single')).toHaveCount(8);
  if (phone()) await page.getByTestId('nav-menu').click();
  for (const [path, group, tab] of [['/staff/money', 'Money', 'To handle'], ['/staff/money?tab=day', 'Money', 'By day'], ['/staff/money?tab=payments', 'Money', 'All payments'], ['/staff/money?tab=refunds', 'Money', 'Refunds'],
    ['/staff/money?tab=deposits', 'Money', 'Deposits'], ['/staff/money?tab=reconciliation', 'Money', 'Reconciliation'], ['/staff/owner-money?tab=invoices', 'Owner money', 'Invoices'], ['/staff/owner-money?tab=statements', 'Owner money', 'Statements']] as const) {
    const res = await page.goto(path, { waitUntil: 'networkidle' });
    expect(res?.status(), path).toBe(200);
    await tabRow(page, group, tab);
    await expect(page.locator('[data-revamp]')).toHaveCount(1);
    await check(page, path);
  }
  await page.screenshot({ path: `${SHOTS}/${test.info().project.name}-staff-money.png`, fullPage: true });
  // the old addresses open their tabs, the dates kept; By day has the dark band and the quick ranges of Admin's
  await page.goto('/staff/payments?from=2026-10-01&to=2026-10-02', { waitUntil: 'networkidle' });
  expect(new URL(page.url()).searchParams.get('tab')).toBe('day');
  expect(new URL(page.url()).searchParams.get('from')).toBe('2026-10-01');
  await expect(page.locator('.rv .ad-tiles')).toBeVisible();
  await expect(page.getByTestId('quick-range')).toBeVisible();
  await page.goto('/staff/reconciliation', { waitUntil: 'networkidle' });
  expect(new URL(page.url()).searchParams.get('tab')).toBe('reconciliation');
  // the staff To do keeps its look (another branch's page)
  await page.goto('/staff', { waitUntil: 'networkidle' });
  await expect(page.locator('[data-revamp]')).toHaveCount(0);
  await ctx.close();
  await sql.end();
});

// the r27 audit: each role's own group is always open, its jobs one tap away; a page group shows only the role's tabs
for (const [fn, links, hub] of [['cs', 7, ['/staff/messages', 'Renters', 'Messages']], ['fleet', 8, ['/staff/checks', 'Checks', 'Daily checks']]] as const) {
  test(`staff ${fn}: a short menu, the role's group open, page groups with the role's tabs`, async ({ browser }) => {
    test.setTimeout(120_000);
    const sql = db();
    const u = await mkUser(sql, fn, `Fp ${fn}`);
    const ctx = await browser.newContext({ viewport: phone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone(), baseURL: test.info().project.use.baseURL });
    const page = await ctx.newPage();
    await signIn(page, u.email, '/staff');
    await page.goto(hub[0], { waitUntil: 'networkidle' });
    await tabRow(page, hub[1], hub[2]);
    await expect(page.locator('[data-revamp]')).toHaveCount(1);
    await check(page, hub[0]);
    const nav = page.getByTestId('va-nav');
    if (phone()) await page.getByTestId('nav-menu').click();
    await expect(nav.getByTestId(`nav-group-${fn}`)).toHaveAttribute('aria-expanded', 'true');
    await expect(nav.locator('.gn__links a, a.gn__single')).toHaveCount(links);
    await page.screenshot({ path: `${SHOTS}/${test.info().project.name}-staff-${fn}-menu.png`, fullPage: true });
    await ctx.close();
    await sql.end();
  });
}
