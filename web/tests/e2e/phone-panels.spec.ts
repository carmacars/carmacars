import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, labelsInButtons, noOverflow, panelFits } from './helpers';

// Release 46 (the owner: "on mobile a bunch of things don't show up properly, like What's new and Report a bug; the text
// goes off the sides"). At 375 and 320 px: the top row's labels stay inside their buttons, and the shared pop-ups (What's
// new, Report a bug, the assistant) open inside the screen with nothing past either side, in the Admin portal, a staff
// portal and the renter portal. Phone project only (the widths are the point).
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => test.info().project.name.includes('phone');

async function mkUser(sql: Sql, role: 'admin' | 'va' | 'renter') {
  const id = randomUUID(); const email = `${role}.pp.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Pat Panel ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, staff_type, va_function, home_address, home_postal_code, onboarding_exempt) values (${id}, 'va', 'cs', '1 Example Lane, Testville', 'X9X 9X9', true)`;
  return { id, email };
}
async function signIn(page: Page, email: string, home: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(home), { timeout: 20_000 });
}
async function phonePage(browser: Browser) {
  const c = await browser.newContext({ viewport: { width: 375, height: 812 }, hasTouch: true, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}

async function sweep(page: Page, path: string, panels: { open: string; panel: string }[]) {
  for (const width of [375, 320]) {
    await page.setViewportSize({ width, height: 740 });
    await page.goto(path, { waitUntil: 'networkidle' });
    await noOverflow(page);
    await labelsInButtons(page);
    for (const p of panels) {
      const opener = page.getByTestId(p.open).first();
      if (!(await opener.isVisible().catch(() => false))) continue; // not on this portal (the assistant is off for some functions)
      await opener.click();
      const panel = page.getByTestId(p.panel);
      await panelFits(page, panel);
      await page.keyboard.press('Escape');
      await expect(panel).toBeHidden();
    }
  }
}

test.describe.configure({ mode: 'serial' });

test('the shared pop-ups fit a phone in the Admin, staff and renter portals (375 and 320)', async ({ browser }) => {
  test.skip(!isPhone(), 'phone widths only');
  test.setTimeout(150_000);
  const sql = db();
  const people = await Promise.all([mkUser(sql, 'admin'), mkUser(sql, 'va'), mkUser(sql, 'renter')]);
  try {
    const [admin, staff, renter] = people;
    const shared = [{ open: 'whats-new-link', panel: 'whats-new' }, { open: 'bug-report-open', panel: 'bug-report-dialog' }, { open: 'assistant-open', panel: 'assistant-panel' }];
    const a = await phonePage(browser); await signIn(a, admin!.email, '/admin'); await sweep(a, '/admin', shared);
    // What's new and Report a bug must be there in the Admin portal (the others may lack a release note for the portal)
    await expect(a.getByTestId('whats-new-link')).toBeVisible();
    await expect(a.getByTestId('bug-report-open')).toBeVisible();
    const s = await phonePage(browser); await signIn(s, staff!.email, '/staff'); await sweep(s, '/staff', shared);
    const r = await phonePage(browser); await signIn(r, renter!.email, '/account'); await sweep(r, '/account', shared);
  } finally {
    for (const p of people) {
      await sql`delete from users where id = ${p.id}`.catch(() => undefined);
      await sql`delete from local_auth.users where id = ${p.id}`.catch(() => undefined);
    }
    await sql.end().catch(() => undefined);
  }
});
