import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { acceptCookies, db, noOverflow, watch } from './helpers';
import { PW, seedInvestor, seedOwner } from './portal-design-seed';

// The owner and investor portal design (docs/changes/2026-10-24-owner-investor-portal-design.md), at 375 and 1440: the
// owner's hero (each car's photo and status right now, this month's rental charges against last month, the next payout),
// the months chart with its month switcher and car filter, the cars' cards, what is coming up, statements, payouts and
// documents as rows; the investor's hero (invested, paid to date, next payment), the growth chart, the payment schedule
// and the deck tile. Every page: axe (no serious or critical issue), no sideways scroll, the copy rules, and the
// investor page shows nothing about the fleet. Fictional people only (example.test).
const LOCK = 780083; // the deck switch is global (investor-deck.spec.ts takes the same lock)
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/18122211|\d{6,}\s+Canada|Canada Inc\b/i, 'numbered company name'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b/, 'brand misspelled']];

async function check(page: Page, where: string) {
  await noOverflow(page);
  const wide = await page.evaluate(() => [...document.querySelectorAll('body *')].filter((e) => e.getBoundingClientRect().right > innerWidth + 1 && !e.closest('.table-scroll, .agreement, .pt__nav, .ad-nav')).slice(0, 5).map((e) => `${e.tagName}.${e.className}`));
  expect(wide, `${where}: elements wider than the screen`).toEqual([]);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('main').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' }).catch(() => page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' }));
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(next), { timeout: 60_000 });
  await page.waitForLoadState('networkidle');
}

test('owner portal design: live cars, months, coming up, money rows', async ({ page }, info) => {
  test.setTimeout(240_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const errors = watch(page);
  const o = await seedOwner(sql);
  await signIn(page, o.email, '/owner');
  // the hero: the three cars with their status right now, this month's figures
  const hero = page.getByTestId('owner-hero');
  await expect(hero).toContainText('Hello, Olivia');
  await expect(hero.locator('.ow-hero-car')).toHaveCount(3);
  for (const label of ['On rent', 'Available', 'In service']) await expect(hero).toContainText(label);
  await expect(hero.locator('img')).not.toHaveCount(0);
  await expect(page.getByTestId('owner-month-rental')).toHaveText(/^\$\d[\d,]*$/);
  await expect(page.getByTestId('owner-next-payout')).toHaveText(/^\$6,554\.00$/);
  await expect(page.getByTestId('owner-due')).toHaveText('$0.00');
  // the months: switch month and car, the chart's columns are buttons
  const months = page.getByTestId('owner-months');
  const now = await months.getByTestId('months-current').innerText();
  await months.getByRole('button', { name: 'Earlier month' }).click();
  await expect(months.getByTestId('months-current')).not.toHaveText(now);
  await expect(months.getByTestId('months-payout')).toHaveText(/^\$\d/);
  const bars = months.getByTestId('months-chart').locator('button');
  await expect(bars).toHaveCount(6);
  await bars.last().click();
  await expect(bars.last()).toHaveAttribute('aria-pressed', 'true');
  await expect(months.getByTestId('months-current')).toHaveText(now);
  await months.getByTestId('months-car').first().click();
  await expect(months.locator('h2')).toContainText(o.cars[0]!.name);
  await months.getByTestId('months-payouts').click();
  await expect(months.locator('h2')).toHaveText('Payouts by month');
  await expect(page.getByTestId('owner-coming-up').locator('li')).not.toHaveCount(0);
  await expect(page.getByTestId('owner-vehicle')).toHaveCount(3);
  await expect(page.getByTestId('owner-vehicle').first().getByTestId('vehicle-live')).toHaveText('On rent');
  await check(page, 'owner home');
  await page.screenshot({ path: `test-results/owner-investor-design/owner-home-${info.project.name}.png`, fullPage: true });
  // a car's drilldown: its photo, status, months and what is coming up
  await page.getByTestId('owner-vehicle').first().getByRole('link', { name: o.cars[0]!.name }).click();
  await page.waitForURL(`**/owner/vehicles/${o.cars[0]!.id}`);
  await expect(page.getByTestId('vehicle-hero').getByTestId('vehicle-live')).toHaveText('On rent');
  await expect(page.getByTestId('vehicle-months')).toBeVisible();
  await expect(page.getByTestId('vehicle-coming-up').locator('li')).not.toHaveCount(0);
  await check(page, 'owner vehicle');
  for (const [path, id] of [['/owner/vehicles', 'owner-vehicle'], ['/owner/bookings', 'owner-coming-up'], ['/owner/statements', 'owner-statements'], ['/owner/payouts', 'owner-payouts'], ['/owner/invoices', 'invoice-rows'], ['/owner/documents', null]] as const) {
    await page.goto(path, { waitUntil: 'networkidle' });
    if (id) await expect(page.getByTestId(id).first()).toBeVisible();
    await check(page, path);
  }
  await expect(page.locator('body')).not.toContainText('utilization', { ignoreCase: true });
  expect(errors.filter((e) => !/favicon|Download the React DevTools/.test(e))).toEqual([]);
  await sql.end();
});

test('investor portal design: invested, paid, next payment, schedule, growth, deck tile', async ({ page }, info) => {
  test.setTimeout(180_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  await sql`select pg_advisory_lock(${LOCK})`;
  try {
    await sql`update deck_settings set show_to_investors = true, deck_multiplier = 3.2, deck_return_bps = 3000`;
    const i = await seedInvestor(sql);
    await signIn(page, i.email, '/investor');
    await expect(page.getByTestId('investor-name')).toHaveText('Isabel Grant');
    await expect(page.getByTestId('invested-amount')).toHaveText('$50,000.00');
    await expect(page.getByTestId('investor-total-invested')).toHaveText('$50,000.00');
    await expect(page.getByTestId('investor-paid-to-date')).toHaveText('$7,500.00');
    await expect(page.getByTestId('investor-next-payment')).toHaveText('$1,250.00');
    await expect(page.getByTestId('investor-growth').locator('svg')).toHaveAttribute('aria-label', /Invested Amount and Returns/);
    await expect(page.getByTestId('investor-growth').locator('p.vh')).toContainText('Returns to date $7,500');
    const sched = page.getByTestId('investor-schedule');
    await expect(sched).toContainText('Paid');
    await expect(sched).toContainText('Estimated');
    await expect(page.getByTestId('deck-tile-multiplier')).toHaveText('3.2x');
    await expect(page.getByTestId('deck-promo').getByRole('link', { name: 'Open the deck' })).toHaveAttribute('href', '/investor/deck');
    // the confidentiality rule: nothing about the fleet's size, use, insurance or costs
    const text = await page.locator('main').innerText();
    for (const word of [/utili[sz]ation/i, /fleet size/i, /premium/i, /\bcars? in the fleet\b/i, /insurance/i, /operating cost/i]) expect(text).not.toMatch(word);
    await check(page, 'investor home');
    await page.screenshot({ path: `test-results/owner-investor-design/investor-home-${info.project.name}.png`, fullPage: true });
  } finally {
    await sql`select pg_advisory_unlock(${LOCK})`;
    await sql.end();
  }
});
