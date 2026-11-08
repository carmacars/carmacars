import { expect, test, type Page } from '@playwright/test';
import { createHash, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db } from './helpers';

// Migration 0810 end to end: Book it now from Claude's connector (an offer that is out is previewed, nothing changes, then
// confirmed with the same arguments and booked: waiting for payment), and the note on a request replaced by a newer one
// ("Replaced by" on the old booking, "Replaces" on the new one) on the Admin and the staff booking page.
const PW = 'correct horse battery';
const sha = (s: string) => createHash('sha256').update(s).digest('hex');
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
type Sql = ReturnType<typeof db>;

async function mkUser(sql: Sql, kind: 'admin' | 'va', name: string) {
  const id = randomUUID(); const email = `${kind}.bn.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${kind})`;
  if (kind === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'cs', 500000)`;
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
async function mkCar(sql: Sql, adminId: string): Promise<string> {
  const vin = `5XYKF${randomBytes(6).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '3').replace(/O/g, 'A');
  const [r] = await sql`select app.vehicle_add(${adminId}, ${sql.json({ supply_type: 'company', vin, plate: `BN${randomBytes(2).toString('hex').toUpperCase()}`, year: 2024, make: 'Kia', model: 'K5',
    rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as v`;
  return (r!.v as { vehicle_id: string }).vehicle_id;
}
async function offer(sql: Sql, by: string, car: string, days: number) {
  const from = new Date(Date.now() + days * 86_400_000); from.setMinutes(0, 0, 0);
  const [r] = await sql`select app.door(${by}, 'aal2', 'ops_do', 'offer_create', ${sql.json({ vehicle_id: car, pickup_at: from.toISOString(), return_at: new Date(from.getTime() + 3 * 86_400_000).toISOString(),
    renter: { full_name: 'Bea Connector', email: `bea.${tag()}@example.test`, mobile: `289555${String(Date.now()).slice(-4)}`, date_of_birth: '1990-05-06' },
    coverage_option: 1, sales_choice: 'sourced', channels: { email: false, text: false }, notify: false })}) as v`;
  return r!.v as { booking_number: string; booking_id: string };
}

test.describe.configure({ mode: 'serial' });

test('connector: book_offer_now is previewed (nothing changes), then confirmed: waiting for payment', async ({ request }, info) => {
  test.skip(info.project.name !== 'desktop-1440', 'one width is enough for an API');
  test.setTimeout(120_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', `Ada Connector ${tag()}`);
  const key = `cc_live_${randomBytes(32).toString('base64url')}`;
  try {
    const car = await mkCar(sql, admin.id);
    const o = await offer(sql, admin.id, car, 30);
    expect((await sql`select status from bookings where id = ${o.booking_id}`)[0]!.status).toBe('offered');
    await sql`insert into api_keys (user_id, kind, name, prefix, key_hash, scopes, created_by)
              values (${admin.id}, 'key', 'e2e bn', ${key.slice(0, 12)}, ${sha(key)}, ${['bookings:read', 'admin:read', 'admin:write']}, ${admin.id})`;
    const auth = { authorization: `Bearer ${key}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream' };
    let n = 0;
    const call = async (name: string, args: Record<string, unknown>) => {
      const r = await request.post('/api/mcp', { headers: auth, data: { jsonrpc: '2.0', id: ++n, method: 'tools/call', params: { name, arguments: args } } });
      return (await r.json()).result as { isError: boolean; structuredContent: Record<string, unknown> };
    };
    const list = await request.post('/api/mcp', { headers: auth, data: { jsonrpc: '2.0', id: 99, method: 'tools/list' } });
    const names = ((await list.json()).result.tools as Array<{ name: string }>).map((t) => t.name);
    expect(names).toContain('book_offer_now');

    const args = { booking: o.booking_number, reason: 'The renter agreed by phone' };
    const pv = await call('book_offer_now', args);
    expect(pv.isError).toBe(false);
    expect(pv.structuredContent.preview).toBe(true);
    expect((await sql`select status from bookings where id = ${o.booking_id}`)[0]!.status).toBe('offered');
    expect((await call('book_offer_now', { ...args, confirm: true })).isError).toBe(true); // no preview_id
    const done = await call('book_offer_now', { ...args, confirm: true, preview_id: pv.structuredContent.preview_id });
    expect(done.isError).toBe(false);
    expect(done.structuredContent.done).toBe(true);
    expect((await sql`select status from bookings where id = ${o.booking_id}`)[0]!.status).toBe('pending_payment');
    const [e] = await sql`select count(*)::int n from booking_events where booking_id = ${o.booking_id} and kind = 'offer_booked_now'`;
    expect(e!.n).toBe(1);
  } finally {
    await sql`update api_keys set revoked_at = now() where key_hash = ${sha(key)}`;
    await sql.end();
  }
});

test('a replaced request: "Replaced by" on the old booking, "Replaces" on the new one, Admin and staff pages', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', `Ada Chain ${tag()}`);
  const staff = await mkUser(sql, 'va', `Cass Chain ${tag()}`);
  const car = await mkCar(sql, admin.id);
  const oldB = await offer(sql, admin.id, car, 50);
  const newB = await offer(sql, admin.id, car, 90);
  await sql`update bookings set superseded_by = ${newB.booking_id} where id = ${oldB.booking_id}`;
  const c = await browser.newContext({ baseURL: test.info().project.use.baseURL, viewport: { width: 1440, height: 900 } });
  const page = await c.newPage();
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/bookings/${oldB.booking_number}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('booking-replaced-by')).toContainText(`Replaced by #${newB.booking_number}`);
  await page.getByTestId('booking-replaced-by').getByRole('link').click();
  await page.waitForURL(new RegExp(`/admin/bookings/${newB.booking_number}`));
  await expect(page.getByTestId('booking-replaces')).toContainText(`Replaces #${oldB.booking_number}`);
  await c.close();

  const c2 = await browser.newContext({ baseURL: test.info().project.use.baseURL, viewport: { width: 1440, height: 900 } });
  const p2 = await c2.newPage();
  await signIn(p2, staff.email, '/staff');
  await p2.goto(`/staff/bookings/${oldB.booking_number}`, { waitUntil: 'networkidle' });
  await expect(p2.getByTestId('booking-replaced-by')).toContainText(`#${newB.booking_number}`);
  await c2.close();
  await sql.end();
});
