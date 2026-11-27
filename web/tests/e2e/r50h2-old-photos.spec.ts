import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, FIXTURE_JPEG } from './helpers';

// R50 hotfix 2 (5185, 5186), end to end on the phone: a field staff member who never handled two past bookings finds the
// first by its plate under Add old photos, chooses the check-out and adds three photos at once (each with its capture time);
// then picks a pile of photos taken at the second booking's pickup, which the system groups and matches by time, and
// confirms the group in one tap. The photos land on each report "added later by" them, with the capture time, once each,
// and nothing goes to the renter. Fleet sees "added later by" on the photo report. No sideways scroll, no serious axe finding.
type Sql = ReturnType<typeof db>;
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

/** FIXTURE_JPEG with an EXIF block whose DateTimeOriginal is the Toronto wall clock of `at`. */
function jpegTaken(at: Date): Buffer {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' })
    .formatToParts(at).map((x) => [x.type, x.value]));
  const date = `${p.year}:${p.month}:${p.day} ${p.hour}:${p.minute}:${p.second}`;
  const le16 = (v: number) => [v & 255, v >> 8], le32 = (v: number) => [v & 255, (v >> 8) & 255, (v >> 16) & 255, v >>> 24];
  const tiff = [0x49, 0x49, 0x2a, 0, ...le32(8), ...le16(1), ...le16(0x8769), ...le16(4), ...le32(1), ...le32(26), ...le32(0),
    ...le16(1), ...le16(0x9003), ...le16(2), ...le32(20), ...le32(44), ...le32(0), ...[...date].map((c) => c.charCodeAt(0)), 0];
  const app1 = [0x45, 0x78, 0x69, 0x66, 0, 0, ...tiff];
  const len = app1.length + 2;
  return Buffer.concat([FIXTURE_JPEG.subarray(0, 2), Buffer.from([0xff, 0xe1, len >> 8, len & 255, ...app1]), FIXTURE_JPEG.subarray(2)]);
}
async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect(await page.locator('body').innerText(), `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 60_000 });
}
async function phone(browser: Browser) {
  const c = await browser.newContext({ viewport: { width: 375, height: 812 }, hasTouch: true, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function photos(sql: Sql, n: string, kind: string) {
  return sql`select p.added_later_at is not null as later, p.uploaded_by, p.device_taken_at, p.shot from condition_report_photos p join condition_reports c on c.id = p.condition_report_id
              join bookings b on b.id = c.booking_id where b.booking_number = ${n} and c.kind = ${kind} order by p.seq`;
}

test.describe.configure({ mode: 'serial' });
test.setTimeout(240_000);

test('add old photos: one booking by plate, then a pile matched by time, on the phone', async ({ browser }) => {
  test.skip(test.info().project.name !== 'phone-375', 'one run is enough: the phone flow at 375 wide');
  const sql = db();
  const t = tag(), T = t.toUpperCase();
  const field = randomUUID(), fieldEmail = `op.field.${t}@example.test`;
  const fleet = randomUUID(), fleetEmail = `op.fleet.${t}@example.test`;
  const owner = randomUUID(), car1 = randomUUID(), car2 = randomUUID();
  const n1 = `OP1-${T}`, n2 = `OP2-${T}`, plate1 = `OP${T}`.slice(0, 8);
  await sql`insert into users (id, email, full_name) values (${field}, ${fieldEmail}, 'Fern Field'), (${fleet}, ${fleetEmail}, 'Flo Fleet')`;
  await sql`insert into user_roles (user_id, role) values (${field}, 'field'), (${fleet}, 'va')`;
  await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function) values (${field}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver')`;
  await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${fleet}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'fleet', 0)`;
  for (const [id, e] of [[field, fieldEmail], [fleet, fleetEmail]] as const) await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${e}, ${hash(PW)})`;
  await sql`insert into owners (id, owner_type, legal_name, status, email, phone) values (${owner}, 'individual', 'Ola Owner', 'active', ${`op.owner.${t}@example.test`}, '416-555-0100')`;
  for (const [id, plate] of [[car1, plate1], [car2, `OQ${T}`.slice(0, 8)]] as const) {
    await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, enrollment_date)
              values (${id}, ${owner}, ${`F-${plate}`}, 2024, 'Toyota', 'Corolla', ${('OP' + randomBytes(8).toString('hex').toUpperCase()).slice(0, 17)}, ${plate}, 'standard', 'available', 'managed', 'transfer', true, current_date - 200)`;
  }
  const [r] = await sql`insert into renters (legal_name, date_of_birth, mobile, email, identity_status) values ('Rio Renter', date '1990-05-05', '647-555-0199', ${`op.renter.${t}@example.test`}, 'verified') returning id`;
  // n1: closed, out 12 days ago, back 9 days ago; n2: on the road, out 2 days ago (neither one handled by the field staff member)
  for (const [n, car, status, out, back] of [[n1, car1, 'closed', 12, 9], [n2, car2, 'on_rent', 2, -5]] as const) {
    await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
        daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total,
        overage_cents_per_km, deposit_cents, blocks_calendar, total_due_at_booking_cents, handed_over_at, checked_in_at, created_by)
      values (${n}, 'standard', ${status}, ${car}, ${r!.id}, now() - make_interval(days => ${out + 3}), now() - make_interval(days => ${out}), now() - make_interval(days => ${back}),
        now() - make_interval(days => ${back}), public.calc_billable_days(now() - make_interval(days => ${out}), now() - make_interval(days => ${back})), 6900, 7900, 39000, 140000, 'daily', 20700, 200, 600, 25, 0, true, 20700, now() - make_interval(days => ${out}),
        ${status === 'closed' ? sql`now() - make_interval(days => ${back})` : null}, ${fleet})`;
  }
  const notices = async () => Number((await sql`select count(*)::int as n from notification_outbox`)[0]!.n);
  const before = await notices();
  const [times] = await sql`select (select checked_in_at from bookings where booking_number = ${n1}) as back1, (select handed_over_at from bookings where booking_number = ${n2}) as out2` as unknown as Array<{ back1: Date; out2: Date }>;
  const { back1, out2 } = times!;

  // 1. one booking: found by its plate (lower case, with a space), the check-out, three photos at once
  const p = await phone(browser);
  await signIn(p, fieldEmail, '/staff');
  await p.goto('/staff/field', { waitUntil: 'networkidle' });
  await p.getByTestId('field-old-photos-link').click();
  await p.waitForURL(/\/staff\/field\/old-photos/);
  await expect(p.getByTestId(`op-row-${n2}`)).toBeVisible();
  await check(p, 'the list');
  await p.getByTestId('op-q').fill(`${plate1.slice(0, 3).toLowerCase()} ${plate1.slice(3).toLowerCase()}`);
  await p.getByTestId('op-q').press('Enter');
  await expect(p.getByTestId(`op-row-${n2}`)).toHaveCount(0);
  await p.getByTestId(`op-row-${n1}`).click();
  await expect(p.getByTestId('op-booking')).toContainText(n1);
  await check(p, 'one booking');
  await p.getByTestId('op-kind-return').click();
  const taken = [5, 6, 7].map((m) => new Date(back1.getTime() + m * 60_000));
  await p.getByTestId('op-pick-input').setInputFiles(taken.map((d, i) => ({ name: `IMG_10${i}.jpg`, mimeType: 'image/jpeg', buffer: jpegTaken(d) })));
  await expect(p.getByTestId('op-uploads-summary')).toContainText('3 of 3 added', { timeout: 60_000 });
  await check(p, 'the uploads');
  const one = await photos(sql, n1, 'return');
  expect(one.length).toBe(3);
  expect(one.every((x) => x.later && x.uploaded_by === field && x.shot === 'other')).toBe(true);
  expect(one.map((x) => Math.round((x.device_taken_at as Date).getTime() / 1000)).sort()).toEqual(taken.map((d) => Math.round(d.getTime() / 1000)).sort());
  // the same photos picked again after a reload: answered "Already added", nothing stored twice
  await p.reload({ waitUntil: 'networkidle' });
  await p.getByTestId('op-kind-return').click();
  await p.getByTestId('op-pick-input').setInputFiles(taken.map((d, i) => ({ name: `IMG_10${i}.jpg`, mimeType: 'image/jpeg', buffer: jpegTaken(d) })));
  await expect(p.getByTestId('op-uploads-summary')).toContainText('3 of 3 added', { timeout: 60_000 });
  await expect(p.getByTestId('op-file').filter({ hasText: 'Already added' })).toHaveCount(3);
  expect((await photos(sql, n1, 'return')).length).toBe(3);

  // 2. a pile: two photos taken 20 minutes after the second booking's pickup, one long before anything (no match)
  await p.goto('/staff/field/old-photos', { waitUntil: 'networkidle' });
  await p.getByTestId('op-tab-bulk').click();
  await p.waitForURL(/mode=bulk/);
  const pile = [20, 24].map((m) => new Date(out2.getTime() + m * 60_000));
  await p.getByTestId('op-bulk-input').setInputFiles([
    ...pile.map((d, i) => ({ name: `IMG_20${i}.jpg`, mimeType: 'image/jpeg', buffer: jpegTaken(d) })),
    { name: 'IMG_old.jpg', mimeType: 'image/jpeg', buffer: jpegTaken(new Date(Date.now() - 300 * 86_400_000)) }]);
  const groups = p.getByTestId('op-group');
  await expect(groups).toHaveCount(2, { timeout: 60_000 });
  await expect(groups.nth(0).getByTestId('op-no-match')).toBeVisible();
  await expect(groups.nth(1).getByTestId('op-suggest')).toContainText(`Check-in of ${n2}`);
  await check(p, 'the pile');
  await groups.nth(1).getByTestId('op-confirm').click();
  await expect(groups.nth(1).getByTestId('op-group-sent')).toBeVisible();
  await expect(p.getByTestId('op-uploads-summary')).toContainText('2 of 2 added', { timeout: 60_000 });
  const two = await photos(sql, n2, 'pickup');
  expect(two.length).toBe(2);
  expect(two.every((x) => x.later && x.uploaded_by === field)).toBe(true);
  const [b2] = await sql`select status from bookings where booking_number = ${n2}`;
  expect(b2!.status).toBe('on_rent');
  expect(await notices()).toBe(before);

  // 3. Fleet: the photo report says who added them later
  const f = await phone(browser);
  await signIn(f, fleetEmail, '/staff');
  await f.goto(`/staff/bookings/${n1}/report`, { waitUntil: 'networkidle' });
  await expect(f.getByTestId('photo-added-later').first()).toContainText('added later by Fern Field');
  await f.goto(`/staff/old-photos?q=${n1}`, { waitUntil: 'networkidle' });
  await expect(f.getByTestId(`op-row-${n1}`).locator('.op-row__count')).toHaveText('3 photos');
  await check(f, 'Fleet: Add old photos');
  await sql.end();
});
