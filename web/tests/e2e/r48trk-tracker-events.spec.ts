import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow } from './helpers';
import { signedHeaders } from '../../src/integrations/tracker/ingest';
import { fakeScenario } from '../../src/integrations/tracker/fake';

// r48 TRK (3320 to 3322): tracker events end to end, with the fake provider's signed readings.
//   1. Tracker events on: a speeding reading over 220 km/h posted to /api/tracker/ingest makes one record with its evidence
//      (the same signed request again is refused as a replay); the renter's notice (the charge and the clause) and the
//      owner's alert are queued; an Admin sees the record on Cars > Fleet tracking and charges it with the evidence attached.
//   2. A car parked at a pound lot is flagged: the flag shows with the lot's phone, Fleet's To do exists, and the path is
//      recorded. An Admin adds a pound lot.
//   3. The staff car map mirrors the panel (Fleet reads the events and records a path; Charge is Finance's and Admin's).
//   4. The owner's car page lists the alerts, with no renter and no booking.
// axe and no overflow at 375 and 1440; screenshots of the new screens at 320, 375, 768, 1280 and 1440 (a long lot name
// and car name included). Fixtures are example.test only; device ids and lots are made up.
const PW = 'correct horse battery';
const WIDTHS = [320, 375, 768, 1280, 1440];
const SHOTS = process.env.SHOTS_DIR ?? 'test-results/r48trk';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const LONG_LOT = 'Northumberland and Quinte West Regional Vehicle Impound and Storage Compound';
type Sql = ReturnType<typeof db>;
/** Tracker events is one switch for everyone: the tests of this file take turns (both widths may run at once). */
async function turn(): Promise<() => Promise<void>> {
  const c = db();
  await c.unsafe('select pg_advisory_lock(33200048)');
  return async () => { await c.end(); };
}

async function signIn(page: Page, email: string, to: RegExp) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => to.test(u.pathname), { timeout: 60_000 });
}
async function ctx(browser: Browser, w: number, h: number) {
  const c = await browser.newContext({ viewport: { width: w, height: h }, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function mkUser(sql: Sql, role: 'admin' | 'va' | 'owner', name: string, va?: string) {
  const id = randomUUID(), email = `trk.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  // a valid mobile number, so no data check box opens over the page (3197)
  await sql`insert into users (id, email, full_name, phone) values (${id}, ${email}, ${name}, '+14165550142')`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Toronto, ON', 'M5V 1A1', 'va', ${va!})`;
  return { id, email };
}
async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).exclude('.lm-map').analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((x) => `${where} ${x.id}: ${x.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function shots(page: Page, name: string, back: { width: number; height: number }) {
  mkdirSync(SHOTS, { recursive: true });
  for (const w of WIDTHS) {
    await page.setViewportSize({ width: w, height: 900 });
    await noOverflow(page);
    // no cell is squeezed into a sliver: every table cell and badge of the panel keeps a readable width
    const slivers = await page.evaluate(() => [...document.querySelectorAll('[data-testid="tracker-events"] td, [data-testid="pound-flags"] td, [data-testid="pound-lots"] td, .te-ev > span, .te-owner > li')]
      .filter((e) => (e.textContent ?? '').trim().length > 12 && e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().width < 90).map((e) => (e.textContent ?? '').trim().slice(0, 40)));
    expect(slivers, `${name} at ${w}`).toEqual([]);
    // in a table (768 and up) a stacked cell keeps its measure: the table scrolls sideways rather than crush it
    if (w >= 768) expect(await page.evaluate(() => [...document.querySelectorAll('td > .te-ev:not(.te-ev--short)')].filter((e) => e.getBoundingClientRect().width < 180).length), `${name} at ${w}: crushed cells`).toBe(0);
    await page.screenshot({ path: `${SHOTS}/${name}-${w}.png`, fullPage: true });
  }
  await page.setViewportSize(back);
}

test.describe.configure({ mode: 'serial' });

test('Tracker events: the fake provider, one record with its evidence, the notices, Charge, a pound flag, the staff mirror and the owner', async ({ browser, request }, info) => {
  test.setTimeout(600_000);
  const phone = info.project.name.startsWith('phone');
  const size = phone ? { width: 375, height: 812 } : { width: 1440, height: 900 };
  const sql = db();
  const done = await turn();
  const t = tag();
  const admin = await mkUser(sql, 'admin', 'Tara Tracker');
  const fleet = await mkUser(sql, 'va', 'Felix Fleet', 'fleet');
  const ownerUser = await mkUser(sql, 'owner', 'Olive Owner');
  const owner = randomUUID(), agr = randomUUID(), car = randomUUID(), booking = randomUUID();
  const device = `E2E-TRK-${t}-${phone ? 'P' : 'D'}`, number = `TE-${t}`.toUpperCase();
  const lot = { lat: Math.round((43.7512 + Math.random() / 100) * 1e5) / 1e5, lng: Math.round((-79.5123 - Math.random() / 100) * 1e5) / 1e5 };
  const [before] = await sql`select events_on, pound_minutes from tracker_settings`;
  try {
    // the owner's own car (enrolled), on rent on a copy of a sample booking
    const T = t.toUpperCase();
    await sql`insert into owners (id, user_id, owner_type, legal_name, status, email, phone) values (${owner}, ${ownerUser.id}, 'individual', 'Olive Owner', 'active', ${ownerUser.email}, '416-555-0100')`;
    await sql`insert into owner_agreements (id, owner_id, kind, agreement_number, agreement_date, status) values (${agr}, ${owner}, 'enrollment', ${`EA-${T}`}, current_date - 30, 'signed') on conflict (owner_id, kind) where status in ('draft', 'sent', 'signed') do update set id = excluded.id, agreement_number = excluded.agreement_number, agreement_date = excluded.agreement_date, status = excluded.status`;
    await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, fleet_policy_added_on, enrollment_date, colour)
              values (${car}, ${owner}, ${`T-${T}`}, 2023, 'Mercedes-Benz', 'GLE 450 4MATIC Coupe', ${`E2ETRK${T}`.padEnd(17, '0')}, ${`TR${T.slice(-5)}`}, 'standard', 'on_rent', 'managed', 'transfer', true, current_date - 20, current_date - 20, 'Black')`;
    const [src] = await sql`select b.id, extract(epoch from b.return_at - b.pickup_at)::int as secs from bookings b join vehicles v on v.id = b.vehicle_id
                             where v.is_sample and b.booking_type::text <> 'owner' and b.renter_id is not null order by b.pickup_at limit 1`;
    const cols = (await sql`select column_name from information_schema.columns where table_schema = 'public' and table_name = 'bookings' and is_generated = 'NEVER' and is_identity = 'NO' order by ordinal_position`)
      .map((c) => `"${String(c.column_name)}"`).join(', ');
    // the same length as the sample booking (its billable days are checked), picked up 12 hours ago
    const pickup = new Date(Date.now() - 12 * 3_600_000), back = new Date(pickup.getTime() + Number(src!.secs) * 1000);
    await sql.unsafe(`insert into bookings (${cols}) select ${cols} from jsonb_populate_record(null::bookings, (select to_jsonb(x) from bookings x where x.id = $1) || ($2::text)::jsonb)`,
      [String(src!.id), JSON.stringify({ id: booking, vehicle_id: car, owner_id: owner, booking_number: number, agreement_number: null, request_key: null, calendar_token: randomUUID(), renews_booking_id: null,
        status: 'on_rent', is_placeholder: false, pickup_at: pickup.toISOString(), return_at: back.toISOString(), original_return_at: back.toISOString(), handed_over_at: pickup.toISOString(), checked_in_at: null })]);
    const [k] = await sql`select coalesce(app.tracker_ingest_key(), app.tracker_key_new(${admin.id}) ->> 'key') as key`;
    const key = String(k!.key);
    await sql`select app.tracker_pair(${admin.id}, ${sql.json({ vehicle_id: car, device })})`;
    await sql`select app.tracker_settings_save(${admin.id}, ${sql.json({ events_on: true, pound_minutes: 0 })})`;
    await sql`select app.pound_lot_save(${admin.id}, ${sql.json({ name: `${LONG_LOT} ${T}`, address: `${T} Example Concession Road 12, Quinte West, ON`, phone: '613-555-0142',
      hours: 'Monday to Friday 8 am to 6 pm, Saturday 9 am to 1 pm', latitude: lot.lat, longitude: lot.lng, checked: true })})`;
    const post = async (points: unknown[]) => {
      const raw = JSON.stringify({ points });
      const headers = await signedHeaders(raw, key);
      return { raw, headers, res: await request.post('/api/tracker/ingest', { data: raw, headers }) };
    };

    // 1. the fake provider: over 220 km/h. One record; the same signed request again is a replay
    const now = Date.now();
    const sp = await post(fakeScenario(device, 'speeding_220', { end: now - 3_600_000 }));
    expect(sp.res.status()).toBe(200);
    expect((await sp.res.json()).events).toBe(1);
    expect((await request.post('/api/tracker/ingest', { data: sp.raw, headers: sp.headers })).status()).toBe(409);
    const [a] = await sql`select a.id, a.tier, a.speed_kmh, a.fee_code, a.clause, e.id as evidence, e.sha256, jsonb_array_length(e.readings) as readings
                            from tracker_alerts a join tracker_evidence e on e.alert_id = a.id where a.vehicle_id = ${car} and a.kind = 'speeding' and a.tier is not null`;
    expect([a!.tier, a!.speed_kmh, a!.fee_code, a!.clause]).toEqual([220, 226, 'speeding_220', '10.5 Speeding charges']);
    expect(String(a!.sha256)).toMatch(/^[0-9a-f]{64}$/);
    expect(Number(a!.readings)).toBeGreaterThan(0);
    // the notices are queued: the renter's (the charge and the clause) and the owner's (no renter, no booking)
    await sql`select app.process_events(1000)`;
    const [rn] = await sql`select o.status, e.payload from app_events e join notification_outbox o on o.event_id = e.id where e.dedupe_key = ${`renter_tracker_notice:${a!.id}`}`;
    expect(rn!.status).toBe('queued');
    expect(String((rn!.payload as Record<string, string>).event_fee)).toContain('A speeding charge of $1,000.00 plus HST applies (over 220 km/h)');
    expect(String((rn!.payload as Record<string, string>).event_ask)).toContain('Please slow down');
    // 3353: the owner's speed alert is off by default on every channel; the notice stays in the portal, the email is recorded as off
    const [on] = await sql`select o.status, o.status_reason, o.booking_id, e.payload from app_events e join notification_outbox o on o.event_id = e.id where e.dedupe_key = ${`owner_tracker_alert:${a!.id}`}`;
    expect([on!.status, on!.status_reason, on!.booking_id]).toEqual(['suppressed', 'not sent: turned off in notification preferences', null]);
    expect(JSON.stringify(on!.payload)).not.toContain(number);

    // an Admin sees the record with its evidence and charges it
    const page = await ctx(browser, size.width, size.height);
    await signIn(page, admin.email, /^\/admin/);
    await page.goto('/admin/vehicles/tracking', { waitUntil: 'networkidle' });
    const events = page.getByTestId('tracker-events');
    const row = events.getByRole('row').filter({ hasText: number }).filter({ hasText: 'Speeding over 220 km/h' });
    await expect(row).toBeVisible();
    await expect(row).toContainText('226 km/h');
    await expect(row).toContainText('$1,000 plus HST');
    await expect(row).toContainText('Agreement 10.5 Speeding charges');
    await expect(row).toContainText('Told: staff, renter and owner');
    await expect(page.getByTestId('events-off')).toHaveCount(0);
    await row.getByRole('button', { name: /^Charge \$1,000/ }).click();
    const dlg = page.locator('dialog[open]');
    await expect(dlg).toContainText('evidence record');
    await dlg.getByTestId(`charge-${a!.evidence}-submit`).click();
    await expect(row.getByTestId('event-charged')).toContainText('Charged $1,000', { timeout: 60_000 });
    const [li] = await sql`select li.charge_type, li.amount_cents, li.evidence_status, li.supporting_refs ->> 'tracker_evidence_id' as ev from booking_line_items li
                             join tracker_evidence e on e.line_item_id = li.id where e.id = ${a!.evidence}`;
    expect([li!.charge_type, Number(li!.amount_cents), li!.evidence_status, li!.ev]).toEqual(['speeding_220', 100000, 'ok', a!.evidence]);

    // 2. the pound: parked at the lot. The flag, Fleet's To do, the renter's notice; the Admin adds a lot
    const pd = await post(fakeScenario(device, 'pound', { end: now - 60_000, lot, parkedMinutes: 10 }));
    expect(pd.res.status()).toBe(200);
    expect((await pd.res.json()).accepted).toBe(4);
    const [f] = await sql`select f.id, f.status, f.booking_id, (select count(*) from tasks x where x.dedupe_key = 'pound_recovery:' || f.id and x.status = 'open') as todo,
                                 (select count(*) from app_events e where e.dedupe_key = 'renter_tracker_notice:' || f.alert_id) as told from pound_flags f where f.vehicle_id = ${car}`;
    expect([f!.status, f!.booking_id, Number(f!.todo), Number(f!.told)]).toEqual(['open', booking, 1, 1]);
    await page.reload({ waitUntil: 'networkidle' });
    const flag = page.getByTestId('pound-flags').getByRole('row').filter({ hasText: number });
    await expect(flag).toContainText(LONG_LOT);
    await expect(flag).toContainText('613-555-0142');
    await expect(flag.locator('[data-status="open"]')).toBeVisible();
    const lots = page.getByTestId('pound-lots');
    await expect(lots.getByRole('row').filter({ hasText: `${LONG_LOT} ${T}` })).toContainText('Ready');
    await expect(lots.getByRole('row').filter({ hasText: 'Classic Towing' })).toContainText('No pin yet');
    await lots.getByRole('button', { name: 'Add a lot' }).click();
    const add = page.locator('dialog[open]');
    await add.getByLabel('Name', { exact: true }).fill(`Example Pound ${T}`);
    await add.getByLabel('Address', { exact: true }).fill(`${T} Example Street, Toronto, ON`);
    await add.getByLabel('Phone', { exact: true }).fill('416-555-0177');
    await add.getByTestId('lot-add-submit').click();
    await expect(lots.getByRole('row').filter({ hasText: `Example Pound ${T}` })).toContainText('No pin yet', { timeout: 60_000 });
    await expect(page.getByTestId('event-settings')).toContainText('Speeding over 180 km/h');
    await axe(page, 'admin tracking');
    if (!phone) await shots(page, 'admin-tracker-events', size);

    // 3. the staff car map mirrors it: Fleet reads the events (no Charge), sees the lots read only, and records the path
    const sp2 = await ctx(browser, size.width, size.height);
    await signIn(sp2, fleet.email, /^\/staff/);
    await sp2.goto('/staff/fleet/map', { waitUntil: 'networkidle' });
    const srow = sp2.getByTestId('tracker-events').getByRole('row').filter({ hasText: number }).filter({ hasText: 'Speeding over 220 km/h' });
    await expect(srow).toContainText('Charged $1,000');
    await expect(sp2.getByTestId('pound-lots').getByRole('button', { name: 'Add a lot' })).toHaveCount(0);
    await expect(sp2.getByTestId('event-settings')).toHaveCount(0);
    const sflag = sp2.getByTestId('pound-flags').getByRole('row').filter({ hasText: number });
    await sflag.getByRole('button', { name: 'Record the path' }).click();
    const res = sp2.locator('dialog[open]');
    await res.getByLabel('What happened', { exact: true }).selectOption('no_charge');
    await res.getByLabel(/What happened, in a sentence/).fill('Towed by mistake from a private lot; released with nothing owed.');
    await res.getByTestId(`resolve-${f!.id}-submit`).click();
    // the row itself says so (the form's own choices carry the same words, so the row's state is what is waited for)
    await expect(sflag.locator('[data-status="recovered"]')).toContainText('Recovered, nothing to charge', { timeout: 60_000 });
    const [f2] = await sql`select f.status, f.path, (select x.status from tasks x where x.dedupe_key = 'pound_recovery:' || f.id) as todo from pound_flags f where f.id = ${f!.id}`;
    expect([f2!.status, f2!.path, f2!.todo]).toEqual(['recovered', 'no_charge', 'done']);
    await axe(sp2, 'staff car map');
    if (!phone) await shots(sp2, 'staff-tracker-events', size);
    await sp2.context().close();

    // 4. the owner's car page: the alerts, the event and the place only
    const op = await ctx(browser, size.width, size.height);
    await signIn(op, ownerUser.email, /^\/owner/);
    await op.goto(`/owner/vehicles/${car}`, { waitUntil: 'networkidle' });
    const alerts = op.getByTestId('vehicle-tracker-alerts');
    await expect(alerts).toContainText('Speeding over 220 km/h');
    await expect(alerts).toContainText('was recorded at 226 km/h');
    await expect(alerts).toContainText('Your rental is at an impound lot');
    await expect(alerts).not.toContainText(number);
    await expect(alerts.getByRole('link', { name: 'See the place' }).first()).toHaveAttribute('href', /google\.com\/maps\?q=/);
    await noOverflow(op);
    if (!phone) await shots(op, 'owner-tracker-alerts', size);
    await op.context().close();
    await page.context().close();
  } finally {
    await sql`update tracker_settings set events_on = ${before!.events_on}, pound_minutes = ${before!.pound_minutes}`;
    await sql`update pound_lots set is_active = false where name like ${`%${t.toUpperCase()}`}`;
    await sql.end();
    await done();
  }
});

test('Tracker events off: the panel says so and nothing is recorded', async ({ browser, request }, info) => {
  test.setTimeout(300_000);
  test.skip(info.project.name.startsWith('phone'), 'the switch is one for everyone: checked once, on the desktop width');
  const sql = db();
  const done = await turn();
  const admin = await mkUser(sql, 'admin', 'Tara Tracker');
  const [before] = await sql`select events_on from tracker_settings`;
  try {
    await sql`update tracker_settings set events_on = false`;
    const [k] = await sql`select coalesce(app.tracker_ingest_key(), app.tracker_key_new(${admin.id}) ->> 'key') as key`;
    const device = `E2E-OFF-${tag()}`;
    const raw = JSON.stringify({ points: fakeScenario(device, 'speeding_300') });
    const r = await request.post('/api/tracker/ingest', { data: raw, headers: await signedHeaders(raw, String(k!.key)) });
    expect(r.status()).toBe(200);
    expect((await r.json()).events).toBeUndefined();
    // a wrong signature is refused, and a sender that keeps failing is told to wait
    const bad = await request.post('/api/tracker/ingest', { data: raw, headers: { ...(await signedHeaders(raw, 'trk_wrong')) } });
    expect(bad.status()).toBe(401);
    const page = await ctx(browser, 1440, 900);
    await signIn(page, admin.email, /^\/admin/);
    await page.goto('/admin/vehicles/tracking', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('events-off')).toContainText('Tracker events are off');
    await expect(page.getByTestId('event-settings')).toBeVisible();
    await noOverflow(page);
    await page.context().close();
  } finally {
    await sql`update tracker_settings set events_on = ${before!.events_on}`;
    await sql.end();
    await done();
  }
});
