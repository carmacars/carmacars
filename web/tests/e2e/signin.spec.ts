import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, watch } from './helpers';

// Sign-in for every portal (migration 0036, docs/changes/2026-10-14-sign-in.md): each role lands on its portal,
// a person with several portals chooses, refusal pages say who is signed in and offer their portals, an Admin
// views any portal as one of its people (read only, every write refused, recorded), invitations into any role land
// on /update-password and then the portal, expired links offer a new one, and sign-out.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => `${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`;
const clean = (e: string[]) => e.filter((x) => !/favicon|_local\/|Failed to load resource.*(404|403)/.test(x));

async function mkPerson(sql: Sql, name: string, roles: Array<'admin' | 'va' | 'field' | 'renter' | 'owner' | 'investor'>, opts: { va?: string; cover?: string[] } = {}) {
  const id = randomUUID(); const email = `si.${roles.join('-')}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (roles.includes('renter')) await sql`select public.register_account(${id}, ${email}, ${name}, null)`;
  else await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  for (const r of roles) if (['admin', 'va', 'field', 'owner'].includes(r)) await sql`insert into user_roles (user_id, role) values (${id}, ${r}) on conflict do nothing`;
  if (roles.includes('va')) await sql`insert into staff_profiles (user_id, staff_type, va_function, cover_functions) values (${id}, 'va', ${opts.va ?? 'cs'}, ${opts.cover ?? []}::va_function[])`;
  if (roles.includes('field')) await sql`insert into staff_profiles (user_id, staff_type, field_function) values (${id}, 'field', 'driver')`;
  if (roles.includes('owner')) await sql`insert into owners (user_id, owner_type, legal_name, status, email) values (${id}, 'individual', ${name}, 'active', ${email})`;
  if (roles.includes('investor')) await sql`insert into investors (user_id, legal_name, investor_type, status, email) values (${id}, ${name}, 'individual', 'active', ${email})`;
  return { id, email, name };
}
async function newPage(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function signIn(page: Page, email: string, next = '') {
  await page.goto(`/sign-in${next ? `?next=${encodeURIComponent(next)}` : ''}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('#si-email').fill(email);
  await page.locator('#si-pass').fill(PW);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 20_000 });
}
const path = (page: Page) => new URL(page.url()).pathname;

test('sign-in: each role lands on its own portal; refusal pages name the account and offer its portals', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const people = {
    admin: await mkPerson(sql, 'Ada Admin', ['admin']),
    va: await mkPerson(sql, 'Fin Assistant', ['va'], { va: 'finance' }),
    field: await mkPerson(sql, 'Finn Field', ['field']),
    owner: await mkPerson(sql, 'Olive Owner', ['owner']),
    investor: await mkPerson(sql, 'Ivan Investor', ['investor']),
    renter: await mkPerson(sql, 'Riley Renter', ['renter'])
  };
  const home = { admin: '/admin', va: '/va', field: '/field', owner: '/owner', investor: '/investor', renter: '/account' } as const;
  for (const [role, p] of Object.entries(people) as Array<[keyof typeof home, { email: string }]>) {
    const page = await newPage(browser, phone);
    const errors = watch(page);
    await signIn(page, p.email);
    expect(path(page), `${role} lands on ${home[role]}`).toBe(home[role]);
    await expect(page.locator('h1').first()).toBeVisible();
    if (role === 'admin') {
      // an Admin is refused the other portals by role, and the page says who is signed in and offers Admin and Portals
      await page.goto('/owner');
      await expect(page).toHaveURL(/\/owner\/not-an-owner/);
      await expect(page.getByTestId('no-access-email')).toHaveText(p.email);
      await expect(page.getByTestId('my-portals').getByRole('link', { name: 'Admin' })).toBeVisible();
      await expect(page.getByRole('link', { name: 'Admin > Portals' })).toBeVisible();
      await page.goto('/va');
      await expect(page).toHaveURL(/\/va\/no-access/);
      await expect(page.getByTestId('no-access')).toContainText('This area is for CarmaCars staff');
      await expect(page.getByRole('button', { name: 'Sign out' })).toBeVisible();
    }
    if (role === 'renter') {
      await page.goto('/admin');
      await expect(page).toHaveURL(/\/admin\/no-access/);
      await expect(page.getByTestId('no-access-email')).toHaveText(p.email);
      await expect(page.getByTestId('my-portals').getByRole('link', { name: 'My rentals' })).toBeVisible();
      await page.getByRole('button', { name: 'Sign out' }).click();
      await page.waitForURL((u) => u.pathname === '/');
      await page.goto('/account');
      await expect(page).toHaveURL(/\/sign-in\?next=/);
    }
    expect(clean(errors), role).toEqual([]);
    await page.context().close();
  }
  // ?next= is honoured, and only on this site
  const page = await newPage(browser, phone);
  await signIn(page, people.owner.email, '/owner/profile');
  expect(path(page)).toBe('/owner/profile');
  await page.context().close();
  const page2 = await newPage(browser, phone);
  await signIn(page2, people.owner.email, '//evil.example/x');
  expect(path(page2)).toBe('/owner');
  await page2.context().close();
  await sql.end();
});

test('sign-in: several portals: choose one, and each frame links to the others', async ({ browser }, info) => {
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const p = await mkPerson(sql, 'Multi Person', ['admin', 'va', 'owner'], { va: 'finance', cover: ['fleet'] });
  const page = await newPage(browser, phone);
  const errors = watch(page);
  await signIn(page, p.email);
  expect(path(page)).toBe('/choose-portal');
  const list = page.getByTestId('choose-portal');
  await expect(list.getByRole('link')).toHaveText(['Admin', 'Staff portal: Finance', 'Staff portal: Fleet', 'Owner portal']);
  await list.getByRole('link', { name: 'Staff portal: Fleet' }).click();
  await page.waitForURL((u) => u.pathname === '/va');
  await expect(page.getByTestId('fn-switch').getByRole('button', { name: 'Fleet' })).toHaveAttribute('aria-pressed', 'true');
  await page.getByTestId('portal-switch').getByRole('link', { name: 'Owner portal' }).click();
  await page.waitForURL((u) => u.pathname === '/owner');
  await page.getByTestId('portal-switch').getByRole('link', { name: 'Admin' }).click();
  await page.waitForURL((u) => u.pathname === '/admin');
  expect(clean(errors)).toEqual([]);
  await page.context().close();
  await sql.end();
});

test('sign-in: a wrong password reads the same as an unknown address, with the way to set a password', async ({ page }) => {
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const p = await mkPerson(sql, 'Wrong Pass', ['renter']);
  for (const email of [p.email, `nobody.${tag()}@example.test`]) {
    await page.goto('/sign-in');
    await acceptCookies(page);
    await page.locator('#si-email').fill(email);
    await page.locator('#si-pass').fill('not the password');
    await page.getByRole('button', { name: 'Sign in', exact: true }).click();
    await expect(page.locator('.alert--error')).toHaveText('That email and password do not match an account.');
    await expect(page.getByTestId('signin-hint')).toContainText('Set a new password');
  }
  await sql.end();
});

test('view as: an Admin opens each portal as one of its people, read only, recorded, and exits', async ({ browser }, info) => {
  test.setTimeout(240_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkPerson(sql, 'Ada Admin', ['admin']);
  const owner = await mkPerson(sql, 'Olive Viewed', ['owner']);
  const va = await mkPerson(sql, 'Val Viewed', ['va'], { va: 'cs', cover: ['fleet'] });
  const field = await mkPerson(sql, 'Finn Viewed', ['field']);
  const investor = await mkPerson(sql, 'Ivan Viewed', ['investor']);
  const renter = await mkPerson(sql, 'Riley Viewed', ['renter']);
  const page = await newPage(browser, phone);
  const errors = watch(page);
  await signIn(page, admin.email);
  await page.goto('/admin/portals');
  await expect(page.getByTestId('portal-list')).toContainText('Staff portal: Fleet');
  const open = async (section: string, who: { id: string; email: string }, expectPath: string) => {
    await page.goto(`/admin/portals?q=${encodeURIComponent(who.email)}`);
    const form = page.getByTestId(`open-as-${section}`);
    await form.locator('select').selectOption(who.id);
    await form.getByRole('button', { name: 'Open as this person' }).click();
    await page.waitForURL((u) => u.pathname.startsWith(expectPath));
    await expect(page.getByTestId('view-as-banner')).toContainText('read only');
  };
  // the owner portal, with the owner's own data
  await open('owner', owner, '/owner');
  await expect(page.getByTestId('view-as-banner')).toContainText(`Viewing as Olive Viewed (${owner.email}), read only.`);
  await expect(page.getByTestId('account-email')).toHaveText(owner.email);
  await expect(page.getByRole('button', { name: 'Exit view' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Sign out' })).toHaveCount(0);
  // a write is refused: the save goes to the read-only page and nothing changes
  await page.goto('/owner/profile');
  await page.locator('#ow-pr-phone').fill('416-555-0199');
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await page.waitForURL((u) => u.pathname === '/read-only');
  await expect(page.getByTestId('read-only')).toContainText('nothing was changed');
  expect((await sql`select phone from owners where user_id = ${owner.id}`)[0]!.phone).toBeNull();
  // and at the HTTP level, any POST outside Admin
  const refused = await page.request.post('/owner/profile', { data: 'x', headers: { 'content-type': 'text/plain' } });
  expect(refused.status()).toBe(403);
  expect(await refused.text()).toMatch(/^Read only/);
  // the staff portal in a function they cover; their switcher is not offered while viewing
  await open('va-fleet', va, '/va');
  await expect(page.getByTestId('account-email')).toHaveText('Val Viewed');
  await expect(page.getByTestId('fn-switch')).toHaveCount(0);
  await expect(page.locator('.ad__who')).toContainText('Fleet');
  await open('field', field, '/field');
  await expect(page.locator('h1').first()).toBeVisible();
  await open('investor', investor, '/investor');
  await expect(page.locator('h1').first()).toBeVisible();
  // the renter portal reads with the renter's identity (row-level security, a token made for them)
  await open('account', renter, '/account');
  await expect(page.getByTestId('account-email')).toHaveText(renter.email);
  // in Admin the Admin is themselves, and Admin actions still work
  await page.goto('/admin');
  await expect(page.getByTestId('view-as-banner')).toContainText('Here in Admin you are yourself');
  await expect(page.locator('.ad__who')).toContainText('Ada Admin');
  // every start is in the audit log
  expect((await sql`select count(*)::int n from audit_log where action = 'view_as_start' and actor_user_id = ${admin.id}`)[0]!.n).toBe(5);
  // Exit: back to Admin > Portals, the portal is the Admin's own again
  await page.goto('/owner');
  await page.getByTestId('view-as-exit').click();
  await page.waitForURL((u) => u.pathname === '/admin/portals');
  await expect(page.getByTestId('view-as-banner')).toHaveCount(0);
  await page.goto('/owner');
  await expect(page).toHaveURL(/not-an-owner/);
  expect(clean(errors).filter((e) => !/403/.test(e))).toEqual([]);
  await page.context().close();
  await sql.end();
});

test('view as: the cookie only counts for the Admin who set it, while they are an Admin', async ({ browser }, info) => {
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkPerson(sql, 'Ada Admin', ['admin']);
  const owner = await mkPerson(sql, 'Olive Target', ['owner']);
  const other = await mkPerson(sql, 'Other Renter', ['renter']);
  const a = await newPage(browser, phone);
  await signIn(a, admin.email);
  await a.goto(`/admin/portals?q=${encodeURIComponent(owner.email)}`);
  const form = a.getByTestId('open-as-owner');
  await form.locator('select').selectOption(owner.id);
  await form.getByRole('button', { name: 'Open as this person' }).click();
  await a.waitForURL((u) => u.pathname.startsWith('/owner'));
  const cookie = (await a.context().cookies()).find((c) => c.name === 'cc-view-as')!;
  expect(cookie.httpOnly).toBe(true);
  // another person who copies the cookie still sees only their own account
  const b = await newPage(browser, phone);
  await signIn(b, other.email);
  await b.context().addCookies([{ ...cookie }]);
  await b.goto('/owner');
  await expect(b).toHaveURL(/not-an-owner/);
  await expect(b.getByTestId('no-access-email')).toHaveText(other.email);
  // the Admin loses the role: the view ends with it
  await sql`delete from user_roles where user_id = ${admin.id} and role = 'admin'`;
  await a.goto('/owner');
  await expect(a).toHaveURL(/not-an-owner/);
  await a.context().close(); await b.context().close();
  await sql.end();
});

test('invite: an Admin invites an assistant and an owner on file; each chooses a password and lands in their portal', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkPerson(sql, 'Ada Admin', ['admin']);
  const t = tag();
  const ownerRec = randomUUID();
  await sql`insert into owners (id, owner_type, legal_name, status, email) values (${ownerRec}, 'individual', ${`Owen Onfile ${t}`}, 'active', ${`owen.${t}@example.test`})`;
  const page = await newPage(browser, phone);
  await signIn(page, admin.email);
  await page.goto('/admin/portals');
  const f = page.getByTestId('invite-form');
  await f.getByLabel('Role').selectOption('va');
  await f.getByLabel('Name').fill('Nina New');
  await f.getByLabel('Email').fill(`nina.${t}@example.test`);
  await f.getByLabel('Main function').selectOption('finance');
  await f.getByLabel('Sales').check();
  await f.getByRole('button', { name: 'Invite' }).click();
  await expect(f.getByRole('status')).toContainText(`Invitation sent to nina.${t}@example.test`);
  await f.getByLabel('Role').selectOption('owner');
  await f.getByLabel('Owner', { exact: true }).selectOption(ownerRec);
  await f.getByRole('button', { name: 'Invite' }).click();
  await expect(f.getByRole('status')).toContainText(`Invitation sent to owen.${t}@example.test`);
  expect((await sql`select va_function::text || '+' || cover_functions::text v from staff_profiles sp join users u on u.id = sp.user_id where u.email = ${`nina.${t}@example.test`}`)[0]!.v).toBe('finance+{sales}');
  await page.context().close();
  for (const [email, landing] of [[`nina.${t}@example.test`, '/va'], [`owen.${t}@example.test`, '/owner']] as const) {
    const m = await sql`select link from local_auth.mailbox where to_email = ${email} order by id desc limit 1`;
    expect(m[0]?.link, email).toContain('/update-password?token=');
    const p = await newPage(browser, phone);
    const u = new URL(m[0]!.link as string);
    await p.goto(u.pathname + u.search);
    await p.locator('#np-pass').fill('a brand new password');
    await p.getByRole('button', { name: 'Save the new password' }).click();
    await p.waitForURL((x) => x.pathname === landing, { timeout: 20_000 });
    await expect(p.locator('h1').first()).toBeVisible();
    await p.context().close();
  }
  // the second use of the same link is refused, and offers a new one
  const m = await sql`select link from local_auth.mailbox where to_email = ${`nina.${t}@example.test`} order by id desc limit 1`;
  const p = await newPage(browser, phone);
  const u = new URL(m[0]!.link as string);
  await p.goto(u.pathname + u.search);
  await p.locator('#np-pass').fill('another new password');
  await p.getByRole('button', { name: 'Save the new password' }).click();
  await expect(p.locator('.alert--error')).toContainText('expired or was already used');
  await p.getByLabel('Email').fill(`nina.${t}@example.test`);
  await p.getByRole('button', { name: 'Send me a new link' }).click();
  await expect(p.getByText('Check your email')).toBeVisible();
  expect((await sql`select count(*)::int n from local_auth.mailbox where to_email = ${`nina.${t}@example.test`}`)[0]!.n).toBe(2);
  await p.context().close();
  await sql.end();
});

test('links: an expired link and a password page without one offer a new link in one step; Admin sends a password link', async ({ browser }, info) => {
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkPerson(sql, 'Ada Admin', ['admin']);
  const r = await mkPerson(sql, 'Riley Link', ['renter']);
  const page = await newPage(browser, phone);
  await page.goto('/link-expired?kind=password');
  await acceptCookies(page);
  await expect(page.getByTestId('link-expired')).toContainText('expired or was already used');
  await page.getByLabel('Email').fill(r.email);
  await page.getByRole('button', { name: 'Send me a new link' }).click();
  await expect(page.getByText('Check your email')).toBeVisible();
  // the address asked with on this device is filled in next time
  await page.goto('/update-password');
  await expect(page.getByTestId('link-expired')).toBeVisible();
  await expect(page.getByLabel('Email')).toHaveValue(r.email);
  // a callback link that does not verify goes to the same page
  await page.goto('/auth/callback?token_hash=nope&type=invite&next=/update-password');
  await expect(page).toHaveURL(/\/link-expired\?kind=invite/);
  await expect(page.getByTestId('link-expired')).toContainText('invitation link has expired');
  // Admin > Portals: a password link for anyone
  await signIn(page, admin.email);
  await page.goto(`/admin/portals?q=${encodeURIComponent(r.email)}`);
  page.once('dialog', (d) => d.accept());
  await page.getByTestId(`pw-${r.email}`).click();
  await expect(page.getByText(`Sent to ${r.email}.`)).toBeVisible();
  expect((await sql`select count(*)::int n from audit_log where action = 'send_password_link' and entity_id = ${r.id}`)[0]!.n).toBe(1);
  expect((await sql`select count(*)::int n from local_auth.mailbox where to_email = ${r.email}`)[0]!.n).toBe(2);
  await page.context().close();
  await sql.end();
});
