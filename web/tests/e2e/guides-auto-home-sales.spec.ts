import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0059 end to end, at 375 and 1440: the guides publish every rewrite that passes the checks, over an Admin's
// draft too, and keep the old text (logged for the next run) when every attempt fails; Admin > Settings > Guides has
// nothing to review. Staff enter their own home address at their first sign-in (VA and field portal): Add a rental waits
// for it, the profile shows it. Every page is checked with axe, for overflow and for the copy rules.
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;

async function mkUser(sql: Sql, kind: 'admin' | 'va' | 'field', name: string, fn?: 'cs' | 'sales') {
  const id = randomUUID(); const email = `${kind}${fn ?? ''}.ga.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${kind})`;
  // a new staff member: no home address yet (their first sign-in)
  if (kind === 'va') await sql`insert into staff_profiles (user_id, staff_type, va_function, single_limit_cents) values (${id}, 'va', ${fn ?? 'cs'}, 500000)`;
  if (kind === 'field') await sql`insert into staff_profiles (user_id, staff_type, field_function) values (${id}, 'field', 'driver_detailer')`;
  return { id, email, name };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
function jobToken() {
  const env = readFileSync(path.join(process.cwd(), '.env.local'), 'utf8');
  return createHmac('sha256', /^LINK_SIGNING_KEY=(.*)$/m.exec(env)![1]!.trim()).update('carmacars-listing-worker-v1').digest('hex');
}

test('guides: a passing rewrite is published over an Admin\'s draft, a failing one keeps the old text, nothing to review', async ({ browser }) => {
  const sql = db();
  const published = await sql`select version from guides where portal = 'field'`;
  test.skip(!(published[0]?.version > 0), 'the field guide is not published on this database (npm run db:seed publishes the guides)');
  const admin = await mkUser(sql, 'admin', 'Ga Admin');
  const slugA = `ga-auto-${tag()}`; const slugB = `ga-kept-${tag()}`;
  const live = 'Open your jobs and press **Start the job now**.\n';
  const draft = 'My own draft, not published yet. Press **Start the job now**.\n';
  const [a] = await sql`insert into guide_sections (portal, kind, sort_order, slug, title, body_md, draft_version, published_title, published_md, published_html, published_hidden, published_version, published_at)
    values ('field', 'chapter', 991, ${slugA}, 'Ga auto chapter', ${draft}, 2, 'Ga auto chapter', ${live}, '<p>Old</p>', false, 1, now()) returning id`;
  const keptMd = 'Press **Ring the bell twice**.\n';
  const [b] = await sql`insert into guide_sections (portal, kind, sort_order, slug, title, body_md, draft_version, published_title, published_md, published_html, published_hidden, published_version, published_at)
    values ('field', 'chapter', 992, ${slugB}, 'Ga kept chapter', ${keptMd}, 1, 'Ga kept chapter', ${keptMd}, '<p>Bell</p>', false, 1, now()) returning id`;
  try {
    const page = await ctx(browser);
    const token = jobToken();
    const run = `e2e-${tag()}`;
    // 1. passes the checks: published at once, the Admin's draft goes into the history
    const r1 = await page.request.post('/api/jobs/guide-rewrite', { headers: { authorization: `Bearer ${token}` },
      data: { section_id: a!.id, run, reason: 'It names buttons the portals no longer show (Start the job now)', labels: ['Start'],
              facts: { portal: 'field', nav: [], screen_labels: ['Start'], missing: [{ label: 'Start the job now', closest: ['Start'] }] } } });
    expect(r1.ok()).toBe(true);
    expect((await r1.json()).result).toBe('updated');
    const [rowA] = await sql`select published_md, body_md, needs_review, suggestion_md from guide_sections where id = ${a!.id}`;
    expect(rowA!.published_md).toContain('**Start**');
    expect(rowA!.body_md).toBe(rowA!.published_md);
    expect(rowA!.suggestion_md).toBeNull();
    expect((await sql`select count(*)::int n from guide_section_versions where section_id = ${a!.id} and body_md = ${draft} and not published`)[0]!.n).toBe(1);
    // 2. fails every attempt (a button with no label to take its place): the old text stays, logged for the next run
    const r2 = await page.request.post('/api/jobs/guide-rewrite', { headers: { authorization: `Bearer ${token}` },
      data: { section_id: b!.id, run, reason: 'It names buttons the portals no longer show (Ring the bell twice)', labels: ['Start'],
              facts: { portal: 'field', nav: [], screen_labels: ['Start'], missing: [{ label: 'Ring the bell twice', closest: [] }] } } });
    const j2 = await r2.json();
    expect(j2.result).toBe('kept');
    expect(j2.attempts).toBe(3);
    const [rowB] = await sql`select published_md, needs_review, suggestion_md, auto_retry_at from guide_sections where id = ${b!.id}`;
    expect(rowB!.published_md).toBe(keptMd);
    expect(rowB!.suggestion_md).toBeNull();
    expect(rowB!.needs_review).toBe(false);
    expect(rowB!.auto_retry_at).not.toBeNull();
    // 3. Admin > Settings > Guides: nothing to review
    await signIn(page, admin.email, '/admin');
    await page.goto('/admin/settings/guides', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('guides').getByRole('columnheader', { name: 'To review' })).toHaveCount(0);
    await expect(page.getByTestId('guide-upkeep')).toContainText('There is nothing to review');
    await expect(page.getByTestId('guide-auto-field')).toContainText('Changed automatically on');
    await check(page, 'guides');
    await page.goto('/admin/settings/guides/field', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('guide-needs-review')).toHaveCount(0);
    await page.getByTestId(`guide-section-${slugA}`).click();
    await expect(page.getByTestId('guide-auto-panel')).toContainText('Changed automatically on');
    await expect(page.getByTestId('guide-review')).toHaveCount(0);
    await check(page, 'a section published over a draft');
    await page.context().close();
  } finally {
    await sql`delete from guide_sections where id in (${a!.id}, ${b!.id})`;
    await sql.end();
  }
});

test('home address: an assistant enters it at the first sign-in; Add a rental waits for it; the profile shows it', async ({ browser }) => {
  const sql = db();
  const va = await mkUser(sql, 'va', 'Ga Sales', 'sales');
  const page = await ctx(browser);
  await signIn(page, va.email, '/va');
  await page.goto('/va', { waitUntil: 'networkidle' });
  const card = page.getByTestId('home-address-card');
  await expect(card).toContainText('Welcome. First, your home address');
  await check(page, 'first sign-in, address asked');
  await page.goto('/va/bookings/new', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('rental-needs-address')).toBeVisible();
  await check(page, 'add a rental waits for the address');
  // a too short address is refused, a full one saved
  await card.getByTestId('home-address').fill('Manila');
  await card.getByTestId('home-postal').fill('1000');
  await card.getByTestId('home-address-save').click();
  await expect(card.getByRole('alert')).toContainText('full home address');
  await card.getByTestId('home-address').fill('12 Rizal Street, Quezon City, Philippines');
  await card.getByTestId('home-postal').fill('1100');
  await card.getByTestId('home-address-save').click();
  await expect(page.getByTestId('home-address-card')).toHaveCount(0, { timeout: 20_000 });
  await page.goto('/va/bookings/new', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('rental-needs-address')).toHaveCount(0);
  const [row] = await sql`select home_address, home_postal_code, home_address_set_by from staff_profiles where user_id = ${va.id}`;
  expect(row!.home_address).toBe('12 Rizal Street, Quezon City, Philippines');
  expect(row!.home_postal_code).toBe('1100');
  expect(row!.home_address_set_by).toBe(va.id);
  await page.goto('/va/profile', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('home-address-section').getByTestId('home-address')).toHaveValue('12 Rizal Street, Quezon City, Philippines');
  await expect(page.getByTestId('home-address-section').getByTestId('home-address-save')).toHaveText('Change my home address');
  await check(page, 'assistant profile');
  await page.context().close();
  await sql.end();
});

test('home address: field staff enter it at the first sign-in; Add a rental waits for it', async ({ browser }) => {
  const sql = db();
  const field = await mkUser(sql, 'field', 'Ga Field');
  const page = await ctx(browser);
  await signIn(page, field.email, '/field');
  await page.goto('/field/rentals/new', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('rental-needs-address')).toBeVisible();
  await page.goto('/field/profile', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('home-address-above')).toBeVisible();
  const card = page.getByTestId('home-address-card');
  await expect(card).toBeVisible();
  await check(page, 'field profile, address asked');
  await card.getByTestId('home-address').fill('12 Queen Street West, Toronto');
  await card.getByTestId('home-postal').fill('M5H 2N2');
  await card.getByTestId('home-address-save').click();
  await expect(page.getByTestId('home-address-card')).toHaveCount(0, { timeout: 20_000 });
  await expect(page.getByTestId('home-address-section')).toBeVisible();
  await page.goto('/field/rentals/new', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('rental-needs-address')).toHaveCount(0);
  await check(page, 'field add a rental');
  expect((await sql`select home_postal_code from staff_profiles where user_id = ${field.id}`)[0]!.home_postal_code).toBe('M5H 2N2');
  await page.context().close();
  await sql.end();
});
