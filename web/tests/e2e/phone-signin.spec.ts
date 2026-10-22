import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';
import { signHook } from '../../src/features/auth/sms-hook';

// Sign-in by phone (migration 0091) end to end, at 375 and 1440, with the SMS sender mocked: locally the sign-in
// service is the stand-in (src/lib/auth/local.ts), which asks the same SMS path as Supabase's hook (the database's
// checks, the fake Quo line) and keeps each text in local_auth.mailbox (to_phone), where these tests read the code like
// the emails. Covered: signing in by phone with a new number (the name asked once), the device remembering phone
// sign-in, a US number refused, the hook refusing unsigned calls and codes the site never asked for; adding and
// verifying a phone on an email account, then signing in with it; a phone sign-in for a number that belongs to an earlier
// booking request, which is attached only after the code; an email added to an account made by phone. axe, overflow, copy rules.
const PW = 'correct horse battery';
const HOOK_SECRET = 'v1,whsec_' + 'Y2FybWFjYXJzLWxvY2FsLXNtcy1ob29rLXNlY3JldA==';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
/** A fresh Toronto mobile number (416 area code; the exchange never starts with 0 or 1). */
const number = () => `+1416${2 + Math.floor(Math.random() * 8)}${String(Math.floor(Math.random() * 1e6)).padStart(6, '0')}`;
const shown = (n: string) => `${n.slice(2, 5)} ${n.slice(5, 8)} ${n.slice(8)}`;

/** The newest code texted to a number (the stand-in's outbox), waiting a moment for it. */
async function codeFor(sql: Sql, phone: string): Promise<string> {
  for (let i = 0; i < 40; i++) {
    const [m] = await sql`select body from local_auth.mailbox where to_phone = ${phone} order by id desc limit 1`;
    const c = /code: (\d{6})\./.exec(String(m?.body ?? ''))?.[1];
    if (c) return c;
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`no code texted to ${phone}`);
}
async function fresh(sql: Sql) {
  // the per-number and per-connection limits are counted per hour: the suite runs many times a day here
  await sql`delete from app.rate_limit_hits where key like 'signin-%'`;
}
async function mkRenter(sql: Sql) {
  const id = randomUUID(); const email = `ps.${Date.now()}.${tag()}@example.test`; const name = `Petra Phone ${tag()}`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`select public.register_account(${id}, ${email}, ${name}, null)`;
  return { id, email, name };
}
async function askCode(page: Page, phone: string) {
  await page.getByTestId('phone-number').fill(shown(phone));
  await page.getByTestId('phone-send').click();
  await expect(page.getByTestId('phone-sent')).toBeVisible();
}

test('sign in with a phone number: a new number, the code by text, the name once; the device remembers; US numbers wait for A2P', async ({ page }) => {
  const sql = db();
  await fresh(sql);
  const phone = number();
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.getByTestId('use-phone').click();
  await expect(page.getByTestId('phone-signin')).toBeVisible();
  await check(page, 'sign-in by phone');
  // a US number: refused while US texting is off (the Admin setting, default Canada only)
  await page.getByTestId('phone-number').fill('212 555 0199');
  await page.getByTestId('phone-send').click();
  await expect(page.getByText('Sign-in codes are texted to Canadian mobile numbers only for now.')).toBeVisible();

  await askCode(page, phone);
  const input = page.getByTestId('phone-code');
  await expect(input).toHaveAttribute('autocomplete', 'one-time-code');
  await expect(input).toHaveAttribute('inputmode', 'numeric');
  await check(page, 'enter the code');
  // a wrong code first
  await input.fill('000000');
  await expect(page.getByText(/That code does not match or has expired/).first()).toBeVisible();
  const code = await codeFor(sql, phone);
  expect((await sql`select body from local_auth.mailbox where to_phone = ${phone} order by id desc limit 1`)[0]!.body).toBe(`CarmaCars code: ${code}. It expires in 5 minutes. Don't share it.`);
  await input.fill(code);
  // a new account with no record behind the number: the name, once
  await expect(page.getByTestId('phone-name')).toBeVisible();
  await check(page, 'your name');
  await page.getByTestId('phone-name').fill('Morgan Mobile');
  await page.getByTestId('phone-name-save').click();
  await page.waitForURL((u) => u.pathname.startsWith('/account'), { timeout: 20_000 });
  const [u] = await sql`select u.email, u.phone, u.phone_verified_at is not null as verified, u.full_name, u.preferred_sign_in from users u join local_auth.users l on l.id = u.id where l.phone = ${phone}`;
  expect(u).toMatchObject({ email: null, phone, verified: true, full_name: 'Morgan Mobile', preferred_sign_in: 'phone' });
  const [log] = await sql`select status from app.auth_sms_log where phone = ${phone} order by created_at desc limit 1`;
  expect(log!.status).toBe('sent');

  // the profile: phone verified, no email yet (asked before the first payment), phone sign-in chosen
  await page.goto('/account/profile', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('signin-phone')).toContainText('Verified');
  await expect(page.getByTestId('signin-email')).toHaveText('None yet');
  await expect(page.getByTestId('pref-phone')).toBeChecked();
  await check(page, 'profile, sign-in');

  // the sign-in page opens on the phone next time on this device
  await page.context().clearCookies({ name: 'cc-local-session' });
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('phone-signin')).toBeVisible();
  await page.getByTestId('use-email').click();
  await expect(page.locator('input[type="password"]')).toBeVisible();
  await sql.end();
});

test('the Send SMS hook: unsigned calls and codes the site never asked for are refused', async ({ request }) => {
  const sql = db();
  const phone = number();
  const body = JSON.stringify({ user: { id: randomUUID(), phone: phone.slice(1) }, sms: { otp: '123456' } });
  const unsigned = await request.post('/api/webhooks/auth-sms', { data: body, headers: { 'content-type': 'application/json' } });
  expect(unsigned.status()).toBe(401);
  const signed = await request.post('/api/webhooks/auth-sms', { data: body, headers: { 'content-type': 'application/json', ...(await signHook(body, HOOK_SECRET, `msg_${tag()}`)) } });
  expect(signed.status()).toBe(403);
  expect((await signed.json()).error.message).toMatch(/No sign-in code was asked for this number/);
  expect((await sql`select reason from app.auth_sms_log where phone = ${phone}`)[0]!.reason).toBe('no_request');
  await sql.end();
});

test('add a phone to an email account, choose phone sign-in, then sign in with it', async ({ page, browser }) => {
  const sql = db();
  await fresh(sql);
  const me = await mkRenter(sql);
  const phone = number();
  await page.goto('/sign-in?next=/account/profile', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(me.email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL(/\/account\/profile/);
  await expect(page.getByTestId('pref-phone')).toBeDisabled();
  await page.getByTestId('phone-add').click();
  await page.locator('#si-phone').fill(shown(phone));
  await page.getByTestId('phone-send').click();
  await expect(page.getByTestId('phone-sent')).toBeVisible();
  await check(page, 'profile, verify a phone');
  await page.getByTestId('phone-code').fill(await codeFor(sql, phone));
  await expect(page.getByTestId('signin-msg')).toContainText('is verified');
  await expect(page.getByTestId('signin-phone')).toContainText('Verified');
  const [u] = await sql`select phone, phone_verified_at is not null as verified, email from users where id = ${me.id}`;
  expect(u).toMatchObject({ phone, verified: true, email: me.email });
  await page.getByTestId('pref-phone').check();
  await expect(page.getByTestId('signin-msg')).toContainText('You sign in with your phone number');
  expect((await sql`select preferred_sign_in from users where id = ${me.id}`)[0]!.preferred_sign_in).toBe('phone');

  // another device: phone sign-in reaches the same account
  const other = await browser.newContext({ viewport: page.viewportSize() ?? undefined, baseURL: test.info().project.use.baseURL });
  const p2 = await other.newPage();
  await p2.goto('/sign-in?method=phone', { waitUntil: 'networkidle' });
  await acceptCookies(p2);
  await sql`delete from local_auth.otps where phone = ${phone}`; // the stand-in, like Supabase, waits a minute between two codes
  await askCode(p2, phone);
  await p2.getByTestId('phone-code').fill(await codeFor(sql, phone));
  await p2.waitForURL((x) => x.pathname.startsWith('/account'), { timeout: 20_000 });
  await p2.goto('/account/profile', { waitUntil: 'networkidle' });
  await expect(p2.getByTestId('signin-email')).toContainText(me.email);
  await other.close();
  await sql.end();
});

test('phone sign-in for a number on an earlier booking request: attached only after the code; an email for the receipts added later', async ({ page }) => {
  const sql = db();
  await fresh(sql);
  const phone = number();
  // a guest's booking request made with this mobile number: a record with no sign-in
  const guest = randomUUID(); const name = `Riley Record ${tag()}`;
  await sql`insert into users (id, email, full_name) values (${guest}, ${`guest.${tag()}@example.test`}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${guest}, 'renter')`;
  const [r] = await sql`insert into renters (user_id, legal_name, mobile, email) values (${guest}, ${name}, ${phone}, ${`guest.${tag()}@example.test`}) returning id`;
  // asking for a code changes nothing: the record is still not anyone's
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.getByTestId('use-phone').click();
  await askCode(page, phone);
  expect((await sql`select user_id from renters where id = ${r!.id}`)[0]!.user_id).toBe(guest);
  await page.getByTestId('phone-code').fill(await codeFor(sql, phone));
  // the name came from the record: no name step
  await page.waitForURL((u) => u.pathname.startsWith('/account'), { timeout: 20_000 });
  const [me] = await sql`select u.id, u.full_name from users u join local_auth.users l on l.id = u.id where l.phone = ${phone}`;
  expect(me!.full_name).toBe(name);
  expect((await sql`select user_id from renters where id = ${r!.id}`)[0]!.user_id).toBe(me!.id);
  expect((await sql`select kind from account_links where user_id = ${me!.id} and entity_id = ${r!.id}`)[0]!.kind).toBe('renter_record');
  await check(page, 'trips after phone sign-in');

  // the account has no email: the pay step asks for it inline before any payment
  await page.goto('/account/profile', { waitUntil: 'networkidle' });
  await page.getByTestId('signin-email-input').fill(`riley.${tag()}@example.test`);
  await page.getByRole('button', { name: 'Save my email' }).click();
  await expect(page.getByTestId('signin-msg')).toContainText('We emailed');
  const [after] = await sql`select email, email_verified_at from users where id = ${me!.id}`;
  expect(after!.email).toMatch(/^riley\./);
  expect(after!.email_verified_at).toBeNull();
  expect((await sql`select count(*)::int as n from local_auth.mailbox where to_email = ${after!.email}`)[0]!.n).toBe(1);
  await sql.end();
});
