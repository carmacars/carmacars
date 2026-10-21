import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { db, noOverflow } from './helpers';

// Migrations 0069 and 0076 end to end, at 375 and 1440: each of the five games shows after one car page to a visitor
// who is not signed in, plays (the wheel turns, the card is scratched, a hand is played, the cups shuffle, the disc
// drops) and reveals the prize the database drew; the unlock form gives the code (and the email is queued); the code
// fills in the request form, takes the discount and goes on the booking request; a signed-in visitor never sees a game
// on the site; the Admin's Leads page and Settings > Discount games show the claim. 0076: the first game after 15
// seconds without a car page; on a phone visit from a search engine the small slide-in 15 seconds later; closed, a
// different game after 2 more car pages; the request-to-book form's card applies the code to that booking and the
// price changes; closing it leaves the booking as it was; a signed-in renter is offered it there. The card is checked
// with axe and for overflow.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const PRIZE10 = { key: 'pct10', percent_bps: 1000, weight: 25 };
const PRIZE50 = { key: 'amt50', amount_cents: 5000, min_days: 3, weight: 1 };

async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).include('[data-testid="game"]').withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}

/** A visitor whose browser id is known, with the game allowed in this automated browser and the prize set in advance
 *  (the database returns the visitor's open play instead of drawing a new one). */
async function visitor(browser: Browser, sql: Sql, game: string, prize: object, reduced = false) {
  const vid = randomUUID();
  await sql`delete from app.rate_limit_hits where key like 'game-%'`;
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(),
    baseURL: test.info().project.use.baseURL, reducedMotion: reduced ? 'reduce' : 'no-preference' });
  await c.addCookies([{ name: 'cc_vid', value: vid, url: test.info().project.use.baseURL! }]);
  await c.addInitScript(() => { try { localStorage.setItem('cc_games_e2e', '1'); } catch { /* none */ } });
  await sql`insert into game_plays (visitor_id, game, prize, path, trigger) values (${vid}, ${game}, ${sql.json(prize as never)}, '/cars/toyota-corolla', 'pages')`;
  const page = await c.newPage();
  if (process.env.GAME_DEBUG) page.on('response', async (r) => { if (/api\/(rpc|games)/.test(r.url())) console.log('RES', r.url(), r.status(), (await r.text().catch(() => '')).slice(0, 160)); });
  return { page, vid };
}

async function answerCookies(page: Page) {
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  await b.waitFor({ state: 'visible', timeout: 15_000 });
  await b.click();
  await page.waitForFunction(() => document.cookie.includes('cc_cookie_choice='));
}

/** One car page (0076): the game slides in once the cookie banner is answered, never over it. */
async function browseUntilGame(page: Page) {
  await page.goto('/cars/toyota-corolla', { waitUntil: 'load' });
  await page.waitForTimeout(1500);
  await expect(page.getByTestId('game')).toHaveCount(0);
  await answerCookies(page);
  await expect(page.getByTestId('game')).toBeVisible({ timeout: 30_000 });
}

/** A car page, once the watcher (loaded when the page is idle) has counted it. */
async function carPage(page: Page, slug: string) {
  await page.goto(`/cars/${slug}`, { waitUntil: 'load' });
  await page.waitForFunction((s) => (sessionStorage.getItem('cc_game_visit') ?? '').includes(`"${s}"`), slug, { timeout: 15_000 });
}

/** Plays whichever game is on screen to its prize. */
async function playAny(page: Page) {
  const game = (await page.getByTestId('game').getAttribute('data-game'))!;
  await page.getByTestId('game-play').click();
  await PLAY[game]!(page);
}

async function claim(page: Page, sql: Sql, email: string, label: string) {
  await expect(page.getByRole('heading', { name: `You won ${label}` })).toBeVisible({ timeout: 15_000 });
  await page.getByTestId('game-get-code').click();
  await expect(page.getByText('Enter your first name.')).toBeVisible();
  const g = page.getByTestId('game');
  await g.getByLabel('First name', { exact: true }).fill('Gia');
  await g.getByLabel('Email', { exact: true }).fill(email);
  await g.getByLabel(/Mobile/).fill(`647555${String(Math.floor(1000 + Math.random() * 8999))}`);
  await page.getByTestId('game-get-code').click();
  await expect(page.getByTestId('game-code')).toHaveText(/^WIN-[A-Z2-9]{4}-[A-Z2-9]{4}$/, { timeout: 30_000 });
  const code = (await page.getByTestId('game-code').innerText()).trim();
  const rows = await sql`select c.email, l.source, pc.code, (select count(*)::int from app_events e where e.code = 'renter_game_code' and e.entity_id = c.id) emails
                           from game_claims c join leads l on l.id = c.lead_id join promo_codes pc on pc.id = c.promo_code_id where c.email = ${email}`;
  expect(rows[0]).toMatchObject({ email, source: 'discount_game', code, emails: 1 });
  return code;
}

test.describe.configure({ mode: 'serial' });

const GAMES_PLAYED = [
  { game: 'wheel', play: async (p: Page) => { await p.getByTestId('game-action').click(); await expect(p.getByText(/It stopped on/).or(p.getByRole('heading', { name: /You won/ }))).toBeVisible({ timeout: 30_000 }); } },
  { game: 'scratch', play: async (p: Page) => {
    if (isPhone()) { await p.getByTestId('game-action').click(); return; }
    // scratch with the mouse across the card until half shows
    const box = (await p.locator('.ccg-scratch canvas').boundingBox())!;
    for (let y = box.y + 10; y < box.y + box.height; y += 18) {
      await p.mouse.move(box.x + 5, y); await p.mouse.down();
      await p.mouse.move(box.x + box.width - 5, y, { steps: 12 }); await p.mouse.up();
    }
    await expect(p.getByText(/You uncovered/).or(p.getByRole('heading', { name: /You won/ }))).toBeVisible({ timeout: 5000 });
  } },
  { game: 'blackjack', play: async (p: Page) => { await p.getByTestId('game-action').click(); await expect(p.getByText(/still win/)).toBeVisible(); await p.getByTestId('game-next').click(); } },
  { game: 'cups', play: async (p: Page) => {
    await p.getByTestId('game-action').click();
    await expect(p.getByText('Pick a cup.')).toBeVisible({ timeout: 30_000 });
    await p.getByTestId('game-cup-2').click();
    await expect(p.getByText(/You found/).or(p.getByRole('heading', { name: /You won/ }))).toBeVisible();
  } },
  { game: 'plinko', play: async (p: Page) => { await p.getByTestId('game-action').click(); await expect(p.getByText(/It landed on/).or(p.getByRole('heading', { name: /You won/ }))).toBeVisible({ timeout: 30_000 }); } }
];
const PLAY: Record<string, (p: Page) => Promise<void>> = Object.fromEntries(GAMES_PLAYED.map((g) => [g.game, g.play]));

for (const g of GAMES_PLAYED) {
  test(`${g.game}: shows after one car page, plays, reveals the prize, the code after the form`, async ({ browser }) => {
    test.setTimeout(90_000);
    const sql = db();
    const { page } = await visitor(browser, sql, g.game, PRIZE10, g.game === 'cups' && isPhone());
    await browseUntilGame(page);
    await expect(page.getByTestId('game')).toHaveAttribute('data-game', g.game);
    // not a full-screen block: the page behind stays visible
    const box = (await page.getByTestId('game').boundingBox())!;
    expect(box.height).toBeLessThan((isPhone() ? 812 : 900) * 0.9);
    await axe(page, `${g.game} start`);
    await page.getByTestId('game-play').click();
    await g.play(page);
    await axe(page, `${g.game} won`);
    await claim(page, sql, `game.${g.game}.${test.info().project.name}.${Date.now()}.${tag()}@example.test`, '10% off');
    await axe(page, `${g.game} code`);
    // never again on this device
    await page.goto('/cars/toyota-corolla', { waitUntil: 'load' });
    await page.goto('/cars/kia-forte', { waitUntil: 'load' });
    await page.waitForTimeout(1500);
    await expect(page.getByTestId('game')).toHaveCount(0);
    await page.context().close();
    await sql.end();
  });
}

test('the first game without a car page: after 15 seconds on the site (0076)', async ({ browser }) => {
  test.setTimeout(90_000);
  const sql = db();
  const { page } = await visitor(browser, sql, 'wheel', PRIZE10);
  const t0 = Date.now();
  await page.goto('/how-it-works', { waitUntil: 'load' });
  await answerCookies(page);
  await page.waitForTimeout(Math.max(0, 9000 - (Date.now() - t0)));
  await expect(page.getByTestId('game')).toHaveCount(0);
  await expect(page.getByTestId('game')).toBeVisible({ timeout: 20_000 });
  expect(Date.now() - t0).toBeGreaterThanOrEqual(14_000);
  await expect(page.getByTestId('game')).not.toHaveAttribute('data-slim', 'true');
  await page.context().close();
  await sql.end();
});

test('a phone visit from a search engine: nothing on the landing page at first, then the small slide-in (0076)', async ({ browser }) => {
  test.setTimeout(90_000);
  test.skip(!isPhone(), 'phones only: a computer gets the usual card');
  const sql = db();
  const { page } = await visitor(browser, sql, 'wheel', PRIZE10);
  await page.goto('/cars/toyota-corolla', { waitUntil: 'load', referer: 'https://www.google.com/' });
  await answerCookies(page);
  const t0 = Date.now();
  await page.waitForTimeout(6000);
  await expect(page.getByTestId('game')).toHaveCount(0);
  const slim = page.getByTestId('game');
  await expect(slim).toBeVisible({ timeout: 25_000 });
  await expect(slim).toHaveAttribute('data-slim', 'true');
  // it covers a small strip only, and leaves the chat button free
  const box = (await slim.boundingBox())!;
  expect(box.height).toBeLessThan(100);
  expect(box.x + box.width).toBeLessThanOrEqual(375 - 70);
  expect(Date.now() - t0).toBeGreaterThan(6000);
  await noOverflow(page);
  await page.getByTestId('game-open').click();
  await expect(page.getByTestId('game-play')).toBeVisible();
  await axe(page, 'slim opened');
  await page.context().close();
  await sql.end();
});

test('closed: a different game comes back after 2 more car pages, with the same prize (0076)', async ({ browser }) => {
  test.setTimeout(90_000);
  const sql = db();
  const { page, vid } = await visitor(browser, sql, 'wheel', PRIZE10);
  await browseUntilGame(page);
  await expect(page.getByTestId('game')).toHaveAttribute('data-game', 'wheel');
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('game')).toHaveCount(0);
  // one more car page is not enough
  await carPage(page, 'kia-forte');
  await page.waitForTimeout(1500);
  await expect(page.getByTestId('game')).toHaveCount(0);
  await carPage(page, 'hyundai-elantra');
  await expect(page.getByTestId('game')).toBeVisible({ timeout: 30_000 });
  const second = await page.getByTestId('game').getAttribute('data-game');
  expect(second).not.toBe('wheel');
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('cc_game') ?? '{}').seen)).toEqual(['wheel', second]);
  const plays = await sql`select game, prize ->> 'key' as k from game_plays where visitor_id = ${vid} order by created_at`;
  expect(plays.map((r) => `${r.game} ${r.k}`)).toEqual(['wheel pct10', `${second} pct10`]);
  await axe(page, 'second game');
  // closed again: the third and last of this visit comes after 2 more car pages, then no more
  await page.getByTestId('game-close').click();
  await expect(page.getByTestId('game')).toHaveCount(0);
  for (const c of ['mercedes-benz-a220', 'tesla-model-3']) await carPage(page, c);
  await expect(page.getByTestId('game')).toBeVisible({ timeout: 30_000 });
  const third = await page.getByTestId('game').getAttribute('data-game');
  expect(['wheel', second]).not.toContain(third);
  await page.getByTestId('game-close').click();
  await expect(page.getByTestId('game')).toHaveCount(0);
  for (const c of ['mercedes-benz-c300', 'toyota-camry', 'honda-civic']) await carPage(page, c);
  await page.waitForTimeout(2500);
  await expect(page.getByTestId('game')).toHaveCount(0);
  await page.context().close();
  await sql.end();
});

/** The request form to the add-ons step for a 4-day trip. */
async function toAddons(page: Page, slug: string, days: number, email: string) {
  const d = new Date(Date.now() + days * 86_400_000); const from = d.toISOString().slice(0, 10);
  d.setUTCDate(d.getUTCDate() + 4); const to = d.toISOString().slice(0, 10);
  await page.goto(`/book/${slug}?from=${from}&to=${to}&tf=10:00&tt=10:00`, { waitUntil: 'networkidle' });
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await b.isVisible().catch(() => false)) await b.click();
  await expect(page.locator('.estimate__lines')).toBeVisible({ timeout: 15_000 });
  await page.getByRole('button', { name: 'Continue to driver details' }).click();
  await page.locator('#rq-first').fill('Gia');
  await page.locator('#rq-last').fill('Player');
  await page.locator('#rq-email').fill(email);
  await page.locator('#rq-phone').fill(`647-555-${String(Math.floor(1000 + Math.random() * 8999))}`);
  await page.locator('#rq-dobm').selectOption('4');
  await page.locator('#rq-dobd').fill('9');
  await page.locator('#rq-doby').fill('1990');
  await page.getByRole('button', { name: 'Continue to licence' }).click();
  await page.locator('label', { hasText: 'Ontario G2' }).click();
  await page.locator('label.option', { hasText: 'Option 2' }).click();
  await page.getByRole('button', { name: 'Continue to add-ons' }).click();
}
const total = async (page: Page) => (await page.locator('.req__sum summary b.num').innerText()).trim();

test('the request-to-book form: the card plays, the code goes on this booking and the price drops (0076)', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const { page, vid } = await visitor(browser, sql, 'plinko', PRIZE50, true);
  const email = `game.bookcard.${test.info().project.name}.${Date.now()}@example.test`;
  await toAddons(page, isPhone() ? 'toyota-corolla' : 'tesla-model-3', isPhone() ? 150 : 155, email);
  const card = page.getByTestId('booking-game');
  await expect(card).toBeVisible({ timeout: 15_000 });
  await expect(card).toContainText('Play for a discount on this booking');
  await noOverflow(page);
  const before = await total(page);
  await card.getByTestId('booking-game-play').click();
  await expect(page.getByTestId('game')).toHaveAttribute('data-context', 'booking');
  await axe(page, 'booking start');
  await playAny(page);
  await expect(page.getByRole('heading', { name: 'You won $50 off' })).toBeVisible({ timeout: 15_000 });
  // filled from the form: one press
  await expect(page.getByTestId('game').getByLabel('Email', { exact: true })).toHaveValue(email);
  await page.getByTestId('game-get-code').click();
  await expect(page.getByTestId('game-code')).toHaveText(/^WIN-[A-Z2-9]{4}-[A-Z2-9]{4}$/, { timeout: 30_000 });
  const code = (await page.getByTestId('game-code').innerText()).trim();
  await expect(page.getByTestId('game-applied')).toHaveText(`Code ${code} applied: $50.00 off the rental charge.`, { timeout: 15_000 });
  await axe(page, 'booking applied');
  await page.getByTestId('game-continue').click();
  await expect(page.getByTestId('game')).toHaveCount(0);
  await expect(page.getByTestId('booking-game-won')).toContainText(code);
  await expect.poll(() => total(page), { timeout: 15_000 }).not.toBe(before);
  await expect(page.locator('.estimate__lines')).toContainText('Promo code');
  const play = await sql`select context, game from game_plays where visitor_id = ${vid} order by created_at desc limit 1`;
  expect(play[0]!.context).toBe('booking');
  expect(play[0]!.game).not.toBe('plinko'); // a game this visitor had not seen
  await page.getByRole('button', { name: 'Review request' }).click();
  await expect(page.getByTestId('promo-code')).toHaveValue(code);
  await expect(page.getByTestId('promo-status')).toHaveText(`Code ${code} applied: $50.00 off the rental charge.`);
  await page.locator('input[name="agree"]').check();
  await page.getByRole('button', { name: 'Send request' }).click();
  await page.waitForURL(/\/book\/sent\//, { timeout: 30_000 });
  const number = decodeURIComponent(page.url().split('/').pop()!);
  const b = await sql`select b.promo_discount_cents::int disc, pc.code from bookings b join promo_codes pc on pc.id = b.promo_code_id where b.booking_number = ${number}`;
  expect(b[0]).toMatchObject({ disc: 5000, code });
  await page.context().close();
  await sql.end();
});

test('the request-to-book form: closing the game leaves the booking as it was (0076)', async ({ browser }) => {
  test.setTimeout(120_000);
  const sql = db();
  const { page } = await visitor(browser, sql, 'cups', PRIZE10, true);
  const email = `game.bookclose.${test.info().project.name}.${Date.now()}@example.test`;
  await toAddons(page, isPhone() ? 'kia-forte' : 'hyundai-elantra', isPhone() ? 160 : 165, email);
  await expect(page.getByTestId('booking-game')).toBeVisible({ timeout: 15_000 });
  const before = await total(page);
  await page.getByTestId('booking-game-play').click();
  await expect(page.getByTestId('game')).toBeVisible();
  await page.getByTestId('game-close').click();
  await expect(page.getByTestId('game')).toHaveCount(0);
  await expect(page.getByTestId('booking-game')).toHaveCount(0);
  expect(await total(page)).toBe(before);
  await page.getByRole('button', { name: 'Review request' }).click();
  await expect(page.getByTestId('booking-game')).toHaveCount(0);
  await expect(page.getByTestId('promo-code')).toHaveValue('');
  await page.locator('input[name="agree"]').check();
  await page.getByRole('button', { name: 'Send request' }).click();
  await page.waitForURL(/\/book\/sent\//, { timeout: 30_000 });
  const number = decodeURIComponent(page.url().split('/').pop()!);
  const b = await sql`select promo_code_id from bookings where booking_number = ${number}`;
  expect(b[0]!.promo_code_id).toBeNull();
  await page.context().close();
  await sql.end();
});

test('the code fills in the request form, takes $50 off a 4-day request and goes on the booking request', async ({ browser }) => {
  test.setTimeout(120_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const { page } = await visitor(browser, sql, 'plinko', PRIZE50, true);
  await browseUntilGame(page);
  await page.getByTestId('game-play').click();
  await page.getByTestId('game-action').click();
  const email = `game.book.${test.info().project.name}.${Date.now()}@example.test`;
  const code = await claim(page, sql, email, '$50 off');
  // a car and four free days
  const slug = isPhone() ? 'hyundai-elantra' : 'mercedes-benz-a220';
  const d = new Date(Date.now() + (isPhone() ? 160 : 170) * 86_400_000); const from = d.toISOString().slice(0, 10);
  d.setUTCDate(d.getUTCDate() + 4); const to = d.toISOString().slice(0, 10);
  await page.goto(`/book/${slug}?from=${from}&to=${to}&tf=10:00&tt=10:00`, { waitUntil: 'networkidle' });
  await expect(page.locator('.estimate__lines')).toContainText('Promo code', { timeout: 15_000 });
  await page.getByRole('button', { name: 'Continue to driver details' }).click();
  await page.locator('#rq-first').fill('Gia');
  await page.locator('#rq-last').fill('Player');
  await page.locator('#rq-email').fill(email);
  await page.locator('#rq-phone').fill('647-555-0177');
  await page.locator('#rq-dobm').selectOption('4');
  await page.locator('#rq-dobd').fill('9');
  await page.locator('#rq-doby').fill('1990');
  await page.getByRole('button', { name: 'Continue to licence' }).click();
  await page.locator('label', { hasText: 'Ontario G2' }).click();
  await page.locator('label.option', { hasText: 'Option 2' }).click();
  await page.getByRole('button', { name: 'Continue to add-ons' }).click();
  await page.getByRole('button', { name: 'Review request' }).click();
  await expect(page.getByTestId('promo-code')).toHaveValue(code);
  await expect(page.getByTestId('promo-status')).toHaveText(`Code ${code} applied: $50.00 off the rental charge.`);
  await page.locator('input[name="agree"]').check();
  await page.getByRole('button', { name: 'Send request' }).click();
  await page.waitForURL(/\/book\/sent\//, { timeout: 30_000 });
  const number = decodeURIComponent(page.url().split('/').pop()!);
  const b = await sql`select b.promo_discount_cents::int disc, pc.code, r.status from bookings b join promo_codes pc on pc.id = b.promo_code_id
                        join promo_redemptions r on r.booking_id = b.id where b.booking_number = ${number}`;
  expect(b[0]).toMatchObject({ disc: 5000, code, status: 'applied' });
  await page.context().close();
  await sql.end();
});

test('a signed-in visitor never sees a game on the site, and is offered it in the request-to-book form', async ({ browser }) => {
  test.setTimeout(90_000);
  const sql = db();
  const id = randomUUID(); const email = `game.signed.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash, email_confirmed_at) values (${id}, ${email}, ${hash(PW)}, now())`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${'Sam Signed'})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'renter')`;
  const { page } = await visitor(browser, sql, 'wheel', PRIZE10);
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await b.isVisible().catch(() => false)) await b.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 20_000 });
  for (const s of ['toyota-corolla', 'tesla-model-3', 'kia-forte']) await page.goto(`/cars/${s}`, { waitUntil: 'load' });
  await page.waitForTimeout(3000);
  await expect(page.getByTestId('game')).toHaveCount(0);
  // 0076: the request-to-book form is the one place a signed-in renter is offered the game, with their account's email
  await toAddons(page, 'mercedes-benz-c300', isPhone() ? 175 : 180, email);
  await expect(page.getByTestId('booking-game')).toBeVisible({ timeout: 15_000 });
  await page.getByTestId('booking-game-play').click();
  await expect(page.getByTestId('game')).toHaveAttribute('data-context', 'booking');
  await page.getByTestId('game-close').click();
  await expect(page.getByTestId('booking-game')).toHaveCount(0);
  await page.context().close();
  await sql.end();
});

test('Admin: Bookings > Leads shows the claims and the report; Settings > Discount games is on with the owner\'s prizes', async ({ browser }) => {
  test.setTimeout(90_000);
  const sql = db();
  const id = randomUUID(); const email = `admin.game.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash, email_confirmed_at) values (${id}, ${email}, ${hash(PW)}, now())`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${'Ada Games'})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, baseURL: test.info().project.use.baseURL });
  const page = await c.newPage();
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await b.isVisible().catch(() => false)) await b.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
  await page.goto('/admin/leads', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('game-leads')).toContainText('WIN-');
  await expect(page.getByText(/Plays, 30 days/)).toBeVisible();
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => v.id)).toEqual([]);
  await page.goto('/admin/settings/discount-games', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('game-rules')).toBeVisible();
  await expect(page.getByTestId('game-settings').locator('input').first()).toHaveValue('5');
  await noOverflow(page);
  await c.close();
  await sql.end();
});
