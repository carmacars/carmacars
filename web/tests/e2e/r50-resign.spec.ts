import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, pickDate } from './helpers';

// Release 50 (5020), end to end at phone widths (320 and 375): a field staff member resigns on their profile (Resign, the
// last section): the last day starts at today + 7, the confirm step says what happens next, the confirmation shows, and
// Withdraw my resignation is there until the last day. The Admin sees Resigning with the last day and the reason on Staff
// and roles, changes the last day, and the person withdraws. A VA still in onboarding resigns today from Welcome: the
// confirmation stays on screen with Sign out, and the access has ended. Every page: no sideways scroll, no serious axe
// finding, no raw database error.
type Sql = ReturnType<typeof db>;
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect(await page.locator('body').innerText(), `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function mkUser(sql: Sql, role: 'admin' | 'va' | 'field', name: string, o: { fn?: string; onboarding?: boolean } = {}) {
  const id = randomUUID(); const email = `r50.rs.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents, started_on, onboarding_exempt)
                               values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${o.fn ?? 'cs'}, 0, current_date - 200, ${!o.onboarding})`;
  if (role === 'field') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function, started_on, onboarding_exempt)
                                  values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver', current_date - 200, true)`;
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
async function phone(browser: Browser, width: number) {
  const c = await browser.newContext({ viewport: { width, height: 812 }, hasTouch: true, baseURL: test.info().project.use.baseURL });
  const p = await c.newPage();
  p.on('dialog', (d) => void d.accept());
  return p;
}
const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
const plusDays = (n: number) => ymd(new Date(Date.now() + n * 86_400_000));

test.describe.configure({ mode: 'serial' });
test.setTimeout(240_000);

test('resign: a field staff member resigns, the Admin sees it and moves the last day, the person withdraws', async ({ browser }) => {
  test.skip(test.info().project.name !== 'phone-375', 'one run is enough: each page is opened at 320 and 375 wide inside');
  const sql = db();
  const t = tag();
  const admin = await mkUser(sql, 'admin', `Ada Admin ${t}`);
  const field = await mkUser(sql, 'field', `Fin Field ${t}`);

  for (const width of [320, 375]) {
    const p = await phone(browser, width);
    await signIn(p, field.email, '/staff');
    await p.goto('/staff/field/profile#resign', { waitUntil: 'networkidle' });
    const sec = p.getByTestId('profile-resign');
    await expect(sec.getByRole('heading', { name: 'Resign' })).toBeVisible();
    await check(p, `profile ${width}`);
    if (width === 320) { await p.context().close(); continue; }

    // the form: the last day starts at today + 7; a reason; Continue
    await sec.getByTestId('resign-open').click();
    await expect(sec.getByTestId('resign-day')).toHaveAttribute('data-value', plusDays(7));
    const box = await sec.getByTestId('resign-open').or(sec.getByTestId('resign-continue')).boundingBox();
    expect(box?.height ?? 0).toBeGreaterThanOrEqual(44);
    await pickDate(p, 'My last day', plusDays(7), { scope: sec });
    await sec.getByTestId('resign-reason').fill('Moving to another city');
    await sec.getByTestId('resign-continue').click();
    // the confirm step says what happens next
    const next = sec.getByTestId('resign-next');
    await expect(next).toContainText('You keep working as usual');
    await expect(next).toContainText('vacation pay');
    await expect(next).toContainText('Withdraw it here');
    await check(p, 'confirm step');
    await sec.getByTestId('resign-submit').click();
    await expect(sec.getByTestId('resign-done')).toContainText('Your resignation is in');
    await sec.getByTestId('resign-close').click();
    await expect(sec.getByTestId('resign-pending')).toContainText('Your last day is');
    await check(p, 'pending');
    const [rec] = await sql`select status, reason, last_day::text as last_day from staff_resignations where user_id = ${field.id}`;
    expect(rec).toMatchObject({ status: 'pending', reason: 'Moving to another city', last_day: plusDays(7) });
    const [todo] = await sql`select count(*)::int as n from tasks t join staff_resignations r on r.task_id = t.id where r.user_id = ${field.id} and t.status = 'open'`;
    expect(todo.n).toBe(1);

    // the Admin: Resigning with the last day, the reason and the To do; Change last day
    const ap = await phone(browser, 375);
    await signIn(ap, admin.email, '/admin');
    await ap.goto('/admin/settings/staff', { waitUntil: 'networkidle' });
    const badge = ap.getByTestId(`resign-${field.email}`);
    await expect(badge).toContainText('Resigning: last day');
    await expect(badge).toContainText('Moving to another city');
    await expect(ap.getByTestId(`resign-todo-${field.email}`)).toBeVisible();
    await check(ap, 'admin staff');
    await ap.getByTestId(`resign-day-${field.email}`).click();
    await pickDate(ap, 'Last day', plusDays(3), { scope: ap.locator('dialog[open]') });
    await ap.getByTestId(`resign-day-${field.email}-submit`).click();
    await expect(ap.locator('dialog[open]')).toHaveCount(0);
    const [moved] = await sql`select last_day::text as d from staff_resignations where user_id = ${field.id} and status = 'pending'`;
    expect(moved.d).toBe(plusDays(3));
    await ap.context().close();

    // the person withdraws
    await p.reload({ waitUntil: 'networkidle' });
    await sec.getByTestId('resign-withdraw').click();
    await sec.getByTestId('resign-withdraw-confirm').click();
    await expect(sec.getByTestId('resign-open')).toBeVisible();
    const [w] = await sql`select status from staff_resignations where user_id = ${field.id} order by created_at desc limit 1`;
    expect(w.status).toBe('withdrawn');
    await p.context().close();
  }
  await sql.end();
});

test('resign: someone in onboarding leaves today from Welcome and the access ends after the confirmation', async ({ browser }) => {
  test.skip(test.info().project.name !== 'phone-375', 'one run is enough');
  const sql = db();
  const va = await mkUser(sql, 'va', `Ona Onboarding ${tag()}`, { fn: 'fleet', onboarding: true });
  const p = await phone(browser, 320);
  await signIn(p, va.email, '/staff');
  await p.goto('/staff/welcome', { waitUntil: 'networkidle' });
  const sec = p.getByTestId('profile-resign');
  await sec.getByTestId('resign-open').click();
  await pickDate(p, 'My last day', ymd(new Date()), { scope: sec });
  await sec.getByTestId('resign-continue').click();
  await expect(sec.getByTestId('resign-next')).toContainText('Your access ends as soon as you confirm');
  await check(p, 'welcome confirm 320');
  await sec.getByTestId('resign-submit').click();
  await expect(sec.getByTestId('resign-done')).toContainText('Your access has ended');
  await expect(sec.getByTestId('resign-signout')).toBeVisible();
  await check(p, 'welcome done 320');
  const [u] = await sql`select status from users where id = ${va.id}`;
  expect(u.status).toBe('suspended');
  await p.context().close();
  await sql.end();
});
