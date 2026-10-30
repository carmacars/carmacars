import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { aiAllowanceLock, db, noOverflow } from './helpers';

// Migration 0133 end to end, at 375 and 1440, with the deterministic stub model (LLM_PROVIDER=fake; a JSON step typed
// in the panel is the model's answer). The assistant makes an offer: the card shows the customer, the car, the dates,
// the price lines, the deposit and how it is paid and sent, and nothing exists until Confirm; Confirm makes and sends it
// through the offer screen's function, as the staff member, and the booking's history names them. Cancel changes
// nothing. When the day's free allowance is used, the assistant says so and when it is back. Settings > Usage shows
// Workers AI by feature, and Workers AI has no "Allow paid usage". The tests change the day's Workers AI figures.
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
async function person(sql: Sql, role: 'admin' | 'va', fn?: 'cs' | 'sales') {
  const id = randomUUID(); const email = `${role}${fn ?? ''}.ao.${Date.now()}.${tag()}@example.test`; const name = `Ada ${role === 'admin' ? 'Admin' : 'Assist'} ${tag()}`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, staff_type, va_function, home_address, home_postal_code) values (${id}, 'va', ${fn!}, '1 Test Lane, Toronto', 'M5V 1A1')`;
  return { id, email, name };
}
async function car(sql: Sql, adminId: string) {
  const plate = `AO${tag().toUpperCase()}`.slice(0, 8);
  const vin = `1XFCX${randomBytes(6).toString('hex').toUpperCase()}`.slice(0, 17).padEnd(17, '0');
  const [r] = await sql`select app.vehicle_add(${adminId}::uuid, ${sql.json({ supply_type: 'company', vin, plate, year: 2024, make: 'Kia', model: 'K5',
    rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as v`;
  return { id: String((r!.v as { vehicle_id: string }).vehicle_id), plate };
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function signIn(page: Page, email: string, path: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await b.isVisible().catch(() => false)) await b.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(path), { timeout: 60_000 });
}
async function neurons(sql: Sql, purpose: string, n: number) {
  await sql`delete from provider_calls where purpose like 'e2e_%' or (purpose = 'staff_assistant' and provider = 'e2e')`;
  if (n > 0) await sql`insert into provider_calls (provider, purpose, ok, units, unit) values ('e2e', ${purpose}, true, ${n}, 'neurons')`;
  await sql`select app.job_usage_refresh()`;
}
async function askIt(page: Page, text: string) {
  await page.getByTestId('assistant-input').fill(text);
  await page.getByTestId('assistant-send').click();
  await expect(page.getByTestId('assistant-busy')).toHaveCount(0, { timeout: 30_000 });
}
const day = (n: number) => { const d = new Date(Date.now() + n * 86_400_000); return d.toISOString().slice(0, 10); };

test.describe.configure({ mode: 'serial' });
let unlock: (() => Promise<void>) | null = null;
test.beforeEach(async () => { unlock = await aiAllowanceLock('alone'); const sql = db(); await neurons(sql, 'e2e_usage', 0); await sql.end(); });
test.afterEach(async () => { const sql = db(); await neurons(sql, 'e2e_usage', 0); await sql.end(); await unlock?.(); unlock = null; });

test('Assistant: an offer comes as a card with the full summary, runs only on Confirm, as the staff member', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  const a = await person(sql, 'admin');
  const cs = await person(sql, 'va', 'cs');
  const k5 = await car(sql, a.id);
  const email = `nora.${tag()}@example.test`;
  const page = await ctx(browser);
  await signIn(page, cs.email, '/staff');
  await page.getByTestId('assistant-open').first().click();
  await expect(page.getByTestId('assistant-panel')).toBeVisible();

  const step = (extra: Record<string, unknown> = {}) => JSON.stringify({ action: 'tool', tool: 'create_offer', args: { car: k5.plate, pickup_at: `${day(5)} 10:00`, return_at: `${day(7)} 10:00`,
    renter_name: 'Nora Assist', renter_email: email, renter_mobile: '(289) 555-0133', renter_date_of_birth: '1990-04-05', deposit_pay: 'cash', notify: 'email', ...extra } });
  // Cancel first: nothing is made
  await askIt(page, step());
  const first = page.getByTestId('assistant-proposal').last();
  await expect(first.getByTestId('assistant-summary')).toContainText(`Send an offer for the 2024 Kia K5 to Nora Assist`);
  await first.getByTestId('assistant-cancel').click();
  await expect(first.getByTestId('assistant-decided')).toHaveText('Cancelled. Nothing was changed.');
  expect((await sql`select count(*)::int as n from bookings where vehicle_id = ${k5.id}::uuid`)[0]!.n).toBe(0);

  // the card: customer, car, dates, price lines, deposit, payments
  await askIt(page, step());
  const card = page.getByTestId('assistant-proposal').last();
  await expect(card.getByTestId('assistant-summary')).toContainText('due at booking, by email?');
  const details = card.getByTestId('assistant-details');
  await expect(details).toHaveCount(3);
  await expect(card).toContainText('Nora Assist');
  await expect(card).toContainText('(new customer)');
  await expect(card).toContainText('2024 Kia K5');
  await expect(card).toContainText('Due at booking');
  await expect(card).toContainText('Deposit (refundable)');
  await expect(card).toContainText('$300.00 by cash at pickup');
  await expect(card).toContainText('By card, when the customer signs and pays online');
  expect((await sql`select count(*)::int as n from bookings where vehicle_id = ${k5.id}::uuid`)[0]!.n).toBe(0);
  await check(page, 'assistant offer card');

  await card.getByTestId('assistant-confirm').click();
  await expect(card.getByTestId('assistant-decided')).toContainText(/^Done\. Offer [A-Z0-9-]+ sent\.$/, { timeout: 20_000 });
  const [b] = await sql`select b.id, b.status, b.deposit_pay_method, r.legal_name from bookings b join renters r on r.id = b.renter_id where b.vehicle_id = ${k5.id}::uuid`;
  expect(b).toMatchObject({ status: 'offered', deposit_pay_method: 'cash', legal_name: 'Nora Assist' });
  const [ev] = await sql`select note from booking_events where booking_id = ${b!.id} and details ->> 'via' = 'assistant'`;
  expect(String(ev!.note)).toContain(`Offer made with the staff assistant by ${cs.name}`);
  const [au] = await sql`select actor_user_id, after ->> 'note' as note from audit_log where action = 'assistant_action' and after ->> 'name' = 'offer_create' and actor_user_id = ${cs.id}`;
  expect(au).toMatchObject({ actor_user_id: cs.id, note: 'via assistant' });

  // what the customer owes on it
  const [bn] = await sql`select booking_number from bookings where id = ${b!.id}`;
  await askIt(page, JSON.stringify({ action: 'tool', tool: 'booking_balance', args: { booking: bn!.booking_number } }));
  await expect(page.getByTestId('assistant-results').last()).toContainText(`${bn!.booking_number}: $`);
  await check(page, 'assistant balance');
  await page.context().close();
  await sql.end();
});

test('Assistant: the day\'s free allowance used up says so and when it is back; Settings > Usage shows AI by feature, never paid', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  const a = await person(sql, 'admin');
  await neurons(sql, 'e2e_usage', 10_400);
  const page = await ctx(browser);
  await signIn(page, a.email, '/admin');
  await page.getByTestId('assistant-open').first().click();
  await askIt(page, 'What needs doing today?');
  await expect(page.getByTestId('assistant-paused')).toContainText(/^Today's free AI allowance is used up \(1\d,\d{3} of 10,000 neurons\)\. The assistant is back at midnight, Toronto time\./);
  await check(page, 'assistant used up');
  await page.keyboard.press('Escape');

  // To do: stopped for today, nothing to pay
  await page.goto('/admin', { waitUntil: 'networkidle' });
  const todo = page.getByTestId('usage-card-workers_ai');
  await expect(todo).toContainText('Stopped for today, never paid.');
  await expect(todo.getByTestId('usage-allow-workers_ai')).toHaveCount(0);

  await page.goto('/admin/settings/usage', { waitUntil: 'networkidle' });
  const ai = page.getByTestId('usage-ai-features');
  await expect(ai).toBeVisible();
  await expect(ai.getByTestId('usage-ai-used')).toContainText(/1\d,\d{3} of 10,000 neurons today/);
  await expect(ai.getByTestId('usage-ai-row-e2e_usage')).toContainText('Background');
  await expect(page.getByTestId('usage-workers_ai-paid')).toContainText('Never');
  await expect(page.getByTestId('usage-page-allow-workers_ai')).toHaveCount(0);
  await check(page, 'settings usage by feature');
  // the shares
  await page.getByTestId('usage-ai-shares').click();
  const form = page.getByTestId('usage-ai-shares-form');
  await form.getByLabel('Kept for the staff assistant (%)').fill('75');
  await page.getByTestId('usage-ai-shares-submit').click();
  await expect(ai).toContainText('keeps 75% of the day', { timeout: 15_000 });
  await sql`update program_settings set ai_assistant_reserve_bps = 7000`;
  await page.context().close();
  await neurons(sql, 'e2e_usage', 0);
  await sql.end();
});
