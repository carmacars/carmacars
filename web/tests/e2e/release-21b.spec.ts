import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Release 21b end to end, at both widths: the "i" (InfoTip: opens on a click or a tap, Escape closes it and gives the focus
// back), the address lookup of the referral partner sign-up, and the academy (a lesson played with captions only, a quiz
// failed then passed, the next section opened; Admin's progress, Open early and the editor).
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text.match(/[–—]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(text, `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function mkUser(sql: Sql, role: 'admin' | 'va', va?: string) {
  const id = randomUUID(); const email = `r21b.${role}.${Date.now()}.${tag()}@example.test`; const name = role === 'admin' ? 'Ada Admin' : `Casey Trainee ${tag()}`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${va!}, 50000)`;
  return { id, email, name };
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
const quiet = (errors: string[]) => errors.filter((x) => !/favicon|Failed to load resource|net::ERR/.test(x));

test('the academy: a lesson with captions, a quiz failed then passed, the next section; Admin progress, Open early, the editor; the "i"', async ({ browser }, info) => {
  test.setTimeout(300_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const cs = await mkUser(sql, 'va', 'cs');
  const answers = await sql`select q.sort, q.answer, jsonb_array_length(q.options) n from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'prices-and-deposits' order by q.sort`;

  // ---- the staff member
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, cs.email, '/staff');
  await page.goto('/staff/academy', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('path-cs')).toBeVisible();
  await expect(page.getByTestId('section-coverage-and-drivers')).toContainText('Pass the one before');
  await check(page, 'academy home');
  await page.getByTestId('section-prices-and-deposits').getByRole('link').click();
  await page.waitForURL(/\/staff\/academy\/cs\/prices-and-deposits$/);
  // a lesson: play (captions only in the test browser), step through every scene, watched
  const player = page.getByTestId('player-0');
  await player.getByTestId('player-0-play').click();
  await expect(player.getByTestId('player-0-caption')).not.toContainText('Press Play');
  await expect(player.getByTestId('player-0-scene')).toContainText('Scene 1 of');
  await player.getByTestId('player-0-play').click(); // pause
  await expect(player.getByTestId('player-0-play')).toHaveText('Resume');
  const n = Number((await player.getByTestId('player-0-scene').innerText()).match(/of (\d+)/)![1]);
  for (let i = 0; i < n; i++) await player.getByTestId('player-0-next').click();
  await expect(page.getByTestId('lesson-0')).toContainText('Watched');
  await expect(player.getByTestId('player-0-progress')).toHaveAttribute('aria-valuenow', '100');
  await check(page, 'section');
  // the quiz: all wrong, then right
  for (const a of answers) await page.getByTestId(`q-${Number(a.sort) - 1}-${(Number(a.answer) + 1) % Number(a.n)}`).check();
  await page.getByTestId('quiz-submit').click();
  await expect(page.getByTestId('quiz-result')).toContainText('Not passed yet');
  await page.getByTestId('quiz-retry').click();
  for (const a of answers) await page.getByTestId(`q-${Number(a.sort) - 1}-${a.answer}`).check();
  await page.getByTestId('quiz-submit').click();
  await expect(page.getByTestId('quiz-result')).toContainText('Passed');
  await page.getByTestId('quiz-next').click();
  await page.waitForURL(/\/staff\/academy\/cs\/coverage-and-drivers$/);
  await expect(page.getByTestId('quiz')).toBeVisible();
  expect(quiet(errors)).toEqual([]);

  // ---- Admin: progress, Open early, the editor, and the "i"
  const ap = await ctx(browser, phone);
  const aerr = watch(ap);
  await signIn(ap, admin.email, '/admin');
  await ap.goto('/admin/academy', { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('academy-staff').locator('tr', { hasText: cs.name })).toContainText('1 of 6');
  // the "i": a button with its name; a click or a tap opens it, Escape closes it and gives the focus back
  const tip = ap.getByRole('button', { name: 'About the academy gate' });
  await (phone ? tip.tap() : tip.click());
  await expect(ap.getByRole('tooltip')).toContainText('Off (the default)');
  await check(ap, 'admin academy');
  await ap.keyboard.press('Escape');
  await expect(ap.getByRole('tooltip')).toHaveCount(0);
  await expect(tip).toBeFocused();
  await ap.goto(`/admin/academy/staff/${cs.id}`, { waitUntil: 'networkidle' });
  await ap.getByTestId('unlock-cs-requests').click();
  await ap.getByRole('dialog').getByLabel('Reason').fill('Two years of rental desk work');
  await ap.getByTestId('unlock-cs-requests-submit').click();
  await expect(ap.getByTestId('ap-cs')).toContainText('Opened early');
  await check(ap, 'admin academy person');
  const [sec] = await sql`select id from academy_sections where slug = 'commission'`;
  await ap.goto(`/admin/academy/sections/${sec!.id}`, { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('qe-1')).toContainText('(right answer)');
  await check(ap, 'academy editor');
  expect(quiet(aerr)).toEqual([]);

  // the early opening reaches the staff member
  await page.goto('/staff/academy', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('section-cs-requests')).toContainText('Opened by an Admin');
  await page.context().close(); await ap.context().close();
  await sql.end();
});

test('the referral partner sign-up: the address lookup fills the street, the city and the postal code', async ({ browser }, info) => {
  const phone = info.project.name.startsWith('phone');
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await page.goto('/partners/body-shops', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  const look = page.getByTestId('ps-lookup');
  await look.scrollIntoViewIfNeeded();
  await look.pressSequentially('100 Queen', { delay: 40 });
  const opt = page.getByRole('option').first();
  await expect(opt).toBeVisible({ timeout: 15_000 });
  await opt.click();
  await expect(page.getByTestId('ps-address_line1')).not.toHaveValue('', { timeout: 15_000 });
  await expect(page.getByTestId('ps-city')).not.toHaveValue('');
  await check(page, 'partner sign-up');
  expect(quiet(errors)).toEqual([]);
  await page.context().close();
});
