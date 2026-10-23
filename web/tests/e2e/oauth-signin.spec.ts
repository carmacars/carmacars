import { expect, test, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Sign in with Google, end to end, against the local stand-in for the provider (/auth/oauth/fake; the local stack runs
// with AUTH_OAUTH_PROVIDERS=google from .env.example). A new account gets what the create-account form gives (the users
// row, the renter role, the address confirmed and one welcome) and no confirmation email; an existing account with the
// same verified address is the same account; an account whose address was never confirmed loses the password someone
// chose for it; an address the provider did not verify is refused; a guest's booking-request record becomes the
// account; staff with an authenticator still get the two-step code before their portal.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const addr = (tag: string) => `g.${tag}.${Date.now()}.${Math.floor(Math.random() * 1e5)}@example.test`;
const path = (page: Page) => new URL(page.url()).pathname;

// RFC 6238, as an authenticator app computes it
function totp(secret: string, t = Date.now()) {
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; let bits = '';
  for (const c of secret) bits += A.indexOf(c).toString(2).padStart(5, '0');
  const key = Buffer.from(bits.match(/.{8}/g)!.map((b) => parseInt(b, 2)));
  const ctr = Buffer.alloc(8); ctr.writeBigUInt64BE(BigInt(Math.floor(t / 30_000)));
  const h = createHmac('sha1', key).update(ctr).digest(); const o = h[h.length - 1]! & 0xf;
  return String((h.readUInt32BE(o) & 0x7fffffff) % 1_000_000).padStart(6, '0');
}

/** "Continue with Google" on a page, then the stand-in's consent page: the address (and name) the provider vouches for. */
async function google(page: Page, from: string, who: { email: string; name?: string; verified?: boolean }) {
  await page.goto(from, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  const btn = page.getByTestId('oauth-google');
  await expect(btn).toHaveText('Continue with Google');
  await expect(btn.locator('svg')).toBeVisible();
  await btn.click();
  await page.waitForURL((u) => u.pathname === '/auth/oauth/fake');
  await page.getByTestId('fake-oauth-email').fill(who.email);
  if (who.name) await page.getByTestId('fake-oauth-name').fill(who.name);
  if (who.verified === false) await page.getByTestId('fake-oauth-verified').uncheck();
  await page.getByTestId('fake-oauth-continue').click();
}
async function passwordSignIn(page: Page, email: string) {
  await page.goto('/sign-in');
  await page.locator('#si-email').fill(email);
  await page.locator('#si-pass').fill(PW);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
}
const authUsers = (sql: Sql, email: string) => sql`select id::text, email_confirmed_at is not null confirmed, password_hash from local_auth.users where email = ${email}`;

test.beforeEach(async ({}, info) => {
  // one viewport is enough for the flow; the buttons' layout is checked on the phone width below
  test.skip(info.project.name !== 'desktop-1440', 'desktop only');
});

test('the buttons: shown on sign-in and create account, neutral Google button with the G, no overflow on a phone', async ({ browser }) => {
  const page = await (await browser.newContext({ viewport: { width: 375, height: 812 }, hasTouch: true, baseURL: test.info().project.use.baseURL })).newPage();
  const errors = watch(page);
  for (const p of ['/sign-in', '/create-account']) {
    await page.goto(p, { waitUntil: 'networkidle' });
    const btn = page.getByTestId('oauth-google');
    await expect(btn).toBeVisible();
    expect(await btn.getAttribute('href')).toContain(`/auth/oauth?provider=google&intent=${p === '/sign-in' ? 'signin' : 'signup'}`);
    const bg = await btn.evaluate((e) => getComputedStyle(e).backgroundColor);
    expect(bg).toBe('rgb(255, 255, 255)');
    await expect(page.getByTestId('oauth')).toContainText('Terms of use');
    await noOverflow(page);
  }
  // the next page asked for rides along
  await page.goto('/sign-in?next=/owner');
  expect(await page.getByTestId('oauth-google').getAttribute('href')).toContain('next=%2Fowner');
  // a provider that is not switched on is refused at the start
  await page.goto('/auth/oauth?provider=facebook');
  await expect(page).toHaveURL(/\/sign-in\?oauth=off/);
  await expect(page.getByTestId('oauth-error')).toContainText('not available');
  expect(errors).toEqual([]);
});

test('a new account by Google: users row, renter role, address confirmed, one welcome, no confirmation email; the next Google sign-in is the same account', async ({ page }) => {
  const sql = db();
  const email = addr('new');
  await google(page, '/create-account', { email, name: 'Gail Google' });
  await page.waitForURL((u) => u.pathname === '/account', { timeout: 20_000 });
  const [a] = await authUsers(sql, email);
  expect(a!.confirmed).toBe(true);
  expect(a!.password_hash).toMatch(/^oauth\$/);
  const [u] = await sql`select id::text, full_name, email_verified_at is not null verified from users where email = ${email}`;
  expect(u).toEqual({ id: a!.id, full_name: 'Gail Google', verified: true });
  const roles = await sql`select role::text from user_roles where user_id = ${a!.id}`;
  expect(roles.map((r) => r.role)).toEqual(['renter']);
  const ev = await sql`select code || ':' || split_part(dedupe_key, ':', 3) k from app_events where entity_id = ${a!.id} and code in ('renter_account_created', 'owner_account_created')`;
  expect(ev.map((r) => r.k)).toEqual(['renter_account_created:confirmed']);
  expect((await sql`select subject from local_auth.mailbox where to_email = ${email}`).length).toBe(0);
  // signed out, then Google again: the same account, nothing new
  await page.getByRole('button', { name: 'Sign out' }).first().click();
  await page.waitForURL((u) => u.pathname === '/');
  await google(page, '/sign-in', { email, name: 'Gail Google' });
  await page.waitForURL((u) => u.pathname === '/account', { timeout: 20_000 });
  expect((await authUsers(sql, email)).map((r) => r.id)).toEqual([a!.id]);
  expect((await sql`select count(*)::int n from users where email = ${email}`)[0]!.n).toBe(1);
  await sql.end();
});

test('an existing email and password account: Google with the same verified address signs into that account, and the password still works', async ({ browser }) => {
  const sql = db();
  const email = addr('pw');
  const id = randomUUID();
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`select public.register_account(${id}, ${email}, 'Pat Password', null)`;
  const page = await (await browser.newContext({ baseURL: test.info().project.use.baseURL })).newPage();
  await google(page, '/sign-in?next=/account/profile', { email, name: 'Someone Else' });
  await page.waitForURL((u) => u.pathname === '/account/profile', { timeout: 20_000 });
  expect((await authUsers(sql, email)).map((r) => r.id)).toEqual([id]);
  // the name on file is kept (the provider's name is only for a new account)
  expect((await sql`select full_name from users where id = ${id}`)[0]!.full_name).toBe('Pat Password');
  const p2 = await (await browser.newContext({ baseURL: test.info().project.use.baseURL })).newPage();
  await passwordSignIn(p2, email);
  await p2.waitForURL((u) => u.pathname === '/account', { timeout: 20_000 });
  await sql.end();
});

test('an account whose address was never confirmed: Google joins it and the password chosen without confirming stops working', async ({ page, browser }) => {
  const sql = db();
  const email = addr('unconf');
  const id = randomUUID();
  // a sign-up waiting for its confirmation link (someone typed this address and a password)
  await sql`insert into local_auth.users (id, email, password_hash, email_confirmed_at) values (${id}, ${email}, ${hash(PW)}, null)`;
  await sql`select public.register_account(${id}, ${email}, 'Una Confirmed', null)`;
  await google(page, '/sign-in', { email, name: 'Una Real' });
  await page.waitForURL((u) => u.pathname === '/account', { timeout: 20_000 });
  const [a] = await authUsers(sql, email);
  expect(a).toMatchObject({ id, confirmed: true });
  expect(a!.password_hash).toMatch(/^oauth\$/);
  const p2 = await (await browser.newContext({ baseURL: test.info().project.use.baseURL })).newPage();
  await passwordSignIn(p2, email);
  await expect(p2.getByRole('alert').first()).toContainText('do not match');
  expect(path(p2)).toBe('/sign-in');
  await sql.end();
});

test('an address the provider did not verify: refused, nobody signed in, nothing joined', async ({ page }) => {
  const sql = db();
  const email = addr('unver');
  await google(page, '/sign-in', { email, name: 'Vic Unverified', verified: false });
  await page.waitForURL((u) => u.pathname === '/sign-in' && u.searchParams.get('oauth') === 'unverified', { timeout: 20_000 });
  await expect(page.getByTestId('oauth-error')).toContainText('did not confirm your email');
  expect((await sql`select count(*)::int n from users where email = ${email}`)[0]!.n).toBe(0);
  await page.goto('/account');
  await expect(page).toHaveURL(/\/sign-in/);
  await sql.end();
});

test('cancelled on the provider page: back on sign-in with a plain message', async ({ page }) => {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.getByTestId('oauth-google').click();
  await page.waitForURL((u) => u.pathname === '/auth/oauth/fake');
  await page.getByTestId('fake-oauth-cancel').click();
  await page.waitForURL((u) => u.pathname === '/sign-in' && u.searchParams.get('oauth') === 'cancelled');
  await expect(page.getByTestId('oauth-error')).toContainText('Google was cancelled');
});

test('a guest booking-request record with the address: Google makes that record the account (its id), in one more pass', async ({ page }) => {
  const sql = db();
  const email = addr('rec');
  const id = randomUUID();
  // what a guest's booking request leaves: a users row with no sign-in
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Rita Record')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'renter')`;
  await google(page, '/sign-in', { email, name: 'Rita Record' });
  await page.waitForURL((u) => u.pathname === '/account', { timeout: 30_000 });
  const rows = await authUsers(sql, email);
  expect(rows.map((r) => r.id)).toEqual([id]);
  expect(rows[0]!.confirmed).toBe(true);
  expect((await sql`select email_verified_at is not null v from users where id = ${id}`)[0]!.v).toBe(true);
  await sql.end();
});

test('staff with an authenticator: Google sign-in still asks for the two-step code before the staff portal', async ({ page }) => {
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const email = addr('va');
  const id = randomUUID();
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Val Google')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
  await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'cs')`;
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  const secret = Array.from(randomBytes(32), (b) => A[b % 32]).join('');
  await sql`insert into local_auth.factors (id, user_id, secret, verified_at) values (${randomUUID()}, ${id}, ${secret}, now())`;
  await google(page, '/sign-in?next=/va', { email });
  await page.waitForURL((u) => u.pathname === '/two-step', { timeout: 20_000 });
  expect(new URL(page.url()).searchParams.get('next')).toBe('/va');
  // the session is not yet aal2: the database refuses staff calls until the code
  const cookie = (await page.context().cookies()).find((c) => c.name === 'cc-local-session')!;
  expect(JSON.parse(Buffer.from(cookie.value.split('.')[1]!, 'base64url').toString()).aal).toBe('aal1');
  await page.getByTestId('totp-code').fill(totp(secret));
  await page.getByTestId('totp-submit').click();
  await page.waitForURL((u) => u.pathname === '/va', { timeout: 20_000 });
  const after = (await page.context().cookies()).find((c) => c.name === 'cc-local-session')!;
  expect(JSON.parse(Buffer.from(after.value.split('.')[1]!, 'base64url').toString()).aal).toBe('aal2');
  await sql.end();
});
