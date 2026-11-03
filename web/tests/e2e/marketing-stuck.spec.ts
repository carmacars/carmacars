import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Sales > Marketing and the "Stuck?" help (docs/changes/2026-11-07-marketing-and-stuck-help.md, migrations 0510 and 0511), at
// 375 and 1440 with axe. A salesperson opens Marketing: the car's variant 2 is already another salesperson's, so their kit is
// variant 3 (its own title, never "rent"), they claim it and log it as posted; the menu has Marketing and the old address
// lands there. Then the help: with a short timing (the browser's test setting), working on the page without a success shows
// "Need a hand with Marketing?", the guide opens beside the page at its chapter, "Back to what I was doing" leaves the page
// as it was (scroll and the chosen car kept), and "Not now" quiets it. Every address example.test.
const PW = 'correct horse battery';
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
type Sql = ReturnType<typeof db>;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function mkUser(sql: Sql, kind: 'admin' | 'sales', name: string) {
  const id = randomUUID(); const email = `${kind}.mk.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  else {
    await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
    await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'sales', 0)`;
  }
  return { id, email };
}
async function mkCar(sql: Sql, admin: string) {
  const vin = `3MKTG${randomBytes(6).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
  const model = `Camry ${tag()}`;
  const [made] = await sql`select app.vehicle_add(${admin}, ${sql.json({ supply_type: 'company', vin, plate: `MK${tag().toUpperCase()}`, year: 2023, make: 'Toyota', model,
    rates: { daily: 8900, weekend: 9900, weekly: 53400, monthly: 178000, deposit: 50000 } })}) as r`;
  const car = (made!.r as { vehicle_id: string }).vehicle_id;
  await sql`update vehicle_listings set status = 'published', published_at = now() where vehicle_id = ${car}`;
  for (const [i, shot] of ['front_left', 'rear', 'left'].entries()) {
    // plate checked (no plate in the shot): a photo with an unchecked plate is kept private (0070), so the kit would have none
    await sql`insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, processed_path, status, sort_order, is_cover, alt_text, variants, background_status, is_public, approved_at, plate_status)
              values (${car}, ${shot}, ${shot}, ${`original/mk/${car}/${i}.jpg`}, ${`mk/${car}/${i}.jpg`}, 'approved', ${i}, ${i === 0}, ${`2023 Toyota ${model}, photo ${i + 1}`}, ${sql.json([])}, 'done', true, now(), 'not_visible')`;
  }
  return { car, model };
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 120_000 });
}

test.describe.configure({ mode: 'serial' });

for (const phone of [false, true]) {
  test(`Sales Marketing ${phone ? 'at 375' : 'at 1440'}: their own variant, claimed and logged, never one already live`, async ({ browser }) => {
    test.setTimeout(300_000);
    const sql = db();
    const admin = await mkUser(sql, 'admin', 'Mk Admin');
    const other = await mkUser(sql, 'sales', 'Mk Other');
    const me = await mkUser(sql, 'sales', 'Mk Seller');
    const { car, model } = await mkCar(sql, admin.id);
    // a teammate already holds variant 2 of the car
    await sql`select app.mp_claim(${other.id}, ${sql.json({ vehicle: car, variant: 2, title: `2023 Toyota ${model} by the day or week, from $89/day`, cover: `mk/${car}/1.jpg`,
      body: 'Teammate copy. Daily and weekly bookings only, not for sale. Book it on carmacars.ca.' })})`;
    const page = await ctx(browser, phone);
    try {
      await signIn(page, me.email, `/staff/marketing?car=${car}`);
      await expect(page.getByRole('heading', { level: 1 })).toHaveText('Marketing', { timeout: 60_000 });
      await expect(page.getByTestId('mp-kit')).toContainText('variant 3');
      const desc = await page.getByTestId('mp-description').inputValue();
      expect(desc.split('\n')[0]).toBe(`Drive this 2023 Toyota ${model} this week: $89 a day.`);
      expect(desc.split('\n')[1]).toBe('Daily and weekly bookings only, not for sale.');
      expect(desc).not.toMatch(/\brent(al)?\b/i);
      expect(await page.getByTestId('mp-link').inputValue()).toContain('utm_content=v3');
      await expect(page.getByTestId('mk-autoreply-text')).toHaveValue(/not for sale/);
      await expect(page.getByTestId('mk-prompt')).toHaveValue(/CAPTCHA/);
      // the lesson in the person's own Academy path: a Sales assistant is in person unless set remote (0174)
      await expect(page.getByTestId('mk-academy')).toHaveAttribute('href', '/staff/academy/sales_in_person/marketplace-with-claude');
      await check(page, 'marketing');

      // claim variant 3 from the car's kit (the car need not be on today's list), then log it as posted
      await page.getByTestId('mk-kit-claim').click();
      await expect(page.getByTestId(`mk-posted-${car}`)).toBeVisible({ timeout: 30_000 });
      await page.getByTestId(`mk-posted-${car}`).click();
      await page.locator('dialog[open]').getByLabel(/listing's address/).fill(`https://www.facebook.com/marketplace/item/${Date.now()}/`);
      await page.getByTestId(`mk-posted-${car}-submit`).click();
      await expect(page.getByTestId('mk-mine')).toContainText('variant 3', { timeout: 30_000 });
      // (Your listings shows a claim as soon as it is made: wait for the Posted log itself)
      await expect.poll(async () => (await sql`select variant, status, poster_id from marketplace_claims where vehicle_id = ${car} and status <> 'ended' order by variant`)
        .map((r) => `${r.variant}:${r.status}:${r.poster_id === me.id ? 'me' : 'other'}`), { timeout: 30_000 }).toEqual(['2:claimed:other', '3:live:me']);
      const [log] = await sql`select kind, variant from marketplace_log where claim_id is not null and logged_by = ${me.id}`;
      expect(log).toMatchObject({ kind: 'posted', variant: 3 });

      // the menu and the old address
      expect(await page.locator('a[href="/staff/marketing"]').count()).toBeGreaterThan(0);
      await page.goto('/staff/marketplace', { waitUntil: 'networkidle' });
      expect(new URL(page.url()).pathname).toBe('/staff/marketing');
    } finally {
      await page.context().close();
      await sql.end();
    }
  });

  test(`Stuck? help ${phone ? 'at 375' : 'at 1440'}: the prompt, the guide beside the page, back with the page untouched, not now`, async ({ browser }) => {
    test.setTimeout(300_000);
    const sql = db();
    const admin = await mkUser(sql, 'admin', 'Mk Admin Two');
    const me = await mkUser(sql, 'sales', 'Mk Seller Two');
    await mkCar(sql, admin.id);
    const page = await ctx(browser, phone);
    // the test setting: the help fires after 2.5 seconds of work without a success instead of the 3 minutes of Settings
    await page.addInitScript(() => { try { localStorage.setItem('cc-stuck-idle-ms', '2500'); } catch { /* the help uses its default */ } });
    try {
      await signIn(page, me.email, '/staff/marketing');
      await expect(page.getByRole('heading', { level: 1 })).toHaveText('Marketing', { timeout: 60_000 });
      const pick = page.getByTestId('mp-car');
      const options = await pick.locator('option').evaluateAll((os) => os.map((o) => (o as HTMLOptionElement).value));
      const chosen = options[options.length - 1]!;
      await pick.selectOption(chosen);
      await page.evaluate(() => window.scrollTo(0, 600));
      const y = await page.evaluate(() => window.scrollY);
      await page.keyboard.press('Shift');
      const prompt = page.getByTestId('stuck-prompt');
      await expect(prompt).toBeVisible({ timeout: 20_000 });
      await expect(prompt).toContainText('Need a hand with Marketing?');
      await expect(page.getByTestId('stuck-lesson')).toHaveAttribute('href', '/staff/academy/sales_remote/marketplace-with-claude');
      await check(page, 'stuck prompt');

      await page.getByTestId('stuck-guide').click();
      const panel = page.getByTestId('stuck-panel');
      await expect(panel.locator('#stk-title')).toBeVisible({ timeout: 20_000 });
      await expect(panel.locator('#stk-title')).toHaveText(/Marketing on Facebook Marketplace|The guide/);
      const box = (await panel.boundingBox())!;
      const vp = page.viewportSize()!;
      if (phone) { expect(box.y + box.height).toBeGreaterThanOrEqual(vp.height - 1); expect(box.width).toBeGreaterThanOrEqual(vp.width - 20); }
      else { expect(box.x + box.width).toBeGreaterThanOrEqual(vp.width - 20); expect(box.width).toBeLessThan(vp.width / 2); }
      await check(page, 'stuck panel');
      await page.getByTestId('stuck-back').click();
      await expect(panel).toHaveCount(0);
      expect(await pick.inputValue()).toBe(chosen);
      expect(await page.evaluate(() => window.scrollY)).toBe(y);

      // Not now: quiet on this page
      await page.reload({ waitUntil: 'networkidle' });
      await page.evaluate(() => localStorage.removeItem(`cc-stuck-snooze:/staff/marketing`));
      await page.reload({ waitUntil: 'networkidle' });
      await page.keyboard.press('Shift');
      await expect(prompt).toBeVisible({ timeout: 20_000 });
      await page.getByTestId('stuck-snooze').click();
      await expect(prompt).toHaveCount(0);
      await page.reload({ waitUntil: 'networkidle' });
      await page.keyboard.press('Shift');
      await page.waitForTimeout(4000);
      await expect(prompt).toHaveCount(0);
      await expect.poll(async () => (await sql`select array_agg(distinct action order by action) as a from help_stuck_events where user_id = ${me.id}`)[0]!.a, { timeout: 10_000 })
        .toEqual(['back', 'guide', 'shown', 'snooze']);
    } finally {
      await page.context().close();
      await sql.end();
    }
  });
}
