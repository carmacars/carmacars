import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Migration 0174 end to end, at 375 and 1440: Sales staff work in person or remote on the same Sales dashboard. An Admin sets a
// rep remote in Settings > Staff and roles; the remote rep's To do shows Remote duties (touches against the minimum, today's
// checklist, cover and reply time), logs a touch by hand and saves an availability block; an in person rep sees no remote
// duties; the Admin's Sales page of the remote rep shows the duties and voids the touch. Every page is checked with axe and for
// overflow and long dashes.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function check(page: Page, where: string, scope?: string) {
  await noOverflow(page);
  let axe = new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']);
  if (scope) axe = axe.include(scope);
  const r = await axe.analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(await page.locator('body').innerText(), `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function mkUser(sql: Sql, role: 'admin' | 'va', name: string, va?: string) {
  const id = randomUUID(); const email = `swm.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${va!}, 0)`;
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
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
const benign = (e: string) => /Failed to load resource|favicon|the server responded/.test(e);

test('Sales work modes: an Admin sets a rep remote; remote duties, a touch, a block; in person sees none; the Admin voids a touch', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const phone = test.info().project.name.startsWith('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
  const admin = await mkUser(sql, 'admin', 'Ada Admin');
  const remote = await mkUser(sql, 'va', 'Rae Remote', 'sales');
  const inPerson = await mkUser(sql, 'va', 'Ian Inperson', 'sales');
  const [m0] = await sql`select sales_work_mode m from staff_profiles where user_id = ${remote.id}`;
  expect(m0!.m).toBe('in_person');

  // the Admin: Settings > Staff and roles, Sales staff: in person or remote
  const ap = await ctx(browser, phone);
  const aErr = watch(ap);
  await signIn(ap, admin.email, '/admin');
  await ap.goto('/admin/settings/staff', { waitUntil: 'networkidle' });
  const card = ap.getByTestId('sales-modes');
  await expect(card).toBeVisible({ timeout: 30_000 });
  await expect(card.getByTestId(`sales-mode-${remote.email}`)).toHaveText('In person');
  await check(ap, 'Staff and roles, Sales staff', '[data-testid="sales-modes"]');
  await card.getByTestId(`sales-mode-set-${remote.email}`).click();
  const form = ap.getByTestId(`sales-mode-set-${remote.email}-form`);
  await form.getByLabel('Works').selectOption('remote');
  await form.getByLabel(/^Reason/).fill('Works from abroad');
  await form.getByTestId(`sales-mode-set-${remote.email}-submit`).click();
  await expect(card.getByTestId(`sales-mode-${remote.email}`)).toHaveText('Remote', { timeout: 30_000 });
  const [m1] = await sql`select sp.sales_work_mode m, (select count(*)::int from audit_log a where a.action = 'staff_sales_mode_set' and a.entity_id = ${remote.id}) n
    from staff_profiles sp where sp.user_id = ${remote.id}`;
  expect([m1!.m, m1!.n]).toEqual(['remote', 1]);

  // the remote rep: To do with Remote duties; log a touch; save a block
  const rp = await ctx(browser, phone);
  const rErr = watch(rp);
  await signIn(rp, remote.email, '/va');
  await rp.goto('/va', { waitUntil: 'networkidle' });
  const duties = rp.getByTestId('remote-duties');
  await expect(duties).toBeVisible({ timeout: 30_000 });
  await expect(duties.getByTestId('remote-checklist').locator('li')).toHaveCount(4);
  await expect(duties.getByTestId('remote-touches')).toContainText('0 of 400 touches this month');
  await expect(rp.getByTestId('va-sales-mode')).toHaveText('Remote');
  await check(rp, 'remote To do');
  await duties.getByTestId('log-touch').click();
  const lf = rp.getByTestId('log-touch-form');
  await lf.getByLabel('Type').selectOption('repost');
  await lf.getByLabel(/^Link/).fill('https://www.facebook.com/marketplace/item/1234567');
  await lf.getByTestId('log-touch-submit').click();
  await expect(duties.getByTestId('remote-touches')).toContainText('1 of 400 touches this month', { timeout: 30_000 });
  await expect(duties.getByTestId('checklist-repost')).toHaveClass(/is-done/);
  const [t] = await sql`select id, kind, source, link from sales_touches where staff_id = ${remote.id}`;
  expect([t!.kind, t!.source, t!.link]).toEqual(['repost', 'manual', 'https://www.facebook.com/marketplace/item/1234567']);
  await duties.getByTestId('availability-add').click();
  await expect(duties.getByTestId('availability-row-0')).toBeVisible();
  await duties.getByTestId('availability-save').click();
  await expect(duties.getByTestId('availability')).toContainText('Saved', { timeout: 30_000 });
  const [blk] = await sql`select count(*)::int n from sales_availability where staff_id = ${remote.id}`;
  expect(blk!.n).toBe(1);
  await check(rp, 'remote To do after a touch and a block');
  await rp.goto('/va/my-sales', { waitUntil: 'networkidle' });
  await expect(rp.getByTestId('my-sales-hero')).toContainText('Remote: 1 of 400 touches this month');
  await check(rp, 'remote My sales');

  // the in person rep: no remote duties
  const ip = await ctx(browser, phone);
  const iErr = watch(ip);
  await signIn(ip, inPerson.email, '/va');
  await ip.goto('/va', { waitUntil: 'networkidle' });
  await expect(ip.getByTestId('va-sales-mode')).toHaveText('In person', { timeout: 30_000 });
  await expect(ip.getByTestId('remote-duties')).toHaveCount(0);
  await check(ip, 'in person To do');

  // the Admin: the remote rep's Sales page, the duties read-only, void the touch
  await ap.goto(`/admin/staff/${remote.id}/sales`, { waitUntil: 'networkidle' });
  const ad = ap.getByTestId('remote-duties');
  await expect(ad).toBeVisible({ timeout: 30_000 });
  await expect(ad.getByTestId('remote-blocks')).toBeVisible();
  await expect(ap.getByTestId('sales-mode-set')).toBeVisible();
  await ad.getByTestId('remote-touch-list').locator('summary').click();
  await ad.getByTestId(`void-touch-${t!.id as string}`).click();
  const vf = ap.getByTestId(`void-touch-${t!.id as string}-form`);
  await vf.getByLabel(/^Reason/).fill('Logged twice');
  await vf.getByTestId(`void-touch-${t!.id as string}-submit`).click();
  await expect(ap.getByTestId('remote-duties').getByTestId('remote-touches')).toContainText('0 of 400 touches this month', { timeout: 30_000 });
  const [v] = await sql`select void_reason from sales_touches where id = ${t!.id as string}`;
  expect(v!.void_reason).toBe('Logged twice');
  await check(ap, 'Admin Sales page, remote duties', '[data-testid="remote-duties"]');

  expect([...aErr, ...rErr, ...iErr].filter((e) => !benign(e))).toEqual([]);
  for (const p of [ap, rp, ip]) await p.context().close();
  await sql.end();
});
