import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { db, noOverflow } from './helpers';

// r50 (migration 5040): the discount game is for signed-in people too. A signed-in renter sees it on a car page, taps once
// ("Get my code": the first name and email come from the account) and the code is tied to their account (My discounts, the
// rewards page); staff and admin see and play it, and their claim says "Staff can't use game codes: this is a preview of
// what visitors see" with no code made; no one signed in sees it inside a portal or on checkout and payment pages. Run at
// 375 and 1440.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const PRIZE10 = { key: 'pct10', percent_bps: 1000, weight: 25 };
// the first game on the first car page view, or after 3 seconds anywhere
const TIMING = { car_pages: 1, seconds: 3, exit: false, reshow_pages: 2, reshow_seconds: 60, per_visit: 3, per_day: 6 };

async function browserFor(browser: Browser, sql: Sql) {
  await sql`delete from app.rate_limit_hits where key like 'game-%'`;
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(),
    baseURL: test.info().project.use.baseURL, reducedMotion: 'no-preference' });
  await c.addCookies([{ name: 'cc_vid', value: randomUUID(), url: test.info().project.use.baseURL! }]);
  await c.addInitScript((t) => { try { localStorage.setItem('cc_games_e2e', '1'); localStorage.setItem('cc_games_e2e_cfg', JSON.stringify(t)); } catch { /* none */ } }, TIMING);
  return c.newPage();
}

async function person(sql: Sql, role: 'renter' | 'admin' | 'va', name: string) {
  const id = randomUUID(); const email = `r50.games.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash, email_confirmed_at) values (${id}, ${email}, ${hash(PW)}, now())`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, staff_type, va_function) values (${id}, 'va', 'sales')`;
  if (role === 'renter') await sql`insert into renters (user_id, legal_name, email, mobile, date_of_birth) values (${id}, ${name}, ${email}, '+14165550143', '1989-05-13') on conflict (user_id) do nothing`;
  return { id, email };
}

async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await b.isVisible().catch(() => false)) await b.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 20_000 });
}

/** An unrevealed wheel play of the account with a 10% prize (fixed so the claim is a code). The play carries the browser's own id (the cc_vid cookie) and the account. */
async function dealWheelForBrowser(sql: Sql, page: Page, userId: string) {
  const vid = (await page.context().cookies()).find((c) => c.name === 'cc_vid')!.value;
  await sql`insert into game_plays (visitor_id, game, prize, path, trigger, user_id, context) values (${vid}, 'wheel', ${sql.json(PRIZE10 as never)}, '/cars/toyota-corolla', 'pages', ${userId}, 'site')`;
}

async function playWheel(page: Page) {
  await expect(page.getByTestId('game')).toBeVisible({ timeout: 30_000 });
  await expect(page.getByTestId('game')).toHaveAttribute('data-game', 'wheel');
  await page.getByTestId('game-play').click();
  await page.getByTestId('game-action').click();
  await expect(page.getByRole('heading', { name: /You won/ })).toBeVisible({ timeout: 30_000 });
}

test.describe.configure({ mode: 'serial' });

test('a signed-in renter sees the game on the site, taps once, and the code is in their account', async ({ browser }) => {
  test.setTimeout(120_000);
  const sql = db();
  const me = await person(sql, 'renter', 'Rae Renter');
  const page = await browserFor(browser, sql);
  await signIn(page, me.email);
  await dealWheelForBrowser(sql, page, me.id);
  await page.goto('/cars/toyota-corolla', { waitUntil: 'load' });
  await playWheel(page);
  const card = page.getByTestId('game');
  // the account's name and email are already there: one tap
  await expect(card.getByLabel('First name', { exact: true })).toHaveValue('Rae');
  await expect(card.getByLabel('Email', { exact: true })).toHaveCount(0);
  await expect(card).toContainText(me.email);
  await noOverflow(page);
  await page.getByTestId('game-get-code').click();
  await expect(page.getByTestId('game-code')).toHaveText(/^WIN-[A-Z2-9]{4}-[A-Z2-9]{4}$/, { timeout: 30_000 });
  const code = (await page.getByTestId('game-code').innerText()).trim();
  await expect(page.getByTestId('game-in-account')).toBeVisible();
  const rows = await sql`select c.email, c.user_id, c.renter_id, r.user_id as renter_user, pc.code from game_claims c join promo_codes pc on pc.id = c.promo_code_id
                           left join renters r on r.id = c.renter_id where c.email = ${me.email}`;
  expect(rows).toHaveLength(1);
  expect(rows[0]).toMatchObject({ email: me.email, user_id: me.id, renter_user: me.id, code });
  // in their account: Rewards > Your discounts, and the database's list
  const mine = await sql`select d ->> 'code' as code, d ->> 'kind' as kind, d ->> 'status' as status from jsonb_array_elements(app.my_discounts(${me.id})) d`;
  expect(mine.map((d) => `${d.code}/${d.kind}/${d.status}`)).toContain(`${code}/game/open`);
  await page.goto('/account/rewards', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('my-discounts')).toContainText(code);
  // and the game does not come back at once for the account
  await page.goto('/cars/tesla-model-3', { waitUntil: 'load' });
  await page.waitForTimeout(4500);
  await expect(page.getByTestId('game')).toHaveCount(0);
  await page.context().close();
  await sql.end();
});

test('staff see and play the game, and their claim is a preview: no code', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  for (const role of ['admin', 'va'] as const) {
    const who = await person(sql, role, role === 'admin' ? 'Ada Admin' : 'Sal Sales');
    const page = await browserFor(browser, sql);
    await signIn(page, who.email);
    await dealWheelForBrowser(sql, page, who.id);
    const before = await sql`select (select count(*)::int from game_claims) as claims, (select count(*)::int from promo_codes where source = 'discount_game') as codes`;
    await page.goto('/cars/toyota-corolla', { waitUntil: 'load' });
    await playWheel(page);
    await page.getByTestId('game-get-code').click();
    await expect(page.getByRole('alert').filter({ hasText: "Staff can't use game codes: this is a preview of what visitors see." })).toBeVisible({ timeout: 20_000 });
    await expect(page.getByTestId('game-code')).toHaveCount(0);
    await noOverflow(page);
    const after = await sql`select (select count(*)::int from game_claims) as claims, (select count(*)::int from promo_codes where source = 'discount_game') as codes,
                                   (select count(*)::int from game_claims where email = ${who.email}) as mine`;
    expect(after[0]).toMatchObject({ claims: before[0]!.claims, codes: before[0]!.codes, mine: 0 });
    await page.context().close();
  }
  await sql.end();
});

test('nobody sees the game inside a portal or on checkout and payment pages', async ({ browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  const renter = await person(sql, 'renter', 'Pia Portal');
  const admin = await person(sql, 'admin', 'Abe Portal');
  const portals = ['/account', '/account/rewards', '/account/bookings', '/owner', '/investor', '/va', '/field', '/staff', '/checkout', '/pay/none', '/payment'];
  for (const [who, paths] of [[renter, portals], [admin, ['/admin', '/admin/settings/discount-games', ...portals.slice(0, 3)]]] as const) {
    const page = await browserFor(browser, sql);
    await signIn(page, who.email);
    await dealWheelForBrowser(sql, page, who.id);
    for (const p of paths) {
      await page.goto(p, { waitUntil: 'load' }).catch(() => undefined);
      await page.waitForTimeout(TIMING.seconds * 1000 + 1500);
      await expect(page.getByTestId('game'), p).toHaveCount(0);
      await expect(page.getByTestId('game-saved'), p).toHaveCount(0);
    }
    // the same browser, the same account: a public page does show it (the portals above were the only thing in the way)
    await page.goto('/cars/toyota-corolla', { waitUntil: 'load' });
    await expect(page.getByTestId('game')).toBeVisible({ timeout: 30_000 });
    await page.context().close();
  }
  await sql.end();
});
