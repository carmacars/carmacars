import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow } from './helpers';

// r48 MAP (3350, 3351): staff and app users on the live map, end to end.
//   1. A Fleet staff member opens Profile: Location on the live map asks for the electronic monitoring policy; accepting it
//      queues their copy (staff_location_policy) once. Off duty nothing is stored; clocked in, a report from the browser is.
//   2. A renter with a pickup in an hour shares from Account > Profile; turning it off removes the position at once.
//   3. An Admin sees the People layer with its role filters on the Visitors map; a filter hides its people.
//   4. Customer service sees the renters filter only (their scope); Finance sees no People layer.
// axe and no overflow at 375 and 1440; screenshots of the card at 320, 375, 768, 1280 and 1440 with a long, French-length name.
const PW = 'correct horse battery';
const WIDTHS = [320, 375, 768, 1280, 1440];
const SHOTS = process.env.SHOTS_DIR ?? 'test-results/r48map';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
type Sql = ReturnType<typeof db>;

async function signIn(page: Page, email: string, to: RegExp) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => to.test(u.pathname), { timeout: 60_000 });
}
async function ctx(browser: Browser, w: number, h: number) {
  const c = await browser.newContext({ viewport: { width: w, height: h }, baseURL: test.info().project.use.baseURL,
    permissions: ['geolocation'], geolocation: { latitude: 43.6532, longitude: -79.3832, accuracy: 15 } });
  return c.newPage();
}
async function mkUser(sql: Sql, role: 'admin' | 'va' | 'renter', name: string, va?: string) {
  const id = randomUUID(), email = `map.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name, phone) values (${id}, ${email}, ${name}, '+14165550142')`;
  if (role !== 'renter') await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Toronto, ON', 'M5V 1A1', 'va', ${va!})`;
  return { id, email };
}
async function report(page: Page, lat: number, lng: number) {
  return page.evaluate(async ([la, ln]) => {
    const r = await fetch('/api/me/location', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ action: 'report', lat: la, lng: ln, accuracy_m: 12, at: new Date().toISOString(), source: 'web' }) });
    return (await r.json()) as { ok: boolean; data?: { stored?: boolean; why?: string } };
  }, [lat, lng] as const);
}
async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).exclude('.lm-map').analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((x) => `${where} ${x.id}`)).toEqual([]);
}
async function shots(page: Page, name: string, back: { width: number; height: number }) {
  mkdirSync(SHOTS, { recursive: true });
  for (const w of WIDTHS) {
    await page.setViewportSize({ width: w, height: 900 });
    await noOverflow(page);
    // no squished text: every line of the card keeps a readable width
    const thin = await page.evaluate(() => [...document.querySelectorAll('[data-testid="location-card"] p, [data-testid="location-card"] .option__body, [data-testid="location-card"] button')]
      .filter((e) => (e.textContent ?? '').trim().length > 12 && e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().width < 120).map((e) => (e.textContent ?? '').trim().slice(0, 40)));
    expect(thin, `${name} at ${w}`).toEqual([]);
    await page.locator('[data-testid="location-card"]').screenshot({ path: `${SHOTS}/${name}-${w}.png` });
  }
  await page.setViewportSize(back);
}

test.describe.configure({ mode: 'serial' });

test('People on the live map: the policy, on shift only, a renter at pickup, Admin layers and filters, scopes', async ({ browser }, info) => {
  test.setTimeout(420_000);
  const phone = info.project.name.startsWith('phone');
  const size = phone ? { width: 375, height: 812 } : { width: 1440, height: 900 };
  const sql = db();
  const t = tag(), T = t.toUpperCase();
  const fleet = await mkUser(sql, 'va', 'Marie-Christine Beauchemin-Lavallée', 'fleet');
  const admin = await mkUser(sql, 'admin', 'Ada Admin');
  const cs = await mkUser(sql, 'va', 'Cy Service', 'cs');
  const fin = await mkUser(sql, 'va', 'Fin Ance', 'finance');
  const rita = await mkUser(sql, 'renter', 'Rita Pickup');
  const ou = randomUUID(), owner = randomUUID(), car = randomUUID();
  await sql`insert into users (id, email, full_name) values (${ou}, ${`map.owner.${t}@example.test`}, 'Oli Owner')`;
  await sql`insert into owners (id, user_id, owner_type, legal_name, status, email, phone) values (${owner}, ${ou}, 'individual', 'Oli Owner', 'active', ${`map.owner.${t}@example.test`}, '416-555-0100')`;
  await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, enrollment_date)
            values (${car}, ${owner}, ${`F-${t}`}, 2024, 'Toyota', 'Corolla', ${('MP' + randomBytes(8).toString('hex').toUpperCase()).slice(0, 17)}, ${`MP${T}`.slice(0, 8)}, 'standard', 'available', 'managed', 'transfer', true, current_date - 60)`;
  const [r] = await sql`insert into renters (user_id, legal_name, email, mobile, date_of_birth, identity_status) values (${rita.id}, 'Rita Pickup', ${rita.email}, '+14165550142', '1990-05-05', 'verified') returning id`;
  const n = `MP-${T}`;
  await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
      daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total,
      overage_cents_per_km, deposit_cents, blocks_calendar, total_due_at_booking_cents, created_by)
    values (${n}, 'standard', 'confirmed', ${car}, ${r!.id}, now(), now() + interval '1 hour', now() + interval '3 days', now() + interval '3 days',
      public.calc_billable_days(now() + interval '1 hour', now() + interval '3 days'), 6900, 7900, 39000, 140000, 'daily', 20700, 200,
      200 * public.calc_billable_days(now() + interval '1 hour', now() + interval '3 days'), 25, 0, true, 20700, ${admin.id})`;

  try {
    // ---------------------------------------------------------------- 1. Fleet: the policy, then on shift only
    const fp = await ctx(browser, size.width, size.height);
    await signIn(fp, fleet.email, /^\/staff/);
    await fp.goto('/staff/profile#location', { waitUntil: 'networkidle' });
    const card = fp.getByTestId('location-card');
    await expect(card).toBeVisible();
    await expect(card.getByTestId('location-state')).toContainText('electronic monitoring policy');
    await card.getByTestId('location-accept').click();
    await expect(card.getByTestId('location-policy-done')).toBeVisible();
    const [q] = await sql`select count(*)::int n from app_events where code = 'staff_location_policy' and entity_id = ${fleet.id}`;
    expect(q!.n).toBe(1);
    await expect(card.getByTestId('location-state')).toContainText('off duty');
    expect((await report(fp, 43.65, -79.38)).data?.why).toBe('off_duty');
    await sql`insert into staff_clock_entries (user_id, started_at, created_by) values (${fleet.id}, now() - interval '1 hour', ${fleet.id})`;
    // the page's own sharer may have sent one already (the browser allows it here): then this one is 'soon'
    expect(await report(fp, 43.65, -79.38).then((x) => x.data?.stored === true || x.data?.why === 'soon')).toBe(true);
    expect((await sql`select reason from person_locations where user_id = ${fleet.id}`)[0]?.reason).toBe('shift');
    await fp.reload({ waitUntil: 'networkidle' });
    await expect(card.getByTestId('location-state')).toContainText('on shift');
    await axe(fp, 'staff profile');
    await shots(fp, 'staff-card', size);

    // ---------------------------------------------------------------- 2. the renter at pickup, and off means off
    const rp = await ctx(browser, size.width, size.height);
    await signIn(rp, rita.email, /^\/account/);
    await rp.goto('/account/profile', { waitUntil: 'networkidle' });
    const rc = rp.getByTestId('location-card');
    await expect(rc.getByTestId('location-state')).toContainText('around your pickup');
    expect(await report(rp, 43.66, -79.39).then((x) => x.data?.stored === true || x.data?.why === 'soon')).toBe(true);
    expect((await sql`select reason from person_locations where user_id = ${rita.id}`)[0]?.reason).toBe('pickup');
    await axe(rp, 'renter profile');
    await shots(rp, 'renter-card', size);

    // ---------------------------------------------------------------- 3. Admin: the People layer and its filters
    const ap = await ctx(browser, size.width, size.height);
    await signIn(ap, admin.email, /^\/admin/);
    await ap.goto('/admin/visitors', { waitUntil: 'networkidle' });
    const layer = ap.getByTestId('lm-people-layer');
    await expect(layer).toContainText(/People \(\d+\)/, { timeout: 45_000 });
    await expect(ap.getByTestId('lm-people-staff')).toBeVisible();
    await expect(ap.getByTestId('lm-people-renter')).toBeVisible();
    const map = ap.getByTestId('live-map').locator('.lm-map').first();
    await expect.poll(async () => Number(await map.getAttribute('data-people') ?? '0'), { timeout: 30_000 }).toBeGreaterThanOrEqual(2);
    const before = Number(await map.getAttribute('data-people'));
    await ap.getByTestId('lm-people-staff').locator('input').uncheck();
    await expect.poll(async () => Number(await map.getAttribute('data-people') ?? '0')).toBeLessThan(before);
    await noOverflow(ap);
    await ap.screenshot({ path: `${SHOTS}/admin-map-${size.width}.png` });

    // the renter turns it off: their position goes at once
    await rc.getByTestId('location-switch').uncheck();
    await expect(rc.getByTestId('location-state')).toContainText('Off');
    const [left] = await sql`select count(*)::int n from person_locations where user_id = ${rita.id}`;
    expect(left!.n).toBe(0);

    // ---------------------------------------------------------------- 4. scopes: customer service renters only, Finance none
    const cp = await ctx(browser, size.width, size.height);
    await signIn(cp, cs.email, /^\/staff/);
    const cv = await cp.evaluate(async () => (await (await fetch('/api/staff/live-people')).json()) as { scope: string });
    expect(cv.scope).toBe('renters');
    const fnp = await ctx(browser, size.width, size.height);
    await signIn(fnp, fin.email, /^\/staff/);
    const fv = await fnp.evaluate(async () => (await (await fetch('/api/staff/live-people')).json()) as { scope: string; people: unknown[] });
    expect([fv.scope, fv.people.length]).toEqual(['none', 0]);
    for (const p of [fp, rp, ap, cp, fnp]) await p.context().close();
  } finally {
    await sql`delete from person_locations where user_id in (${fleet.id}, ${rita.id})`.catch(() => undefined);
    await sql.end();
  }
});
