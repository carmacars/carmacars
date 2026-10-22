import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID } from 'node:crypto';
import { db, noOverflow } from './helpers';

// Migration 0100 end to end, at 375 and 1440. The discount game: the prize never shows before a game is played (a
// prize already won comes back as the small "Your 10% off is saved" badge, never as "You won"); each of the five new
// games (coin flip, dice roll, slot machine, prize drop, mystery box) plays to the drawn prize and gives the code; the
// owner's timings as set live (the 2nd page view; after a close the 3rd page view; 4 a visit; never the same game twice
// in a row; none once a booking request is in progress). The chat greeting: once a visit, for the page (the car's
// name on a car page), never over a game, and a reply opens the chat with it as the first message. axe and overflow on
// every new surface.
type Sql = ReturnType<typeof db>;
const isPhone = () => test.info().project.name.includes('phone');
const tag = () => randomBytes(3).toString('hex');
const PRIZE10 = { key: 'pct10', percent_bps: 1000, weight: 25 };

async function axe(page: Page, where: string, include = '[data-testid="game"]') {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).include(include).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}

/** A browser with a known id. games: let the games play in this automated browser (cfg: its own timings, else the
 *  live settings); greet: let the chat greeting open (after: its own wait in seconds, else the live setting). */
async function visitor(browser: Browser, sql: Sql, o: { game?: string; prize?: object; revealed?: boolean; games?: boolean; cfg?: object; greet?: boolean; after?: number; storage?: Record<string, string> } = {}) {
  const vid = randomUUID();
  await sql`delete from app.rate_limit_hits where key like 'game-%' or key like 'chat-%'`;
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(),
    baseURL: test.info().project.use.baseURL, reducedMotion: 'no-preference' });
  await c.addCookies([{ name: 'cc_vid', value: vid, url: test.info().project.use.baseURL! }]);
  const items: Record<string, string> = { ...(o.storage ?? {}) };
  if (o.games !== false) items.cc_games_e2e = '1';
  if (o.cfg) items.cc_games_e2e_cfg = JSON.stringify(o.cfg);
  if (o.greet) { items.cc_chat_greet_e2e = '1'; if (o.after) items.cc_chat_greet_e2e_after = String(o.after); }
  // once per browser (not on every page load): what a test sets is the browser's starting point
  await c.addInitScript((it) => { try { if (!sessionStorage.getItem('cc_e2e_seeded')) { for (const [k, v] of Object.entries(it)) localStorage.setItem(k, v); sessionStorage.setItem('cc_e2e_seeded', '1'); } } catch { /* none */ } }, items);
  if (o.game) await sql`insert into game_plays (visitor_id, game, prize, path, trigger, revealed_at) values (${vid}, ${o.game}, ${sql.json((o.prize ?? PRIZE10) as never)}, '/cars/toyota-corolla', 'pages', ${o.revealed ? new Date() : null})`;
  const page = await c.newPage();
  return { page, vid };
}

async function answerCookies(page: Page) {
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  await b.waitFor({ state: 'visible', timeout: 15_000 });
  await b.click();
  await page.waitForFunction(() => document.cookie.includes('cc_cookie_choice='));
}

/** A page the games' watcher has counted. */
async function visit(page: Page, path: string) {
  const before = await page.evaluate(() => JSON.parse(sessionStorage.getItem('cc_game_visit') ?? '{}').pages ?? 0).catch(() => 0);
  await page.goto(path, { waitUntil: 'load' });
  await page.waitForFunction((n) => (JSON.parse(sessionStorage.getItem('cc_game_visit') ?? '{}').pages ?? 0) > n, before, { timeout: 15_000 });
}

/** The five games of 0100, played to their prize. */
const PLAY: Record<string, (p: Page) => Promise<void>> = {
  coin: async (p) => { await p.getByTestId('game-call-tails').click(); await expect(p.locator('.ccg-live', { hasText: /It landed on (heads|tails)/ })).toBeVisible({ timeout: 15_000 }); },
  dice: async (p) => { await p.getByTestId('game-action').click(); await expect(p.locator('.ccg-live', { hasText: /You rolled \d and \d/ })).toBeVisible({ timeout: 15_000 }); },
  slots: async (p) => { await p.getByTestId('game-action').click(); await expect(p.locator('.ccg-live', { hasText: 'Three in a row' })).toBeVisible({ timeout: 15_000 }); },
  drop: async (p) => { await p.getByTestId('game-action').click(); await expect(p.locator('.ccg-live', { hasText: 'Your capsule holds' })).toBeVisible({ timeout: 15_000 }); },
  mystery: async (p) => { await p.getByTestId('game-box-2').click(); await expect(p.locator('.ccg-live', { hasText: 'Box 2 holds' })).toBeVisible({ timeout: 15_000 }); }
};

async function claim(page: Page, sql: Sql, heading: string) {
  await expect(page.getByRole('heading', { name: heading })).toBeVisible({ timeout: 20_000 });
  const g = page.getByTestId('game');
  const email = `g3.${test.info().project.name}.${Date.now()}.${tag()}@example.test`;
  await g.getByLabel('First name', { exact: true }).fill('Gia');
  await g.getByLabel('Email', { exact: true }).fill(email);
  await page.getByTestId('game-get-code').click();
  await expect(page.getByTestId('game-code')).toHaveText(/^WIN-[A-Z2-9]{4}-[A-Z2-9]{4}$/, { timeout: 30_000 });
  const rows = await sql`select pc.percent_bps from game_claims c join promo_codes pc on pc.id = c.promo_code_id where c.email = ${email}`;
  expect(rows[0]!.percent_bps).toBe(1000);
}

test.describe.configure({ mode: 'serial' });

for (const game of Object.keys(PLAY)) {
  test(`${game}: a short animated game, played to the drawn prize, then the code`, async ({ browser }) => {
    test.setTimeout(90_000);
    const sql = db();
    const { page } = await visitor(browser, sql, { game, cfg: { car_pages: 1 } });
    await visit(page, '/cars/toyota-corolla');
    await answerCookies(page);
    const card = page.getByTestId('game');
    await expect(card).toBeVisible({ timeout: 30_000 });
    await expect(card).toHaveAttribute('data-game', game);
    // nothing about the prize before the game is played
    await expect(card).not.toContainText('10% off');
    await expect(page.getByRole('heading', { name: /You won|is saved/ })).toHaveCount(0);
    const box = (await card.boundingBox())!;
    expect(box.height).toBeLessThan((isPhone() ? 812 : 900) * 0.9);
    await axe(page, `${game} start`);
    await page.getByTestId('game-play').click();
    await axe(page, `${game} playing`);
    await PLAY[game]!(page);
    await axe(page, `${game} won`);
    await claim(page, sql, 'You won 10% off');
    await axe(page, `${game} code`);
    await page.context().close();
    await sql.end();
  });
}

test('the prize is never shown before a game: a prize already seen is "saved" in a small badge, never "You won"', async ({ browser }) => {
  test.setTimeout(90_000);
  const sql = db();
  // the live case: an earlier game was played to the prize (revealed), and this browser forgot it (another tab,
  // cleared storage); the visitor reaches the page where a game fires
  const { page, vid } = await visitor(browser, sql, { game: 'wheel', revealed: true, cfg: { car_pages: 1 } });
  await visit(page, '/faq');
  await answerCookies(page);
  const badge = page.getByTestId('game-saved');
  await expect(badge).toBeVisible({ timeout: 30_000 });
  await expect(badge).toHaveText(/Your 10% off is saved/);
  await expect(page.getByRole('heading', { name: /You won/ })).toHaveCount(0);
  await expect(page.getByTestId('game-play')).toHaveCount(0);
  const b = (await badge.boundingBox())!;
  expect(b.height).toBeLessThan(80);
  await axe(page, 'saved badge', '[data-testid="game-saved"]');
  // no new play and no new draw
  expect((await sql`select count(*)::int n from game_plays where visitor_id = ${vid}`)[0]!.n).toBe(1);
  // on the next page: the badge again, still no game
  await visit(page, '/how-it-works');
  await expect(badge).toBeVisible({ timeout: 15_000 });
  await expect(page.locator('[data-testid="game"]')).toHaveCount(0);
  // the badge opens the claim form under "saved"
  await page.getByTestId('game-saved-open').click();
  await expect(page.getByTestId('game')).toHaveAttribute('data-saved', 'true');
  await axe(page, 'saved card');
  await claim(page, sql, 'Your 10% off is saved');
  await page.context().close();
  await sql.end();
});

test('a prize won in this browser: later pages show "saved", never a new game', async ({ browser }) => {
  test.setTimeout(90_000);
  const sql = db();
  const { page } = await visitor(browser, sql, { game: 'dice', cfg: { car_pages: 1 } });
  await visit(page, '/cars/toyota-corolla');
  await answerCookies(page);
  await expect(page.getByTestId('game')).toBeVisible({ timeout: 30_000 });
  await page.getByTestId('game-play').click();
  await PLAY.dice!(page);
  await expect(page.getByRole('heading', { name: 'You won 10% off' })).toBeVisible({ timeout: 15_000 });
  await page.getByTestId('game-close').click();
  for (const p of ['/faq', '/how-it-works', '/cars', '/delivery']) await visit(page, p);
  await expect(page.getByTestId('game-saved')).toHaveText(/Your 10% off is saved/);
  await expect(page.getByTestId('game')).toHaveCount(0);
  // hidden for this visit when closed
  await page.getByTestId('game-saved-close').click();
  await visit(page, '/faq');
  await page.waitForTimeout(1500);
  await expect(page.getByTestId('game-saved')).toHaveCount(0);
  await page.context().close();
  await sql.end();
});

test("the owner's timings as set live: the 2nd page view, then the 3rd page view after a close, 4 a visit, never the same game twice in a row", async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const live = await sql`select app.game_cfg() c`;
  expect(live[0]!.c).toMatchObject({ car_pages: 2, seconds: 30, reshow_pages: 3, reshow_seconds: 120, per_visit: 4, per_day: 0, exit: true });
  const { page } = await visitor(browser, sql, {});
  await visit(page, '/faq');
  await answerCookies(page);
  await page.waitForTimeout(2000);
  await expect(page.getByTestId('game')).toHaveCount(0);
  await visit(page, '/how-it-works');
  await expect(page.getByTestId('game')).toBeVisible({ timeout: 20_000 });
  const games = [(await page.getByTestId('game').getAttribute('data-game'))!];
  await axe(page, 'first game');
  const pages = ['/delivery', '/requirements', '/cars', '/faq', '/how-it-works', '/delivery', '/requirements', '/cars', '/faq', '/how-it-works', '/delivery', '/requirements'];
  let i = 0;
  for (let shown = 1; shown < 4; shown++) {
    await page.getByTestId('game-close').click();
    await expect(page.getByTestId('game')).toHaveCount(0);
    await visit(page, pages[i++]!);
    await visit(page, pages[i++]!);
    await page.waitForTimeout(1200);
    await expect(page.getByTestId('game')).toHaveCount(0);
    await visit(page, pages[i++]!);
    await expect(page.getByTestId('game')).toBeVisible({ timeout: 20_000 });
    games.push((await page.getByTestId('game').getAttribute('data-game'))!);
  }
  for (let k = 1; k < games.length; k++) expect(games[k]).not.toBe(games[k - 1]);
  expect(new Set(games).size).toBe(4);
  // the 4th was the last of this visit
  await page.getByTestId('game-close').click();
  for (const p of pages.slice(i)) await visit(page, p);
  await page.waitForTimeout(2000);
  await expect(page.getByTestId('game')).toHaveCount(0);
  await page.context().close();
  await sql.end();
});

test("the first game after 30 seconds on one page (the owner's setting)", async ({ browser }) => {
  test.setTimeout(90_000);
  test.skip(isPhone(), 'the time rule is the same on a phone; the computer run checks it');
  const sql = db();
  const { page } = await visitor(browser, sql, {});
  const t0 = Date.now();
  await visit(page, '/how-it-works');
  await answerCookies(page);
  await page.waitForTimeout(Math.max(0, 24_000 - (Date.now() - t0)));
  await expect(page.getByTestId('game')).toHaveCount(0);
  await expect(page.getByTestId('game')).toBeVisible({ timeout: 25_000 });
  expect(Date.now() - t0).toBeGreaterThanOrEqual(29_000);
  await page.context().close();
  await sql.end();
});

test('no game once a booking request is in progress in this browser', async ({ browser }) => {
  test.setTimeout(90_000);
  const sql = db();
  const draft = JSON.stringify({ data: {}, step: 2, token: null, draftId: null, key: 'k', at: Date.now() });
  const { page } = await visitor(browser, sql, { cfg: { car_pages: 1, seconds: 5 }, storage: { 'cc.request.v2': draft } });
  await visit(page, '/cars/toyota-corolla');
  await answerCookies(page);
  for (const p of ['/faq', '/how-it-works', '/cars']) await visit(page, p);
  await page.waitForTimeout(7000);
  await expect(page.getByTestId('game')).toHaveCount(0);
  await expect(page.getByTestId('game-saved')).toHaveCount(0);
  await page.context().close();
  await sql.end();
});

test('the chat greeting: after 45 seconds, once a visit, with the car on a car page; a reply opens the chat with it', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const live = await sql`select chat_greeting_seconds s from (select (app.settings()).*) x`;
  expect(live[0]!.s).toBe(45);
  // the live 45 seconds on the computer run; a shorter wait on the phone run
  const { page } = await visitor(browser, sql, { games: false, greet: true, after: isPhone() ? 6 : undefined });
  const t0 = Date.now();
  await page.goto('/cars/mercedes-benz-a220', { waitUntil: 'load' });
  await answerCookies(page);
  const bubble = page.getByTestId('chat-bubble');
  if (!isPhone()) {
    await page.waitForTimeout(Math.max(0, 38_000 - (Date.now() - t0)));
    await expect(bubble).toHaveCount(0);
  }
  await expect(bubble).toBeVisible({ timeout: isPhone() ? 20_000 : 30_000 });
  if (!isPhone()) expect(Date.now() - t0).toBeGreaterThanOrEqual(44_000);
  await expect(bubble).toHaveAttribute('data-kind', 'greeting');
  await expect(bubble).toContainText('CarmaCars');
  await expect(bubble).toContainText('Hi! Questions about the 2021 Mercedes-Benz A220?');
  // a preview only: the chat itself is not open
  await expect(page.locator('#ccw-panel')).toHaveCount(0);
  await axe(page, 'greeting', '[data-testid="chat-widget"]');
  const text = (await bubble.locator('p').innerText()).replace(/^CarmaCars\s*/, '').trim();
  await bubble.getByRole('button', { name: 'Reply' }).click();
  const first = page.getByTestId('chat-log').locator('[data-sender="ai"] .ccw-text').first();
  await expect(first).toHaveText(text, { timeout: 15_000 });
  await axe(page, 'chat with the greeting', '[data-testid="chat-widget"]');
  await page.keyboard.press('Escape');
  await expect(page.locator('#ccw-panel')).toHaveCount(0);
  await page.context().close();
  await sql.end();
});

test('the chat greeting shows once a visit, never over a game: it waits for the game to close', async ({ browser }) => {
  test.setTimeout(120_000);
  const sql = db();
  const { page } = await visitor(browser, sql, { game: 'coin', cfg: { car_pages: 1, seconds: 0 }, greet: true, after: 4 });
  await visit(page, '/faq');
  await answerCookies(page);
  await expect(page.getByTestId('game')).toBeVisible({ timeout: 30_000 });
  await page.waitForTimeout(8000);
  await expect(page.getByTestId('chat-bubble')).toHaveCount(0);
  await page.getByTestId('game-close').click();
  const bubble = page.getByTestId('chat-bubble');
  await expect(bubble).toBeVisible({ timeout: 15_000 });
  await expect(bubble).toContainText('Hi! Looking for a car? Ask me anything: prices, delivery, or what you need to rent.');
  await noOverflow(page);
  await bubble.getByRole('button', { name: 'No thanks' }).click();
  await expect(bubble).toHaveCount(0);
  // once a visit: not on the next pages
  await visit(page, '/how-it-works');
  await page.waitForTimeout(7000);
  await expect(page.getByTestId('chat-bubble')).toHaveCount(0);
  await page.context().close();
  await sql.end();
});

test('the chat greeting never opens on booking or sign-in pages', async ({ browser }) => {
  test.setTimeout(60_000);
  const sql = db();
  const { page } = await visitor(browser, sql, { games: false, greet: true, after: 2 });
  await page.goto('/sign-in', { waitUntil: 'load' });
  await answerCookies(page);
  await page.waitForTimeout(6000);
  await expect(page.getByTestId('chat-bubble')).toHaveCount(0);
  await page.goto('/book/toyota-corolla', { waitUntil: 'load' });
  await page.waitForTimeout(6000);
  await expect(page.getByTestId('chat-bubble')).toHaveCount(0);
  await page.context().close();
  await sql.end();
});
