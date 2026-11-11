import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';
import { signQuo } from '../../src/features/phone/webhook';
import { SAMPLES } from '../../src/features/phone/samples';

// Migration 0800 end to end, at 375 and 1440, with Quo mocked (signed with the local fake's webhook secret, as phone.spec):
// a renter calls; customer service, signed in on another page of their portal, gets the caller pop-up within one poll with
// the renter's name and booking, writes a note from it, and finds the note on the renter's record. An unknown number shows
// Unknown caller and becomes a lead in one tap. The Admin sees the pop-up and the note on the renter page.
const PW = 'correct horse battery';
const SECRET = 'whsec_' + 'Y2FybWFjYXJzLWxvY2FsLXF1by13ZWJob29rLXNlY3JldA==';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
const number = () => `+1416${String(2000000 + Math.floor(Math.random() * 7999999)).slice(0, 7)}`;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function mkUser(sql: Sql, role: 'admin' | 'va', fn?: 'cs') {
  const id = randomUUID(); const email = `${role}.cp.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Casey Caller ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (fn) await sql`insert into staff_profiles (user_id, staff_type, va_function) values (${id}, 'va', ${fn})`;
  return { id, email };
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
type Delivery = { id: string; data: { resource: Record<string, unknown>; context: Record<string, unknown> } };
// every number a test rang, hung up after each test whether it passed or not (see hangUp)
const rung: string[] = [];
async function ring(page: Page, ours: string, theirs: string): Promise<number> {
  rung.push(theirs);
  const body = JSON.parse(JSON.stringify(SAMPLES.callRinging)) as Delivery;
  body.id = `EV${randomUUID()}`;
  body.data.resource.id = `AC${tag()}${tag()}`;
  body.data.resource.createdAt = new Date().toISOString();
  body.data.resource.updatedAt = new Date().toISOString();
  body.data.context.participants = { workspace: [ours], external: [theirs], resolution: 'available' };
  const raw = JSON.stringify(body);
  return (await page.request.post('/api/webhooks/quo', { data: raw, headers: { 'content-type': 'application/json', ...(await signQuo(raw, SECRET, `msg_${randomUUID()}`)) } })).status();
}

// the calls a test rang are hung up when it ends: a ringing call shows on every Admin and customer service page for 30
// minutes (app.caller_live), which would cover the other tests' pages in the shared test database
async function hangUp(sql: ReturnType<typeof db>, numbers: string[]) {
  await sql`update phone_activity a set started_at = now() - interval '40 minutes', ended_at = now() - interval '35 minutes' from phone_threads t
             where t.id = a.thread_id and a.kind = 'call' and a.ended_at is null and t.number = any (${numbers})`;
}

test.describe.configure({ mode: 'serial' });
// a failed test must not leave its call ringing on every other test's pages (CI run 43065252052: two retries' calls covered
// the Admin pages of the shard for half an hour)
test.afterEach(async () => {
  if (!rung.length) return;
  const sql = db();
  try { await hangUp(sql, rung.splice(0)); } finally { await sql.end(); }
});

test('Customer service: a renter calls, the pop-up shows who it is, a note from the pop-up is on their record; an unknown caller becomes a lead', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const ours = (await sql<Array<{ n: string }>>`select app.phone_our_number() as n`)[0]!.n;
  const mobile = number();
  const t = tag();
  const [r] = await sql<Array<{ id: string }>>`insert into renters (legal_name, date_of_birth, mobile, email, identity_status)
    values (${`Callum Caller ${t}`}, '1990-05-05', ${mobile.replace(/^\+1(\d{3})(\d{3})(\d{4})$/, '($1) $2-$3')}, ${`callum.${t}@example.test`}, 'verified') returning id`;
  const cs = await mkUser(sql, 'va', 'cs');
  const page = await ctx(browser);
  await signIn(page, cs.email, '/staff');
  await page.goto('/staff/renters', { waitUntil: 'networkidle' });
  expect(await ring(page, ours, mobile)).toBe(200);
  const card = page.getByTestId('caller-card').filter({ hasText: `Callum Caller ${t}` });
  await expect(card, 'the pop-up comes within one poll').toBeVisible({ timeout: 25_000 });
  await expect(card.getByText('Ringing now')).toBeVisible();
  await expect(card.getByTestId('caller-balance')).toHaveText('Nothing owed');
  await check(page, 'staff caller pop-up');
  await card.getByTestId('renter-note-body').fill('Asked about adding a second driver; sent the link.');
  await card.getByTestId('renter-note-add').click();
  await expect(card.getByRole('status').filter({ hasText: 'Note added.' })).toBeVisible();
  const [n] = await sql<Array<{ author_role: string; call_id: string | null }>>`select author_role, call_id from renter_notes where renter_id = ${r!.id}`;
  expect(n).toMatchObject({ author_role: 'cs' });
  expect(n!.call_id, 'the note is tied to the call').toBeTruthy();
  await card.getByTestId('caller-open').click();
  await page.waitForURL(/\/staff\/renters\?id=/);
  await expect(page.getByTestId('activity-log').getByText('Asked about adding a second driver; sent the link.')).toBeVisible();
  await check(page, 'staff renter notes');
  await page.getByTestId('caller-close').first().click();
  await expect(card).toHaveCount(0);

  // an unknown number
  const stranger = number();
  expect(await ring(page, ours, stranger)).toBe(200);
  const unk = page.getByTestId('caller-card').filter({ hasText: 'Unknown caller' });
  await expect(unk).toBeVisible({ timeout: 25_000 });
  await unk.getByTestId('caller-create-lead').click();
  await expect(unk.getByRole('status').filter({ hasText: 'Lead created.' })).toBeVisible();
  const [lead] = await sql<Array<{ kind: string }>>`select l.kind from leads l join phone_threads p on p.lead_id = l.id where p.number = ${stranger}`;
  expect(lead?.kind).toBe('phone');
  await hangUp(sql, [mobile, stranger]);
  await sql.end();
});

test('Admin: the pop-up on any Admin page, and the renter page\'s notes with Remove', async ({ browser }) => {
  test.setTimeout(120_000);
  const sql = db();
  const ours = (await sql<Array<{ n: string }>>`select app.phone_our_number() as n`)[0]!.n;
  const mobile = number();
  const t = tag();
  const [r] = await sql<Array<{ id: string }>>`insert into renters (legal_name, date_of_birth, mobile, email, identity_status)
    values (${`Ada Admincall ${t}`}, '1990-05-05', ${mobile}, ${`ada.${t}@example.test`}, 'verified') returning id`;
  const admin = await mkUser(sql, 'admin');
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  expect(await ring(page, ours, mobile)).toBe(200);
  const card = page.getByTestId('caller-card').filter({ hasText: `Ada Admincall ${t}` });
  await expect(card).toBeVisible({ timeout: 25_000 });
  await card.getByTestId('renter-note-body').fill('Wants a weekly rate.');
  await card.getByTestId('renter-note-add').click();
  await expect(card.getByRole('status').filter({ hasText: 'Note added.' })).toBeVisible();
  await page.goto(`/admin/renters/${r!.id}`, { waitUntil: 'networkidle' });
  // r35 (0850): the notes are in the Activity log, each with Remove for an Admin
  const notes = page.getByTestId('activity-log');
  await expect(notes.getByText('Wants a weekly rate.')).toBeVisible();
  await check(page, 'admin renter notes');
  page.once('dialog', (d) => void d.accept('Duplicate'));
  await notes.getByTestId('renter-note-remove').first().click();
  await expect(notes.getByRole('status').filter({ hasText: 'Note removed.' })).toBeVisible();
  const [x] = await sql<Array<{ removed_reason: string }>>`select removed_reason from renter_notes where renter_id = ${r!.id}`;
  expect(x?.removed_reason).toBe('Duplicate');
  await hangUp(sql, [mobile]);
  await sql.end();
});
