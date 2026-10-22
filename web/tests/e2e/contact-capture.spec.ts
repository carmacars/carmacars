import { expect, test } from '@playwright/test';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Contact capture (migration 0090), phone 375 and desktop 1440: a request left half way keeps the person's contact as a
// lead and opens an account (no password, email not confirmed) with an unverified session bound to this browser; the
// "Continue your request" link, opened on another device, signs in, confirms the email and opens the draft, and ends the
// first browser's unverified session; an address that already has an account gets only "You have an account: we sent
// you a sign-in link" and no session. The sign-up form: the same capture; it answers an existing address itself when sent.

function futureRange(offsetDays: number) {
  const d = new Date(); d.setUTCDate(d.getUTCDate() + offsetDays);
  const from = d.toISOString().slice(0, 10); d.setUTCDate(d.getUTCDate() + 3);
  return { from, to: d.toISOString().slice(0, 10) };
}

test('an abandoned request leaves a lead and an account; the continue link signs in, confirms and opens the draft', async ({ browser, page }, info) => {
  { const s0 = db(); await s0`delete from app.rate_limit_hits`; await s0.end(); }
  const errors = watch(page);
  const sql = db();
  const slug = info.project.name.startsWith('phone') ? 'toyota-corolla' : 'kia-forte';
  const email = `capture.${info.project.name}.${Date.now()}@example.test`;
  const range = futureRange(120);
  await page.goto(`/book/${slug}?from=${range.from}&to=${range.to}&tf=10:00&tt=10:00`);
  await acceptCookies(page);
  await page.getByRole('button', { name: 'Continue to driver details' }).click();
  await expect(page.getByRole('heading', { name: 'The driver' })).toBeVisible();
  await page.locator('#rq-first').fill('Casey');
  await page.locator('#rq-last').fill('Capture');
  await page.locator('#rq-phone').fill('647-555-0177');
  await page.locator('#rq-email').fill(email);
  await page.locator('#rq-dobm').focus();
  // saved as typed: the note under the fields, nothing sent
  await expect(page.getByTestId('capture-note')).toContainText('We opened an account for you with this email');
  await noOverflow(page);

  const cap = await sql`select c.id, c.user_id, c.lead_id, c.draft_id, c.state, l.consent_marketing, l.source from contact_captures c join leads l on l.id = c.lead_id where c.email = ${email}`;
  expect(cap.length).toBe(1);
  expect(cap[0]!.state).toBe('new');
  expect(cap[0]!.consent_marketing).toBe(false);
  expect(cap[0]!.source).toBe('unfinished_form');
  const userId = cap[0]!.user_id as string;
  const acct = await sql`select u.email_verified_at, r.legal_name, r.mobile, a.email_confirmed_at, a.password_hash like 'invited$%' as no_password
                           from users u join renters r on r.user_id = u.id join local_auth.users a on a.id = u.id where u.id = ${userId}`;
  expect(acct[0]!.legal_name).toBe('Casey Capture');
  expect(acct[0]!.mobile).toBe('+16475550177');
  expect(acct[0]!.email_verified_at).toBeNull();
  expect(acct[0]!.email_confirmed_at).toBeNull();
  expect(acct[0]!.no_password).toBe(true);
  // the browser-bound unverified session: an httpOnly cookie; it is not a sign-in
  const cookie = (await page.context().cookies()).find((c) => c.name === 'cc-pending');
  expect(cookie?.httpOnly).toBe(true);
  // wait for the draft to reach the server, then the capture carries it
  await expect.poll(async () => (await sql`select draft_id from contact_captures where id = ${cap[0]!.id}`)[0]!.draft_id, { timeout: 15_000 }).toBeTruthy();

  // this device: /account shows what it started, with "Email not confirmed yet", and nothing else
  await page.goto('/account');
  await page.waitForURL(/\/my-request/);
  await expect(page.getByTestId('my-request')).toContainText('Email not confirmed yet');
  await expect(page.getByTestId('my-request')).toContainText(email);
  await noOverflow(page);
  // the portal's pages stay behind the sign-in
  await page.goto('/account/profile');
  await page.waitForURL(/\/sign-in/);

  // another browser types the same address before it is confirmed: an existing account, the sign-in link (the one
  // "Continue your request" email), never a session, and nothing of the first browser is visible there
  const intruder = await browser.newContext({ viewport: page.viewportSize() ?? undefined, reducedMotion: 'reduce' });
  const pb = await intruder.newPage();
  await pb.goto('/contact');
  await acceptCookies(pb);
  await pb.locator('#ct-name').fill('Not Casey');
  await pb.locator('#ct-email').fill(email);
  await pb.locator('#ct-phone').focus();
  await expect(pb.getByTestId('capture-note')).toHaveText('You have an account: we sent you a sign-in link.');
  expect((await intruder.cookies()).some((c) => c.name === 'cc-pending')).toBe(false);
  await pb.goto('/my-request');
  await expect(pb.getByRole('heading', { level: 1 })).toHaveText('Nothing started on this device.');
  expect((await sql`select full_name from users where id = ${userId}`)[0]!.full_name).toBe('Casey Capture');
  await intruder.close();
  const ev = await sql`select payload from app_events where code = 'renter_continue_request' and entity_id = ${userId}`;
  expect(ev.length).toBe(1);
  const url = new URL(String((ev[0]!.payload as { continue_url: string }).continue_url));
  expect(url.pathname).toBe('/continue');

  // another device: the link signs in AND confirms the email, and lands on the draft
  const other = await browser.newContext({ viewport: page.viewportSize() ?? undefined, reducedMotion: 'reduce' });
  const p2 = await other.newPage();
  await p2.goto(`/continue${url.search}`);
  await p2.waitForURL(new RegExp(`/book/${slug}`), { timeout: 30_000 });
  await acceptCookies(p2);
  await expect(p2.getByRole('heading', { name: 'The driver' })).toBeVisible({ timeout: 15_000 });
  await expect(p2.locator('#rq-first')).toHaveValue('Casey');
  await expect(p2.locator('#rq-email')).toHaveValue(email);
  const after = await sql`select u.email_verified_at is not null as confirmed, a.email_confirmed_at is not null as auth_confirmed,
                            (select count(*)::int from capture_sessions s where s.user_id = u.id and s.revoked_at is null) as live
                            from users u join local_auth.users a on a.id = u.id where u.id = ${userId}`;
  expect(after[0]).toEqual({ confirmed: true, auth_confirmed: true, live: 0 });
  await p2.goto('/account');
  await expect(p2.getByTestId('account-email')).toHaveText(email);
  await other.close();

  // the first browser's unverified session ended with the confirmation
  await page.goto('/my-request');
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Nothing started on this device.');
  await sql.end();
  expect(errors.filter((e) => !/Failed to load resource|favicon|ERR_ABORTED/.test(e))).toEqual([]);
});

test('an address that already has an account: "we sent you a sign-in link", no session, nothing revealed', async ({ page }, info) => {
  { const s0 = db(); await s0`delete from app.rate_limit_hits`; await s0.end(); }
  const sql = db();
  const email = `capture.known.${info.project.name}.${Date.now()}@example.test`;
  const id = crypto.randomUUID();
  await sql`insert into users (id, email, full_name, email_verified_at) values (${id}, ${email}, 'Known Person', now())`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'renter')`;
  await sql`insert into local_auth.users (id, email, password_hash, email_confirmed_at) values (${id}, ${email}, 'scrypt$x$y', now())`;
  await page.goto('/contact');
  await acceptCookies(page);
  await page.locator('#ct-name').fill('Somebody Typing');
  await page.locator('#ct-email').fill(email);
  await page.locator('#ct-phone').focus();
  await expect(page.getByTestId('capture-note')).toHaveText('You have an account: we sent you a sign-in link.');
  await noOverflow(page);
  expect((await page.context().cookies()).some((c) => c.name === 'cc-pending')).toBe(false);
  const r = await sql`select (select count(*)::int from app_events where code = 'renter_continue_request' and entity_id = ${id}) as emails,
                             (select full_name from users where id = ${id}) as name,
                             (select count(*)::int from contact_captures where email = ${email} and state = 'existing') as captures`;
  expect(r[0]).toEqual({ emails: 1, name: 'Known Person', captures: 1 });
  // a second browser typing it again: no second email
  await page.locator('#ct-name').fill('Somebody Else');
  await page.locator('#ct-phone').fill('416-555-0123');
  await page.locator('#ct-email').focus();
  await expect(page.getByTestId('capture-note')).toContainText('You have an account');
  expect((await sql`select count(*)::int n from app_events where code = 'renter_continue_request' and entity_id = ${id}`)[0]!.n).toBe(1);
  await sql.end();
});

test('the sign-up form: a new address left half way is saved with this browser\'s account; finishing it sets the password and closes the capture; an existing address gets nothing until sent', async ({ page }, info) => {
  { const s0 = db(); await s0`delete from app.rate_limit_hits`; await s0.end(); }
  const sql = db();
  const email = `capture.signup.${info.project.name}.${Date.now()}@example.test`;
  await page.goto('/create-account');
  await acceptCookies(page);
  await page.locator('#su-name').fill('Sidney Signup');
  await page.locator('#su-email').fill(email);
  await page.locator('#su-pass').focus();
  await expect.poll(async () => (await sql`select state from contact_captures where email = ${email} and form = 'signup'`)[0]?.state, { timeout: 15_000 }).toBe('new');
  await expect.poll(async () => (await page.context().cookies()).some((c) => c.name === 'cc-pending' && c.httpOnly)).toBe(true);
  await noOverflow(page);
  await page.locator('#su-pass').fill('correct horse battery');
  await page.locator('input[name="agree"]').check();
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.locator('.alert--ok')).toContainText('Confirm your CarmaCars account');
  const r = await sql`select c.done_at is not null as done, l.status, a.password_hash not like 'invited$%' as has_password, a.email_confirmed_at is null as unconfirmed
                        from contact_captures c join leads l on l.id = c.lead_id join local_auth.users a on a.id = c.user_id where c.email = ${email}`;
  expect(r[0]).toEqual({ done: true, status: 'closed', has_password: true, unconfirmed: true });

  // an address that already has an account, typed into the sign-up form of another browser: saved, no session, no email
  const known = `capture.signup.known.${info.project.name}.${Date.now()}@example.test`;
  const id = crypto.randomUUID();
  await sql`insert into users (id, email, full_name, email_verified_at) values (${id}, ${known}, 'Known Signup', now())`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'renter')`;
  await page.context().clearCookies();
  await page.goto('/create-account');
  await acceptCookies(page);
  await page.locator('#su-name').fill('Someone Else');
  await page.locator('#su-email').fill(known);
  await page.locator('#su-pass').focus();
  await expect.poll(async () => (await sql`select state from contact_captures where email = ${known} and form = 'signup'`)[0]?.state, { timeout: 15_000 }).toBe('existing');
  expect((await page.context().cookies()).some((c) => c.name === 'cc-pending')).toBe(false);
  expect((await sql`select count(*)::int n from app_events where code = 'renter_continue_request' and entity_id = ${id}`)[0]!.n).toBe(0);
  expect((await sql`select full_name from users where id = ${id}`)[0]!.full_name).toBe('Known Signup');
  await sql.end();
});
