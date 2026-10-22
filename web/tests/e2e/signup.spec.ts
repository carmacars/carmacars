import { expect, test, type Page } from '@playwright/test';
import { createHmac, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { acceptCookies, db, noOverflow, tapColour, watch } from './helpers';

// One confirmation email per sign-up (migration 0045, docs/changes/2026-10-16-one-confirmation-email.md), for every
// path that makes an account: the create-account form, the owner application (with and without an invitation link),
// and a guest's booking request followed by the create-account form (the address already on file). Each: sign up,
// exactly the expected emails (the sign-in service's mailbox, local_auth.mailbox; the app's events and outbox rows),
// the link, the right portal, sign out, sign in. The staff and owner invitations are checked in signin.spec.ts.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const ACCOUNT_CODES = ['renter_account_created', 'owner_account_created'];
const vin = (prefix: string) => { const ok = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789'; let s = prefix; while (s.length < 17) s += ok[Math.floor(Math.random() * ok.length)]; return s; };
const linkKey = () => process.env.LINK_SIGNING_KEY || (() => { try { return /^LINK_SIGNING_KEY=(\S+)/m.exec(readFileSync('.env.local', 'utf8'))?.[1]; } catch { return undefined; } })() || 'local-link-signing-key-change-me-32-chars';
const b64url = (b: Buffer) => b.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
/** The owner invitation link an Admin sends (src/server/actions/admin.ts sendOwnerLink). */
function inviteToken(email: string, name: string) {
  const body = b64url(Buffer.from(JSON.stringify({ e: email, n: name, p: 'owner-invite', exp: Math.floor(Date.now() / 1000) + 3600 })));
  return `${body}.${b64url(createHmac('sha256', linkKey()).update(body).digest())}`;
}

/** The mails the sign-in service sent this address (subjects, oldest first). */
const mailbox = async (sql: Sql, email: string) => (await sql`select subject, link from local_auth.mailbox where to_email = ${email} order by id`) as unknown as Array<{ subject: string; link: string }>;
/** The app's account emails for this person: every email starts as an event (code:discriminator). */
async function accountEmails(sql: Sql, email: string) {
  const r = await sql`select e.code || ':' || split_part(e.dedupe_key, ':', 3) k from app_events e join users u on u.id = e.entity_id
                       where u.email = ${email} and e.code in ${sql(ACCOUNT_CODES)} order by e.id`;
  return r.map((x) => x.k as string);
}
/** Every app email decided for this address (outbox rows after the events are processed). */
async function outbox(sql: Sql, email: string) {
  await sql`select app.process_events(1000)`;
  return (await sql`select code, missing_variables::text mv from notification_outbox where lower(to_address) = ${email} order by created_at, code`) as unknown as Array<{ code: string; mv: string }>;
}
const local = (link: string) => { const u = new URL(link); return u.pathname + u.search; };
const path = (page: Page) => new URL(page.url()).pathname;

async function signOutAndIn(page: Page, email: string, home: string) {
  await page.getByRole('button', { name: 'Sign out' }).first().click();
  await page.waitForURL((u) => u.pathname === '/');
  await page.goto('/sign-in');
  await page.locator('#si-email').fill(email);
  await page.locator('#si-pass').fill(PW);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL((u) => u.pathname === home, { timeout: 20_000 });
}

/** The welcome template has no confirm button and links to the portal (what the outbox row renders). */
function expectWelcome(code: string, link: string) {
  const html = readFileSync(`../emails/templates/${code}.html`, 'utf8');
  expect(html, code).not.toMatch(/confirm my email|confirm your email/i);
  expect(html, code).toContain(`href="https://carmacars.ca${link}"`);
}

test('create account: one confirmation email; before it, sign-in says confirm first and sends a new link; the link lands in /account; one welcome', async ({ page }, info) => {
  const errors = watch(page);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const email = `signup.renter.${info.project.name}.${Date.now()}@example.test`;
  await page.goto('/create-account');
  await acceptCookies(page);
  await page.locator('#su-name').fill('Riley Signup');
  await page.locator('#su-email').fill(email);
  await page.locator('#su-pass').fill(PW);
  await page.locator('input[name="agree"]').check();
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.getByText('Check your email')).toBeVisible();
  await expect(page.locator('.alert--ok')).toContainText('Confirm your CarmaCars account');
  // exactly one email: the sign-in service's confirmation; the app sends nothing yet
  expect((await mailbox(sql, email)).map((m) => m.subject)).toEqual(['Confirm your CarmaCars account']);
  expect(await accountEmails(sql, email)).toEqual([]);
  expect(await outbox(sql, email)).toEqual([]);
  // signing in first: "Confirm your email first", and one click sends a new link
  await page.goto('/sign-in');
  await page.locator('#si-email').fill(email);
  await page.locator('#si-pass').fill(PW);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.getByTestId('signin-unconfirmed')).toContainText('Confirm your email first');
  await noOverflow(page);
  await page.getByRole('button', { name: 'Send a new confirmation link' }).click();
  await expect(page.getByTestId('signin-unconfirmed').locator('xpath=..').getByText('we sent a new link')).toBeVisible();
  const mails = await mailbox(sql, email);
  expect(mails.map((m) => m.subject)).toEqual(['Confirm your CarmaCars account', 'Confirm your CarmaCars account']);
  // the link of the template: no next; it confirms, signs in and lands in the renter portal
  expect(mails[1]!.link).toMatch(/\/auth\/callback\?token_hash=[\w-]+&type=signup$/);
  await page.goto(local(mails[1]!.link));
  await page.waitForURL((u) => u.pathname === '/account');
  await expect(page.getByTestId('account-email')).toHaveText(email);
  expect(await accountEmails(sql, email)).toEqual(['renter_account_created:confirmed']);
  expect(await outbox(sql, email)).toEqual([{ code: 'renter_account_created', mv: '{}' }]);
  expectWelcome('renter_account_created', '/cars');
  // the same link again: used, so the page that sends a new one
  await page.goto(local(mails[1]!.link));
  await expect(page).toHaveURL(/\/link-expired\?kind=confirm/);
  await expect(page.getByRole('button', { name: 'Send a new confirmation link' })).toBeVisible();
  await page.goto('/account');
  await signOutAndIn(page, email, '/account');
  expect(await accountEmails(sql, email), 'no second welcome after a sign-in').toEqual(['renter_account_created:confirmed']);
  expect(errors.filter((e) => !/favicon|Failed to load resource.*(404|403)/.test(e))).toEqual([]);
  await sql.end();
});

for (const variant of ['plain', 'invitation'] as const) {
  test(`owner application (${variant}): one confirmation email, no app "confirm" email; the link lands in /owner; one owner welcome`, async ({ page }, info) => {
    test.setTimeout(180_000);
    const errors = watch(page);
    const sql = db();
    await sql`delete from app.rate_limit_hits`;
    const email = `signup.owner.${variant}.${info.project.name}.${Date.now()}@example.test`;
    await page.goto(variant === 'invitation' ? `/list-your-car/apply?invite=${inviteToken(email, 'Omar Applicant')}` : '/list-your-car/apply', { waitUntil: 'networkidle' });
    await acceptCookies(page);
    await page.locator('label:has-text("An individual")').click();
    if (variant === 'invitation') {
      // the invitation fills in the name and the address
      await expect(page.locator('#ap-email')).toHaveValue(email);
      await expect(page.locator('#ap-first')).toHaveValue('Omar');
    } else {
      await page.locator('#ap-first').fill('Omar');
      await page.locator('#ap-last').fill('Applicant');
      await page.locator('#ap-email').fill(email);
    }
    await page.locator('#ap-addr').fill('union');
    await page.getByRole('option', { name: /Union Station/ }).click();
    await page.locator('#ap-postal').fill('m5j 1e6');
    await page.locator('#ap-phone').fill('647-555-0102');
    await page.locator('#ap-lic').fill('O1234-56789-01234');
    await page.locator('#ap-dob').fill('1985-05-05');
    await page.getByRole('button', { name: 'Continue to vehicles' }).click();
    const id = (k: string) => `#ap-v0-${k}`;
    await page.locator(id('vin')).fill(vin('2T1'));
    await expect(page.getByTestId('apply-vin-summary')).toBeVisible({ timeout: 20_000 });
    await tapColour(page, 'apply', 'White');
    await page.locator(id('plate')).fill(`SU${String(Date.now()).slice(-5)}`);
    await page.locator(id('odo')).fill('20000');
    await page.locator(id('ins')).fill('Intact');
    const editor = page.getByTestId('vehicle-editor');
    await editor.locator('label:has-text("Me personally")').click();
    await editor.locator('label:has-text("Owned outright")').click();
    await editor.locator('fieldset:has-text("branded") label:has-text("No")').click();
    await editor.locator('fieldset:has-text("recall") label:has-text("No")').click();
    await page.getByRole('button', { name: 'Continue', exact: true }).click();
    const plan = page.getByTestId('plan-vehicle').first();
    await expect(plan.locator('input[name^="ap-method-"]').first()).toBeVisible();
    await plan.locator('label:has-text("Co-Registrant")').click();
    await expect(page.getByTestId('autosave')).toContainText('Saved', { timeout: 10_000 });
    // a click while the plan step re-renders can be lost: press again until the review step shows
    await expect(async () => {
      await page.getByRole('button', { name: 'Review' }).click();
      await expect(page.locator('#ap-pw')).toBeVisible({ timeout: 3_000 });
    }).toPass({ timeout: 20_000 });
    await page.locator('#ap-pw').fill(PW);
    await page.getByRole('button', { name: 'Submit application' }).click();
    await expect(page.getByTestId('apply-done')).toContainText('Application received', { timeout: 20_000 });
    // the page asks to confirm the email (no button to a portal the person cannot open yet)
    await expect(page.getByTestId('apply-confirm-email')).toContainText(`We sent a link to ${email}`);
    await expect(page.getByRole('link', { name: 'Go to your owner portal' })).toHaveCount(0);
    await noOverflow(page);
    // exactly: the sign-in service's confirmation, and the application receipt; no account email from the app
    expect((await mailbox(sql, email)).map((m) => m.subject)).toEqual(['Confirm your CarmaCars account']);
    expect(await accountEmails(sql, email)).toEqual([]);
    expect((await outbox(sql, email)).map((o) => o.code)).toEqual(['owner_application_received']);
    // the confirmation link lands in the owner portal, signed in
    const [mail] = await mailbox(sql, email);
    await page.goto(local(mail!.link));
    await page.waitForURL((u) => u.pathname === '/owner', { timeout: 20_000 });
    await expect(page.getByTestId('owner-vehicle')).toHaveCount(1);
    expect(await accountEmails(sql, email)).toEqual(['owner_account_created:confirmed']);
    const ob = await outbox(sql, email);
    expect(ob.map((o) => o.code).sort()).toEqual(['owner_account_created', 'owner_application_received']);
    expect(ob.every((o) => o.mv === '{}')).toBe(true);
    expectWelcome('owner_account_created', '/owner');
    await signOutAndIn(page, email, '/owner');
    expect(errors.filter((e) => !/favicon|Failed to load resource.*(404|403)/.test(e))).toEqual([]);
    await sql.end();
  });
}

test('booking request, then create account with the same address: no email at the request; one link to choose the password; /account; one welcome', async ({ page }, info) => {
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const email = `signup.guest.${info.project.name}.${Date.now()}@example.test`;
  // the records a booking request makes for someone with no account (app.submit_booking_request): no sign-in
  const uid = randomUUID();
  await sql`insert into users (id, email, full_name) values (${uid}, ${email}, 'Gina Guest')`;
  await sql`insert into user_roles (user_id, role) values (${uid}, 'renter')`;
  await sql`insert into renters (user_id, legal_name, email) values (${uid}, 'Gina Guest', ${email})`;
  expect(await accountEmails(sql, email), 'the request sends no "finish your account" email').toEqual([]);
  await page.goto('/create-account');
  await acceptCookies(page);
  await page.locator('#su-name').fill('Gina Guest');
  await page.locator('#su-email').fill(email);
  await page.locator('#su-pass').fill(PW);
  await page.locator('input[name="agree"]').check();
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.locator('.alert--ok')).toContainText('We already have a booking request');
  // one email: the link to choose the password on that record (the sign-up's own confirmation is not sent)
  const mails = await mailbox(sql, email);
  expect(mails.map((m) => m.subject)).toEqual(['Reset your CarmaCars password']);
  expect(await accountEmails(sql, email)).toEqual([]);
  await page.goto(local(mails[0]!.link));
  await page.locator('#np-pass').fill(PW);
  await page.getByRole('button', { name: 'Save the new password' }).click();
  await page.waitForURL((u) => u.pathname === '/account');
  expect(await accountEmails(sql, email)).toEqual(['renter_account_created:confirmed']);
  expect((await outbox(sql, email)).map((o) => o.code)).toEqual(['renter_account_created']);
  await signOutAndIn(page, email, '/account');
  expect(path(page)).toBe('/account');
  await sql.end();
});
