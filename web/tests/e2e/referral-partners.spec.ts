import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, pdfText, watch } from './helpers';

// Referral partners and the RentalCoverage affiliate (docs/changes/2026-10-25-referral-partners.md, migration 0164): a body shop
// signs up on the public page (a pending partner), an Admin approves it, the partner gets a short link with a 60-day cookie, a
// flyer PDF and a private page; Admin > Settings > RentalCoverage affiliate stays off until a link is pasted, then the Requirements
// page shows the disclosed link and a click is counted. Fictional people only. Run with one worker (one affiliate setting).
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function admin(sql: ReturnType<typeof db>) {
  const id = randomUUID(); const email = `admin.ref.${Date.now()}.${tag()}@example.test`;
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

test('a body shop signs up, an Admin approves it, the link, flyer and private page work', async ({ page, browser }) => {
  test.setTimeout(600_000);
  const errors = watch(page);
  const sql = db();
  const name = `Test Collision ${tag()}`;

  // the public page and its form, at phone and desktop width
  for (const w of [375, 1440]) {
    await page.setViewportSize({ width: w, height: 900 });
    await page.goto('/partners/body-shops', { waitUntil: 'networkidle' });
    await acceptCookies(page);
    await expect(page.getByTestId('partner-rate')).toBeVisible();
    await expect(page.getByTestId('partner-signup-form')).toBeVisible();
    await axe(page, `/partners/body-shops ${w}`);
  }
  await page.getByTestId('ps-business_name').fill(name);
  await page.getByTestId('ps-contact_name').fill('Jordan Example');
  await page.getByTestId('ps-phone').fill('416-555-0142');
  await page.getByTestId('ps-email').fill(`shop.${tag()}@example.test`);
  await page.getByTestId('ps-submit').click();
  await expect(page.getByTestId('partner-signup-sent')).toBeVisible({ timeout: 60_000 });
  const [row] = await sql`select id, status, kind, referral_code from referral_partners where business_name = ${name}`;
  expect(row?.status).toBe('pending');
  expect(row?.kind).toBe('body_shop');
  const id = row!.id as string; const code = row!.referral_code as string;

  // an unapproved code ties nothing: the short link sets no partner cookie
  const cold = await page.request.get(`/r/${code}`, { maxRedirects: 0 });
  expect((cold.headers()['set-cookie'] ?? '')).not.toContain('cc-ref=');

  // the Admin approves it
  const email = await admin(sql);
  await signIn(page, email, `/admin/referral-partners/${id}`);
  await expect(page.getByTestId('rp-summary')).toBeVisible({ timeout: 60_000 });
  await page.getByTestId('rp-approve').click();
  await expect.poll(async () => (await sql`select status from referral_partners where id = ${id}`)[0]?.status, { timeout: 60_000 }).toBe('active');
  await page.reload({ waitUntil: 'networkidle' });
  await expect(page.getByTestId('rp-short-link')).toHaveValue(new RegExp(`/r/${code}$`));
  await axe(page, 'admin partner page');

  // the short link now sets the cookie for about 60 days
  const warm = await page.request.get(`/r/${code}`, { maxRedirects: 0 });
  const cookie = warm.headers()['set-cookie'] ?? '';
  expect(cookie).toContain(`cc-ref=${code}`);
  expect(Number(/Max-Age=(\d+)/i.exec(cookie)?.[1] ?? 0)).toBeGreaterThanOrEqual(59 * 86400);

  // the flyer is a one-page PDF with the code on it
  const flyer = await page.request.get(`/admin/referral-partners/${id}/flyer`);
  expect(flyer.status()).toBe(200);
  expect(flyer.headers()['content-type']).toContain('application/pdf');
  const text = await pdfText(await flyer.body());
  expect(text).toContain(code);

  // the private page: only the partner's link opens it
  const portal = await page.getByTestId('rp-portal-link').inputValue();
  const ctx = await browser.newContext();
  const pp = await ctx.newPage();
  await pp.goto(portal, { waitUntil: 'networkidle' });
  await expect(pp.getByTestId('portal-code')).toHaveText(code);
  await expect(pp.getByTestId('portal-totals')).toBeVisible();
  const bad = await pp.goto(portal.replace(/[^/]+$/, 'x'.repeat(40)));
  expect(bad?.status()).toBe(404);
  await ctx.close();

  expect(errors.filter((e) => !/favicon|Failed to load resource/i.test(e))).toEqual([]);
  await sql.end();
});

test('the RentalCoverage link stays off until pasted, then shows with its disclosure and counts a click', async ({ page }) => {
  test.setTimeout(300_000);
  const sql = db();
  await sql`update coverage_affiliate set enabled = false, link_url = null, affiliate_id = null`;
  await page.goto('/requirements', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await expect(page.getByTestId('coverage-affiliate')).toHaveCount(0);
  const off = await page.request.get('/go/coverage?p=requirements', { maxRedirects: 0 });
  expect(off.headers()['location'] ?? '').toContain('/requirements');

  await sql`update coverage_affiliate set enabled = true, link_url = 'https://rentalcoverage.example.test/?aff={id}', affiliate_id = 'abc123'`;
  const before = Number((await sql`select count(*)::int as n from coverage_clicks`)[0]!.n);
  await page.goto('/requirements', { waitUntil: 'networkidle' });
  const note = page.getByTestId('coverage-affiliate');
  await expect(note).toBeVisible();
  await expect(note).toContainText('separate company');
  await expect(note).toContainText('may earn a commission');
  await expect(page.getByTestId('coverage-affiliate-link')).toHaveAttribute('rel', /sponsored/);
  await axe(page, '/requirements with the link');

  const go = await page.request.get('/go/coverage?p=requirements', { maxRedirects: 0 });
  const to = new URL(go.headers()['location']!);
  expect(to.host).toBe('rentalcoverage.example.test');
  expect(to.searchParams.get('aff')).toBe('abc123');
  expect(to.searchParams.get('utm_source')).toBe('carmacars');
  expect(to.searchParams.get('utm_campaign')).toBe('coverage_requirements');
  const after = await sql`select count(*)::int as n, count(*) filter (where placement = 'requirements')::int as r from coverage_clicks`;
  expect(Number(after[0]!.n)).toBe(before + 1);

  await sql`update coverage_affiliate set enabled = false, link_url = null, affiliate_id = null`;
  await sql.end();
});
