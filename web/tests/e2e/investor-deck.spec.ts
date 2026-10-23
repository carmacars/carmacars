import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { acceptCookies, db, noOverflow, pdfText } from './helpers';

// The investor deck (migration 0083), end to end at 375 and 1440: a signed-in investor finds it on the portal home and in
// the menu, moves through the slides by keyboard and buttons, uses the calculator (the agreement's numbers: $20,000 at
// 30% pays $500.00 a month, first paid about 7.5 months after investing), and prints it to PDF (one landscape page per
// slide, with the forward-looking notice). An Admin previews it, changes its settings, and hides it: the investor then
// sees neither the link nor the deck. Fictional people only (example.test).
const SHOTS = 'test-results/investor-deck';
const PW = 'correct horse battery';
const LOCK = 780083; // the "Show the deck to investors" switch is global: tests that read or change it take turns
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b/, 'brand misspelled'], [/18122211|\d{6,}\s+Canada|Canada Inc\b/i, 'numbered company name']];
type Sql = ReturnType<typeof db>;
mkdirSync(SHOTS, { recursive: true });

const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;
const shot = (page: Page, name: string) => page.screenshot({ path: `${SHOTS}/${test.info().project.name}-${name}.png` });

async function mkPerson(sql: Sql, kind: 'investor' | 'admin', name: string) {
  const id = randomUUID(); const email = `${kind}.deck.${Date.now()}.${randomBytes(2).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  else await sql`insert into investors (user_id, legal_name, investor_type, status, email) values (${id}, ${name}, 'individual', 'active', ${email})`;
  return { id, email };
}
async function signIn(page: Page, email: string) {
  // a first visit can be cut short while the server compiles: once more
  await page.goto('/sign-in', { waitUntil: 'networkidle' }).catch(() => page.goto('/sign-in', { waitUntil: 'networkidle' }));
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 60_000 });
  await page.waitForLoadState('networkidle');
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL,
    reducedMotion: 'reduce' });
  return c.newPage();
}
async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('main').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}

test.describe('investor deck', () => {
  let sql: Sql;
  test.beforeAll(() => { sql = db(); });
  test.afterAll(async () => { await sql.end(); });

  test('an investor opens the deck, moves through it, uses the calculator', async ({ browser }) => {
    test.setTimeout(240_000);
    await sql`select pg_advisory_lock(${LOCK})`;
    try {
      await sql`update deck_settings set show_to_investors = true, deck_multiplier = 3.2, deck_return_bps = 3000`;
      const inv = await mkPerson(sql, 'investor', 'Dana Example');
      const page = await ctx(browser);
      await signIn(page, inv.email);
      await page.goto('/investor', { waitUntil: 'networkidle' });
      await expect(page.getByTestId('deck-promo')).toBeVisible();
      await expect(page.getByTestId('nav-deck')).toBeVisible();
      await page.getByTestId('deck-promo').getByRole('link', { name: 'Open the deck' }).click();
      await page.waitForURL('**/investor/deck');
      await expect(page.locator('meta[name="robots"]')).toHaveAttribute('content', /noindex/);
      await expect(page.getByTestId('deck')).toHaveAttribute('data-ready', 'true', { timeout: 60_000 });
      const n = await page.getByTestId('deck-slide').count();
      expect(n).toBeGreaterThan(40);
      await expect(page.getByTestId('deck-count')).toHaveText(`1 / ${n}`);
      await expect(page.getByTestId('deck-multiplier')).toHaveText('3.2x');
      await expect(page.locator('#offer')).toContainText('30% a year on our current offer, set in your agreement');
      await expect(page.locator('#risks')).toContainText('unsecured');
      await check(page, 'deck');
      await shot(page, 'title');

      // next by button, then by keyboard
      await page.getByTestId('deck-next').click();
      await expect(page.getByTestId('deck-count')).toHaveText(`2 / ${n}`);
      await page.keyboard.press('ArrowRight');
      await expect(page.getByTestId('deck-count')).toHaveText(`3 / ${n}`);
      await page.keyboard.press('End');
      await expect(page.getByTestId('deck-count')).toHaveText(`${n} / ${n}`);
      await page.keyboard.press('Home');
      await expect(page.getByTestId('deck-count')).toHaveText(`1 / ${n}`);

      // the sample rental and the tiers come from the database
      await expect(page.getByTestId('deck-tiers').locator('tbody tr')).toHaveCount(Number((await sql`select count(*)::int n from owner_fee_grid g where g.effective_from = (select max(effective_from) from owner_fee_grid where effective_from <= current_date)`)[0]!.n));

      // the calculator: the agreement's numbers
      const calc = page.getByTestId('deck-calculator');
      await calc.scrollIntoViewIfNeeded();
      await page.getByTestId('calc-amount').fill('20000');
      await page.getByTestId('calc-mode-pay').click();
      await expect(page.getByTestId('calc-monthly')).toHaveText('$500.00');
      await expect(calc).toContainText('about 7.5 months after you invest');
      await page.getByTestId('calc-years').selectOption('3');
      await page.getByTestId('calc-mode-switch').click();
      await expect(page.getByTestId('calc-monthly')).toHaveText('$672.44');
      await page.getByTestId('calc-mode-reinvest').click();
      await expect(page.getByTestId('calc-paid')).toHaveText('$0.00');
      await page.getByTestId('calc-amount').fill('100');
      await expect(calc.getByRole('alert')).toContainText('At least $20,000');
      await page.getByTestId('calc-amount').fill('50000');
      await page.getByTestId('calc-mode-pay').click();
      await expect(page.getByTestId('calc-monthly')).toHaveText('$1,250.00');
      await calc.screenshot({ path: `${SHOTS}/${test.info().project.name}-calculator.png` });
      await noOverflow(page);
      await page.context().close();
    } finally { await sql`select pg_advisory_unlock(${LOCK})`; }
  });

  test('Download PDF prints the slides alone, one landscape page each, with the notice', async ({ browser }) => {
    test.skip(isPhone(), 'printed once, from the desktop');
    test.setTimeout(240_000);
    await sql`select pg_advisory_lock(${LOCK})`;
    try {
      await sql`update deck_settings set show_to_investors = true`;
      const inv = await mkPerson(sql, 'investor', 'Riley Example');
      const page = await ctx(browser);
      await signIn(page, inv.email);
      await page.goto('/investor/deck', { waitUntil: 'networkidle' });
      await expect(page.getByTestId('deck')).toHaveAttribute('data-ready', 'true', { timeout: 60_000 });
      const n = await page.getByTestId('deck-slide').count();
      await expect(page.getByTestId('deck-pdf')).toBeVisible();
      // what the button does: the browser's print, with the print styles
      await page.evaluate(() => { (window as unknown as { printed: number }).printed = 0; window.print = () => { (window as unknown as { printed: number }).printed++; }; });
      await page.getByTestId('deck-pdf').click();
      expect(await page.evaluate(() => (window as unknown as { printed: number }).printed)).toBe(1);
      // every lazy image loaded before printing
      await page.evaluate(async () => { for (const i of Array.from(document.images)) { i.loading = 'eager'; } await Promise.all(Array.from(document.images).map((i) => i.complete ? null : new Promise((r) => { i.onload = r; i.onerror = r; }))); });
      await page.emulateMedia({ media: 'print' });
      const pdf = await page.pdf({ preferCSSPageSize: true, printBackground: true });
      writeFileSync(`${SHOTS}/deck.pdf`, pdf);
      const pages = (pdf.toString('latin1').match(/\/Type\s*\/Page[^s]/g) ?? []).length;
      expect(pages).toBe(n);
      const text = await pdfText(pdf);
      expect(text).toContain('CarmaCars');
      expect(text).toContain('not part of any offering memorandum');
      expect(text).toContain('prospectus exemptions');
      expect(text).not.toMatch(/Investments\s+Statements\s+Profile and notices/); // the portal menu is not printed
      expect(text).not.toMatch(/[—–]/);
      await page.context().close();
    } finally { await sql`select pg_advisory_unlock(${LOCK})`; }
  });

  test('the Admin previews the deck, changes its settings and hides it from investors', async ({ browser }) => {
    test.skip(isPhone(), 'the switch is global: changed once, from the desktop');
    test.setTimeout(240_000);
    await sql`select pg_advisory_lock(${LOCK})`;
    try {
      await sql`update deck_settings set show_to_investors = true, deck_multiplier = 3.2, deck_return_bps = 3000`;
      const admin = await mkPerson(sql, 'admin', 'Sam Example');
      const inv = await mkPerson(sql, 'investor', 'Jordan Example');
      const a = await ctx(browser);
      await signIn(a, admin.email);
      await a.goto('/admin/investors', { waitUntil: 'networkidle' });
      await expect(a.getByTestId('admin-deck-link')).toContainText('shown to investors');
      await a.getByTestId('admin-deck-link').click();
      await a.waitForURL('**/admin/investors/deck');
      await expect(a.getByTestId('deck-visibility')).toContainText('Investors see the deck');
      await expect(a.getByTestId('deck-multiplier')).toHaveText('3.2x');
      await check(a, 'admin deck');
      // a new multiplier and percentage, and hidden
      const form = a.getByTestId('deck-save-form');
      await form.getByLabel('Multiplier on the money we invest (x)').fill('3.5');
      await form.getByLabel('Yearly percentage of the current offer (%)').fill('24');
      await form.getByLabel('Show the deck to investors').uncheck();
      await a.getByTestId('deck-save-submit').click();
      await expect(a.getByTestId('deck-visibility')).toContainText('Hidden from investors', { timeout: 15_000 });
      await expect(a.getByTestId('deck-multiplier')).toHaveText('3.5x');
      await expect(a.locator('#offer')).toContainText('24% a year');
      const row = (await sql`select show_to_investors, deck_multiplier::text m, deck_return_bps from deck_settings`)[0]!;
      expect([row.show_to_investors, row.m, row.deck_return_bps]).toEqual([false, '3.50', 2400]);
      await shot(a, 'admin-preview');

      // the investor: no link, no deck
      const p = await ctx(browser);
      await signIn(p, inv.email);
      await p.goto('/investor', { waitUntil: 'networkidle' });
      await expect(p.getByTestId('deck-promo')).toHaveCount(0);
      await expect(p.getByTestId('nav-deck')).toHaveCount(0);
      await p.goto('/investor/deck', { waitUntil: 'networkidle' });
      await expect(p.getByTestId('deck-closed')).toBeVisible();
      await expect(p.getByTestId('deck')).toHaveCount(0);

      // shown again from Admin > Investors
      await a.goto('/admin/investors', { waitUntil: 'networkidle' });
      await a.getByTestId('deck-toggle').click();
      await a.getByRole('dialog').getByRole('button', { name: 'Show the deck to investors' }).click();
      await expect(a.getByTestId('admin-deck-link')).toContainText('shown to investors', { timeout: 15_000 });
      await p.goto('/investor/deck', { waitUntil: 'networkidle' });
      await expect(p.getByTestId('deck')).toBeVisible();
      await a.context().close(); await p.context().close();
    } finally {
      await sql`update deck_settings set show_to_investors = true, deck_multiplier = 3.2, deck_return_bps = 3000`;
      await sql`select pg_advisory_unlock(${LOCK})`;
    }
  });

  test('anyone else is turned away', async ({ browser }) => {
    const page = await ctx(browser);
    await page.goto('/investor/deck');
    await page.waitForURL((u) => u.pathname.startsWith('/sign-in'));
    const id = randomUUID(); const email = `renter.deck.${Date.now()}@example.test`;
    await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
    await sql`select public.register_account(${id}, ${email}, ${'Casey Example'}, null)`;
    await signIn(page, email);
    await page.goto('/investor/deck');
    await page.waitForURL('**/investor/no-access');
    await page.context().close();
  });
});
