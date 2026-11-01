import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';
import { signedHeaders } from '../../src/integrations/tracker/ingest';
import { simFleet, simPoints } from '../../src/features/tracking/sim';
// Fleet tracking (migration 0400) end to end: the simulator's signed batches reach /api/tracker/ingest (an unsigned one is
// refused), a new tracker shows as "Reporting, not on a car yet", an Admin pairs it with a car from Cars > Fleet tracking,
// the car shows on the map and in the list with its renter, a speeding batch raises an alert that is marked seen, and demo
// mode puts simulated cars on the dashboard and on the Live map's Fleet layer. axe and no overflow at 375 and 1440.
// Fixtures are example.test only; device ids are made up.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
test.use({ launchOptions: { args: ['--no-proxy-server', '--force-prefers-reduced-motion', '--enable-unsafe-swiftshader', '--use-angle=swiftshader', '--ignore-gpu-blocklist'] } });

async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 60_000 });
}
async function ctx(browser: Browser, w: number, h: number) {
  const c = await browser.newContext({ viewport: { width: w, height: h }, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}

test.describe.configure({ mode: 'serial' });

test('Fleet tracking: signed ingest, pairing, the map and list, alerts, demo mode and the Live map layer', async ({ browser, request }, info) => {
  test.setTimeout(240_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  const t = tag();
  const admin = randomUUID(), email = `tk.admin.${Date.now()}.${t}@example.test`;
  const car = randomUUID(), booking = randomUUID(), device = `E2E-${t}-${phone ? 'P' : 'D'}`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${admin}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${admin}, ${email}, 'Tara Tracker')`;
  await sql`insert into user_roles (user_id, role) values (${admin}, 'admin')`;
  try {
    // a real car (a copy of a sample car) on rent to a sample booking's renter, picked up yesterday
    const copy = async (table: 'vehicles' | 'bookings', from: string, patch: Record<string, unknown>) => {
      const cols = (await sql`select column_name from information_schema.columns where table_schema = 'public' and table_name = ${table}
                               and is_generated = 'NEVER' and is_identity = 'NO' order by ordinal_position`).map((c) => `"${String(c.column_name)}"`).join(', ');
      await sql.unsafe(`insert into ${table} (${cols}) select ${cols} from jsonb_populate_record(null::${table}, (select to_jsonb(x) from ${table} x where x.id = $1) || $2::jsonb)`,
        [from, JSON.stringify(patch)]);
    };
    const [sample] = await sql`select v.id from vehicles v where v.is_sample and exists (select 1 from bookings b where b.vehicle_id = v.id) order by v.fleet_number limit 1`;
    await copy('vehicles', String(sample!.id), { id: car, is_sample: false, vin: `E2ETRK${t}`.toUpperCase().padEnd(17, '0'), plate: `TK${t}`.toUpperCase(), fleet_number: `TK-${t}`,
      car_code: null, tracker_installed_on: null, tracker_install_pending: true });
    const [src] = await sql`select b.id, extract(epoch from b.return_at - b.pickup_at)::int as secs, r.legal_name from bookings b join renters r on r.id = b.renter_id
                             where b.vehicle_id = ${sample!.id} order by b.pickup_at limit 1`;
    const pickup = new Date(Date.now() - 86_400_000), back = new Date(pickup.getTime() + Number(src!.secs) * 1000);
    await copy('bookings', String(src!.id), { id: booking, vehicle_id: car, booking_number: `TK-${t}`, agreement_number: null, request_key: null, calendar_token: randomUUID(),
      renews_booking_id: null, status: 'on_rent', is_placeholder: false, pickup_at: pickup.toISOString(), return_at: back.toISOString(), original_return_at: back.toISOString(),
      handed_over_at: pickup.toISOString(), checked_in_at: null });
    const renter = String(src!.legal_name);
    // the ingest key (one for every run: made once, never rotated here)
    const [k] = await sql`select coalesce(app.tracker_ingest_key(), app.tracker_key_new(${admin}) ->> 'key') as key`;
    const key = String(k!.key);
    const [sim] = simFleet([device]);
    const now = Date.now();
    const batch = (from: number, to: number, speed?: number) => JSON.stringify({ points: simPoints([sim!], from, to, 10).map((p) => ({ ...p, device, ...(speed ? { speed, ignition: true } : {}) })) });

    // the ingest: unsigned refused; signed accepted, the new tracker created
    const unsigned = await request.post('/api/tracker/ingest', { data: batch(now - 120_000, now - 60_000), headers: { 'content-type': 'application/json' } });
    expect(unsigned.status()).toBe(401);
    const first = batch(now - 120_000, now - 60_000);
    const r1 = await request.post('/api/tracker/ingest', { data: first, headers: await signedHeaders(first, key) });
    expect(r1.status()).toBe(200);
    expect((await r1.json()).new_devices).toBe(1);

    const page = await ctx(browser, phone ? 375 : 1440, phone ? 812 : 900);
    await signIn(page, email);
    await page.goto('/admin/vehicles/tracking', { waitUntil: 'networkidle' });
    await expect(page.getByRole('heading', { level: 1, name: 'Fleet tracking' })).toBeVisible();
    await expect(page.getByTestId('ft-kpis')).toContainText('On rent');
    // pair the new tracker with the car (install date today: the Tracker Fee starts)
    const row = page.getByTestId('unpaired').getByRole('row').filter({ hasText: device });
    await expect(row).toBeVisible();
    await row.getByRole('button', { name: 'Pair' }).click();
    const dlg = page.getByRole('dialog');
    await dlg.getByLabel('Car', { exact: true }).selectOption(car);
    await dlg.getByRole('button', { name: 'Pair' }).click();
    await expect(page.getByTestId('paired').getByRole('row').filter({ hasText: device })).toBeVisible({ timeout: 20_000 });
    const [v] = await sql`select tracker_installed_on is not null as fee from vehicles where id = ${car}`;
    expect(v!.fee).toBe(true);

    // the car reports, then speeds: on the map and in the list with its renter; one speeding alert
    const second = batch(now - 50_000, now - 20_000), fast = batch(now - 15_000, now - 5_000, 168);
    expect((await request.post('/api/tracker/ingest', { data: second, headers: await signedHeaders(second, key) })).status()).toBe(200);
    expect((await request.post('/api/tracker/ingest', { data: fast, headers: await signedHeaders(fast, key) })).status()).toBe(200);
    await page.reload({ waitUntil: 'networkidle' });
    const map = page.getByTestId('ft-map');
    await expect(map).toHaveAttribute('data-mode', 'map', { timeout: 60_000 });
    await expect.poll(async () => Number(await map.getAttribute('data-cars'))).toBeGreaterThanOrEqual(1);
    const carRow = page.getByTestId('ft-car').filter({ hasText: renter }).filter({ hasText: /km\/h/ }).first();
    await expect(carRow).toBeVisible();
    await carRow.click();
    await expect(page.getByTestId('ft-card')).toContainText(`TK-${t}`);
    const alert = page.getByTestId('ft-alert').filter({ hasText: 'Speeding' }).filter({ hasText: `TK-${t}` });
    await expect(alert).toHaveCount(1);
    await noOverflow(page);
    const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).exclude('.lm-map').analyze();
    expect(r.violations.map((x) => `${x.id}: ${x.nodes.map((n) => n.target.join(' ')).join(', ')}`)).toEqual([]);
    await alert.getByRole('button', { name: 'Seen' }).click();
    await expect(alert).toHaveClass(/is-seen/, { timeout: 20_000 });

    // demo mode (desktop only: it is one switch for everyone): simulated cars here and on the Live map
    if (!phone) {
      await sql`update tracker_settings set demo = true`;
      await page.reload({ waitUntil: 'networkidle' });
      await expect(page.getByTestId('ft-demo')).toBeVisible();
      await expect(page.getByTestId('ft-alert').filter({ hasText: 'demo' }).first()).toBeVisible();
      await page.goto('/admin/live-map', { waitUntil: 'networkidle' });
      await expect(page.getByText(/Fleet \(\d+/)).toBeVisible({ timeout: 30_000 });
      await sql`update tracker_settings set demo = false`;
    }
    await page.context().close();
  } finally {
    await sql`update tracker_settings set demo = false`.catch(() => undefined);
    await sql`delete from tracker_alerts where vehicle_id = ${car}`.catch(() => undefined);
    await sql`delete from tracker_devices where serial_number = ${device}`.catch(() => undefined);
    await sql`delete from bookings where id = ${booking}`.catch(() => undefined);
    await sql`delete from vehicles where id = ${car}`.catch(() => undefined);
    await sql`delete from user_roles where user_id = ${admin}`.catch(() => undefined);
    await sql.end();
  }
});
