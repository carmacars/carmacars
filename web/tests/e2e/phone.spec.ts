import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';
import { signQuo } from '../../src/features/phone/webhook';
import { SAMPLES } from '../../src/features/phone/samples';

// Migration 0085 end to end, at 375 and 1440, with Quo mocked: deliveries are signed with the local fake's webhook
// secret and posted to /api/webhooks/quo exactly as Quo sends them (the documentation's payloads with our numbers), and
// texts go through the fake line (QUO_PROVIDER=fake). Customer service reads a renter's text in Live chat > Texts and
// calls, asks for a suggestion (the fake model), sends it from the CarmaCars number; an unknown caller's missed call
// shows under Unknown callers and becomes a lead in one click; the Admin sees the calls and texts on the booking's
// History tab and on the renter page. Every page is checked with axe, for overflow and the copy rules.
const PW = 'correct horse battery';
const SECRET = 'whsec_' + 'Y2FybWFjYXJzLWxvY2FsLXF1by13ZWJob29rLXNlY3JldA==';
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
const shown = (n: string) => `${n.slice(2, 5)}-${n.slice(5, 8)}-${n.slice(8)}`;
const number = () => `+1416${String(2000000 + Math.floor(Math.random() * 7999999)).slice(0, 7)}`;

async function mkUser(sql: Sql, role: 'admin' | 'va', fn?: 'cs') {
  const id = randomUUID(); const name = `Pat Phone ${tag()}`; const email = `${role}.ph.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (fn) await sql`insert into staff_profiles (user_id, staff_type, va_function) values (${id}, 'va', ${fn})`;
  return { id, email, name };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
/** A delivery as Quo sends it: the documentation's payload with our numbers, signed with the local webhook secret. */
type Delivery = { id: string; data: { resource: Record<string, unknown>; context: Record<string, unknown> } };
async function deliver(page: Page, sample: unknown, patch: (b: Delivery) => void): Promise<number> {
  const body = JSON.parse(JSON.stringify(sample)) as Delivery;
  body.id = `EV${randomUUID()}`;
  const now = new Date().toISOString();
  for (const k of ['createdAt', 'updatedAt', 'answeredAt', 'completedAt']) if (k in body.data.resource) body.data.resource[k] = now;
  patch(body);
  const raw = JSON.stringify(body);
  const r = await page.request.post('/api/webhooks/quo', { data: raw, headers: { 'content-type': 'application/json', ...(await signQuo(raw, SECRET, `msg_${randomUUID()}`)) } });
  return r.status();
}

test.describe.configure({ mode: 'serial' });

// a renter of this test's own with a mobile of their own, and a past booking of theirs (a copy of a seeded booking
// moved to dates no other booking uses), so the two widths never share a renter or a number
async function renterWithBooking(sql: Sql) {
  const mobile = number();
  const t = tag();
  const legal_name = `Phoebe Phone ${t}`;
  const [r] = await sql<Array<{ id: string }>>`insert into renters (legal_name, date_of_birth, mobile, email, identity_status)
    values (${legal_name}, '1990-05-05', ${mobile}, ${`phoebe.${t}@example.test`}, 'verified') returning id`;
  const year = 2024 - Math.floor(Math.random() * 20);
  const booking_number = `PH-${t.toUpperCase()}`;
  const dd = 1 + Math.floor(Math.random() * 25);
  const pickup = `${year}-0${1 + Math.floor(Math.random() * 9)}-${String(dd).padStart(2, '0')} 14:00+00`;
  const ret = new Date(new Date(pickup.replace(' ', 'T').replace('+00', 'Z')).getTime() + 2 * 86_400_000).toISOString();
  const cols = (await sql<Array<{ c: string }>>`select column_name as c from information_schema.columns
     where table_schema = 'public' and table_name = 'bookings' and is_generated = 'NEVER' order by ordinal_position`).map((x) => `"${x.c}"`).join(', ');
  const patch = { booking_number, agreement_number: null, renter_id: r!.id, status: 'closed', renews_booking_id: null, pickup_at: pickup, return_at: ret,
    original_return_at: ret, booked_at: pickup, checked_in_at: null, handed_over_at: null };
  await sql.unsafe(`insert into bookings (${cols}) select ${cols} from jsonb_populate_record(null::bookings,
      (select to_jsonb(b) || jsonb_build_object('id', gen_random_uuid()) || $j$${JSON.stringify(patch)}$j$::jsonb
        || jsonb_build_object('billable_days', public.calc_billable_days('${pickup}'::timestamptz, '${ret}'::timestamptz),
             'km_allowance_total', b.km_allowance_per_day * public.calc_billable_days('${pickup}'::timestamptz, '${ret}'::timestamptz))
        from bookings b where b.status = 'confirmed' limit 1))`);
  return { renter_id: r!.id, booking_number, legal_name, mobile };
}

test('Texts and calls: customer service reads a renter\'s text, takes a suggestion, sends it; an unknown caller becomes a lead', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const ours = (await sql<Array<{ n: string }>>`select app.phone_our_number() as n`)[0]!.n;
  const r = await renterWithBooking(sql);
  const stranger = number();
  const cs = await mkUser(sql, 'va', 'cs');
  const page = await ctx(browser);
  // the webhook refuses an unsigned delivery
  expect((await page.request.post('/api/webhooks/quo', { data: JSON.stringify(SAMPLES.messageReceived), headers: { 'content-type': 'application/json' } })).status()).toBe(401);
  expect(await deliver(page, SAMPLES.messageReceived, (b) => { b.data.resource.id = `AC${tag()}`; b.data.resource.text = 'Can I pick up an hour early?'; b.data.context.senderIdentifier = r.mobile; b.data.context.recipientIdentifiers = [ours]; })).toBe(200);
  expect(await deliver(page, SAMPLES.callMissed, (b) => { b.data.resource.id = `AC${tag()}`; b.data.context.participants = { workspace: [ours], external: [stranger], resolution: 'available' }; })).toBe(200);
  const [task] = await sql<Array<{ queue: string }>>`select t.queue from tasks t join phone_threads p on p.id = t.related_id where p.number = ${stranger} and t.task_type = 'phone_missed_call'`;
  expect(task?.queue, 'a missed call raises a task').toBeTruthy();
  expect((await sql`select 1 from phone_outbox o join phone_threads p on p.id = o.thread_id where p.number = ${stranger}`).length, 'no automatic text (Quo\'s own auto-reply is used)').toBe(0);

  await signIn(page, cs.email, '/va');
  await page.goto('/va/chat', { waitUntil: 'networkidle' });
  await page.getByTestId('tab-phone').click();
  await page.waitForURL(/view=phone/);
  const inbox = page.getByTestId('phone-inbox');
  await expect(inbox).toBeVisible();
  await inbox.getByTestId('phone-item').filter({ hasText: shown(r.mobile) }).first().click();
  const thread = page.getByTestId('phone-thread');
  await expect(thread.getByText('Can I pick up an hour early?')).toBeVisible();
  await expect(thread.getByText(`booking ${r.booking_number}`).first()).toBeVisible();
  await check(page, 'va texts and calls');
  await thread.getByTestId('phone-suggest').click();
  const box = thread.getByLabel(/^Text to/);
  await expect(box).toHaveValue(/CarmaCars$/, { timeout: 15_000 });
  await thread.getByRole('button', { name: 'Send text' }).click();
  await expect(box).toHaveValue('');
  const [sent] = await sql<Array<{ status: string; body: string }>>`select o.status, o.body from phone_outbox o join phone_threads p on p.id = o.thread_id where p.number = ${r.mobile} and o.kind = 'staff' order by o.created_at desc limit 1`;
  expect(sent?.status).toBe('sent');
  await expect(thread.locator('[data-direction="out"]').filter({ hasText: sent!.body }).first()).toBeVisible();

  // Unknown callers: the missed call, then Create lead
  await page.getByTestId('phone-unknown-tab').click();
  await inbox.getByTestId('phone-item').filter({ hasText: shown(stranger) }).first().click();
  await expect(thread.getByTestId('phone-call').filter({ hasText: 'Missed call' }).first()).toBeVisible();
  await page.getByTestId('phone-link').getByLabel('Name').fill('Walt Weekend');
  await page.getByTestId('phone-link').getByRole('button', { name: 'Create lead' }).click();
  await expect(page.getByRole('status').filter({ hasText: 'Lead created.' })).toBeVisible();
  const [lead] = await sql<Array<{ kind: string; name: string }>>`select l.kind, l.name from leads l join phone_threads p on p.lead_id = l.id where p.number = ${stranger}`;
  expect(lead).toEqual({ kind: 'phone', name: 'Walt Weekend' });
  await check(page, 'va unknown caller');
  await sql.end();
});

test('Admin: the booking\'s History tab and the renter page show the calls and texts; Live chat has the Texts and calls tab', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const ours = (await sql<Array<{ n: string }>>`select app.phone_our_number() as n`)[0]!.n;
  const r = await renterWithBooking(sql);
  const page = await ctx(browser);
  expect(await deliver(page, SAMPLES.messageReceived, (b) => { b.data.resource.id = `AC${tag()}`; b.data.resource.text = 'Running ten minutes late'; b.data.context.senderIdentifier = r.mobile; b.data.context.recipientIdentifiers = [ours]; })).toBe(200);
  const callId = `AC${tag()}`;
  expect(await deliver(page, SAMPLES.callCompleted, (b) => { b.data.resource.id = callId; b.data.context.participants = { workspace: [ours], external: [r.mobile], resolution: 'available' }; })).toBe(200);
  expect(await deliver(page, SAMPLES.callSummary, (b) => { b.data.resource.callId = callId; b.data.resource.summary = ['Renter asked to move the pickup by an hour.']; b.data.context.participants = { workspace: [ours], external: [r.mobile], resolution: 'available' }; })).toBe(200);
  // the booking the text was attached to (the renter's current one)
  const [att] = await sql<Array<{ booking_number: string }>>`select b.booking_number from phone_activity a join bookings b on b.id = a.booking_id where a.body = 'Running ten minutes late' and a.renter_id = ${r.renter_id} order by a.created_at desc limit 1`;
  expect(att?.booking_number, 'the text is kept with a booking of the renter').toBeTruthy();
  const admin = await mkUser(sql, 'admin');
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/bookings/${encodeURIComponent(att!.booking_number)}?tab=history`, { waitUntil: 'networkidle' });
  const card = page.getByTestId('booking-calls');
  await expect(card.getByText('Running ten minutes late').first()).toBeVisible();
  await expect(card.getByTestId('call-summary').filter({ hasText: 'Renter asked to move the pickup by an hour.' })).toBeVisible();
  // the line does not record calls: no transcript or recording section on a call without them
  await expect(card.getByRole('button', { name: 'Transcript' })).toHaveCount(0);
  await check(page, 'admin booking history');
  await page.goto(`/admin/renters/${r.renter_id}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('renter-calls').getByText('Running ten minutes late').first()).toBeVisible();
  await check(page, 'admin renter page');
  await page.goto('/admin/chat?view=phone', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('phone-inbox')).toBeVisible();
  await check(page, 'admin texts and calls');
  await page.goto('/admin/settings/program', { waitUntil: 'networkidle' });
  await expect(page.getByText('Phone and texts (Quo)').first()).toBeVisible();
  await sql.end();
});
