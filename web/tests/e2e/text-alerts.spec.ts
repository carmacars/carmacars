import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { acceptCookies, db, noOverflow } from './helpers';

// Text alerts (migration 0096) end to end, at 375 and 1440, with the SMS sender mocked (QUO_PROVIDER=fake: texts are
// recorded in the outbox and on the thread, never sent). A renter with a verified phone sees Both chosen by default on
// their profile and picks Text; then sends a booking request choosing Text: the request email is skipped, the text is
// queued with its link (and held until 8 am in the quiet hours), and the phone job sends it through the fake line. The
// phone sign-up offers Text first. Every page is checked with axe, for overflow and the copy rules.
const PW = 'correct horse battery';
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
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
function jobToken() {
  let key = 'local-only-link-signing-key-not-for-production';
  try {
    const env = readFileSync(path.join(process.cwd(), '.env.local'), 'utf8');
    key = (/^LINK_SIGNING_KEY=(.*)$/m.exec(env)?.[1] ?? /^LOCAL_AUTH_SECRET=(.*)$/m.exec(env)?.[1] ?? key).replace(/\s+#.*$/, '').trim();
  } catch { /* the default local key */ }
  return createHmac('sha256', key).update('carmacars-listing-worker-v1').digest('hex');
}

/** A renter account with a password and a phone verified with a code (a Canadian mobile of this test's own). */
async function mkRenter(sql: Sql) {
  const id = randomUUID(); const t = tag(); const email = `ta.${Date.now()}.${t}@example.test`;
  const phone = `+1647${String(2000000 + Math.floor(Math.random() * 7999999)).slice(0, 7)}`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`select public.register_account(${id}, ${email}, ${`Tara Text ${t}`}, null)`;
  await sql`update users set phone = ${phone}, phone_verified_at = now(), email_verified_at = now() where id = ${id}`;
  return { id, email, phone };
}
async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  const useEmail = page.getByTestId('use-email');
  if (await useEmail.isVisible().catch(() => false)) await useEmail.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 20_000 });
}
function futureRange(offsetDays: number) {
  const d = new Date(); d.setUTCDate(d.getUTCDate() + offsetDays);
  const from = d.toISOString().slice(0, 10); d.setUTCDate(d.getUTCDate() + 2);
  return { from, to: d.toISOString().slice(0, 10) };
}
async function freeWindow(sql: Sql, slug: string) {
  for (let off = 90 + Math.floor(Math.random() * 30); off < 300; off += 5) {
    const r = futureRange(off);
    const [b] = await sql`select count(*)::int n from bookings b join vehicle_listings l using (vehicle_id) where l.slug = ${slug} and b.status not in ('expired', 'cancelled', 'declined')
      and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${r.from}::date::timestamptz, ${r.to}::date::timestamptz + interval '1 day')`;
    if (b!.n === 0) return r;
  }
  throw new Error('no free window');
}

test.describe.configure({ mode: 'serial' });

test('profile: How should we reach you? Both by default with a verified phone; Text saved', async ({ page }) => {
  const sql = db();
  try {
    const r = await mkRenter(sql);
    await signIn(page, r.email);
    await page.goto('/account/profile', { waitUntil: 'networkidle' });
    const card = page.getByTestId('notify-channel');
    await expect(card.getByRole('heading', { name: 'Messages' })).toBeVisible();
    await expect(card.getByRole('group', { name: 'How should we reach you?' })).toBeVisible();
    await expect(page.getByTestId('channel-both')).toBeChecked();
    await expect(page.getByTestId('notify-now')).toHaveText('We text and email you.');
    await check(page, 'profile');
    await card.locator('label.option', { hasText: 'Text' }).first().click();
    await expect(page.getByTestId('notify-msg')).toContainText('Saved. We text you.');
    await expect(page.getByTestId('channel-text')).toBeChecked();
    await expect.poll(async () => (await sql`select notify_channel from users where id = ${r.id}`)[0]!.notify_channel).toBe('text');
    // the choice survives a reload; the quiet hours and STOP are explained
    await page.reload({ waitUntil: 'networkidle' });
    await expect(page.getByTestId('channel-text')).toBeChecked();
    await expect(card).toContainText('No texts from 9 pm to 8 am unless it is urgent');
    await expect(card).toContainText('Reply STOP to any text to stop them.');
    // STOP from that number: the profile says texts are off and how to turn them back on
    await sql`insert into phone_threads (number, opted_out_at, opt_out_source) values (${r.phone}, now(), 'stop') on conflict (number) do update set opted_out_at = now(), opt_out_source = 'stop'`;
    await page.reload({ waitUntil: 'networkidle' });
    await expect(page.getByTestId('notify-why')).toContainText('You replied STOP, so texts are off. Text START to');
    await expect(page.getByTestId('notify-now')).toHaveText('We email you.');
    await check(page, 'profile after STOP');
  } finally { await sql.end(); }
});

test('a booking request with Text: the email is skipped, the text is queued with its link and sent by the (mocked) line', async ({ page }) => {
  const sql = db();
  try {
    await sql`delete from app.rate_limit_hits`;
    const r = await mkRenter(sql);
    const slug = isPhone() ? 'honda-civic' : 'toyota-camry';
    const range = await freeWindow(sql, slug);
    await signIn(page, r.email);
    await page.goto(`/book/${slug}?from=${range.from}&to=${range.to}&tf=10:00&tt=10:00`, { waitUntil: 'networkidle' });
    await acceptCookies(page);
    await expect(page.getByRole('heading', { level: 1 })).toHaveText('Request to book');
    await page.getByRole('button', { name: 'Continue to driver details' }).click();
    await expect(page.getByRole('heading', { name: 'The driver' })).toBeVisible();
    await page.locator('#rq-first').fill('Tara');
    await page.locator('#rq-last').fill('Text');
    await expect(page.locator('#rq-email')).toHaveValue(r.email);
    await page.locator('#rq-dobm').selectOption('4');
    await page.locator('#rq-dobd').fill('9');
    await page.locator('#rq-doby').fill('1990');
    // signed in with a verified phone: Both is chosen; pick Text
    await expect(page.getByTestId('rq-channel-both')).toBeChecked();
    await page.getByTestId('rq-channel').locator('label.option', { hasText: 'Text' }).first().click();
    await expect(page.getByTestId('rq-channel-text')).toBeChecked();
    await expect(page.getByTestId('rq-channel')).toContainText('We text');
    await check(page, 'request, the driver');
    await page.getByRole('button', { name: 'Continue to licence' }).click();
    await page.locator('label', { hasText: 'Ontario G2' }).click();
    await page.locator('label.option', { hasText: 'Option 2' }).click();
    await page.getByRole('button', { name: 'Continue to add-ons' }).click();
    await expect(page.getByRole('heading', { name: 'Add-ons' })).toBeVisible();
    await page.getByRole('button', { name: 'Review request' }).click();
    await expect(page.locator('.req__review')).toContainText('Messages');
    await expect(page.locator('.req__review')).toContainText('Text');
    await page.locator('input[name="agree"]').check();
    await page.getByRole('button', { name: 'Send request' }).click();
    await page.waitForURL(/\/book\/sent\//, { timeout: 30_000 });
    const number = decodeURIComponent(page.url().split('/').pop()!);

    // the choice is on the account and the renter record
    const [who] = await sql`select u.notify_channel as u, r.notify_channel as r from bookings b join renters r on r.id = b.renter_id join users u on u.id = r.user_id where b.booking_number = ${number}`;
    expect(who).toEqual({ u: 'text', r: 'text' });
    // the notification layer: the request email is skipped for the text
    await expect.poll(async () => {
      await sql`select app.process_events(1000)`;
      return (await sql`select n.status, n.status_reason, n.channel from notification_outbox n join bookings b on b.id = n.booking_id where b.booking_number = ${number} and n.code = 'renter_request_received'`)[0] ?? null;
    }, { timeout: 15_000 }).toEqual({ status: 'skipped', status_reason: 'Sent by text (the person chose text)', channel: 'text' });
    const [sms] = await sql<Array<{ id: string; status: string; to_number: string; body: string; waits: boolean; quiet: boolean }>>`
      select o.id, o.status, o.to_number, o.body, o.send_after > now() + interval '1 second' as waits, app.sms_quiet_end(o.created_at) > o.created_at as quiet
        from phone_outbox o join bookings b on b.id = o.booking_id where b.booking_number = ${number} and o.kind = 'notify' and o.sms_kind = 'renter_request_received'`;
    expect(sms!.status).toBe('queued');
    expect(sms!.to_number).toBe(r.phone);
    expect(sms!.body).toContain(`we have your request ${number}`);
    expect(sms!.body).toMatch(new RegExp(`/account/bookings/${number}/request( Reply STOP to opt out\\.)?$`));
    // the STOP line is on the first text to the number only (the account's welcome may have been texted first)
    const stops = await sql`select body like '%Reply STOP to opt out.' as stop from phone_outbox where to_number = ${r.phone} and kind = 'notify' order by created_at`;
    expect(stops.map((x) => x.stop)).toEqual(stops.map((_, i) => i === 0));
    expect(sms!.body).not.toMatch(/[—–]/);
    expect(sms!.waits, 'a text queued in the quiet hours waits for 8 am, otherwise it goes now').toBe(sms!.quiet);
    // the quiet hours end (or have): the phone job sends it through the fake line
    await sql`update phone_outbox set send_after = now() - interval '1 second' where id = ${sms!.id}`;
    const job = await page.request.post('/api/jobs/phone', { headers: { authorization: `Bearer ${jobToken()}` } });
    expect(job.status()).toBe(200);
    await expect.poll(async () => (await sql`select status from phone_outbox where id = ${sms!.id}`)[0]!.status, { timeout: 15_000 }).toBe('sent');
    const [act] = await sql`select direction, sms_kind, body from phone_activity where outbox_id = ${sms!.id}`;
    expect(act).toMatchObject({ direction: 'out', sms_kind: 'renter_request_received' });
    // the booking page the text links to
    await page.goto(`/account/bookings/${encodeURIComponent(number)}/request`, { waitUntil: 'networkidle' });
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
    await check(page, 'the request page');
  } finally { await sql.end(); }
});

test('phone sign-up offers Text first; an Admin sees and changes a renter\'s channel', async ({ page, browser }) => {
  const sql = db();
  try {
    await page.goto('/create-account', { waitUntil: 'networkidle' });
    await acceptCookies(page);
    await page.getByRole('button', { name: /Sign up with my phone number instead/ }).click();
    await expect(page.getByTestId('signup-channel-text')).toBeChecked();
    await expect(page.getByTestId('signup-channel')).toContainText('Reply STOP to any text to stop them.');
    await check(page, 'phone sign-up');

    // the Admin side: People > Renters > the renter, How we reach them
    const r = await mkRenter(sql);
    await sql`insert into renters (user_id, legal_name, email, mobile) select ${r.id}, 'Tara Text', ${r.email}, ${r.phone} where not exists (select 1 from renters where user_id = ${r.id})`;
    const [rec] = await sql`select id from renters where user_id = ${r.id}`;
    const aid = randomUUID(); const aemail = `ta.admin.${Date.now()}.${tag()}@example.test`;
    await sql`insert into local_auth.users (id, email, password_hash) values (${aid}, ${aemail}, ${hash(PW)})`;
    await sql`insert into users (id, email, full_name) values (${aid}, ${aemail}, 'Ada Admin')`;
    await sql`insert into user_roles (user_id, role) values (${aid}, 'admin')`;
    const ctx = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
    const a = await ctx.newPage();
    await signIn(a, aemail);
    await a.goto(`/admin/renters/${rec!.id}`, { waitUntil: 'networkidle' });
    const card = a.getByTestId('reach-card');
    await expect(card).toContainText('Not chosen (default Both)');
    await expect(a.getByTestId('reach-now')).toHaveText('Both');
    await check(a, 'admin renter');
    await a.getByTestId('reach-change').click();
    await a.getByRole('dialog').locator('select').selectOption('email');
    await a.getByTestId('reach-change-submit').click();
    await expect(a.getByTestId('reach-now')).toHaveText('Email');
    expect((await sql`select notify_channel from users where id = ${r.id}`)[0]!.notify_channel).toBe('email');
    expect((await sql`select count(*)::int n from audit_log where action = 'notify_channel_set' and actor_user_id = ${aid}`)[0]!.n).toBe(1);
    // Settings > Text alerts and Site health
    await a.goto('/admin/settings/text-alerts', { waitUntil: 'networkidle' });
    await expect(a.getByTestId('sms-templates')).toContainText('Booking received');
    await check(a, 'settings text alerts');
    await a.goto('/admin', { waitUntil: 'networkidle' });
    await expect(a.getByTestId('sms-volume')).toContainText('Texts today');
    await ctx.close();
  } finally { await sql.end(); }
});
