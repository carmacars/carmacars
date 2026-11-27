import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// R50 hotfix 2, Sales (5130 to 5137), end to end at the project's width:
//   1. a request for a sample car is a row of Requests and offers, marked as a sample car, with real cars to offer;
//   3. the renter adds a note to their open request, and Admin sees it on the request;
//   6. a lead generator adds an owner on Owners I found, sees where it is, and the credit once the owner signs; the
//      Admin approves it on Lead generators.
type Sql = ReturnType<typeof db>;
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;

async function person(sql: Sql, role: 'admin' | 'va' | 'renter', name: string, fn?: 'sales') {
  const id = randomUUID(); const email = `r50s.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') {
    await sql`select public.register_account(${id}, ${email}, ${name}, null)`;
    await sql`insert into renters (user_id, legal_name, email, mobile, date_of_birth) values (${id}, ${name}, ${email}, '+14165550143', '1988-04-12')
              on conflict (user_id) do update set date_of_birth = excluded.date_of_birth`;
  } else {
    await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
    await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
    if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, onboarding_exempt) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${fn ?? 'sales'}, true)`;
  }
  return { id, email };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 30_000 });
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function car(sql: Sql, adminId: string, model: string) {
  const vin = `3RSMX${randomBytes(6).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
  const [r] = await sql`select app.vehicle_add(${adminId}::uuid, ${sql.json({ supply_type: 'company', vin, plate: `S${randomBytes(3).toString('hex').toUpperCase()}`, year: 2024, make: 'Kia', model,
    rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as v`;
  return String((r!.v as { vehicle_id: string }).vehicle_id);
}

test('item 1: a sample-car request is in Requests and offers with real cars to offer', async ({ browser }) => {
  test.setTimeout(120_000);
  const sql = db();
  const admin = await person(sql, 'admin', `Ria Requests ${tag()}`);
  const sample = await car(sql, admin.id, `Dost ${tag()}`);
  await sql`update vehicles set is_sample = true, sample_bookable = false where id = ${sample}`;
  const day = new Date(Date.now() + (200 + Math.floor(Math.random() * 100)) * 86_400_000); day.setUTCHours(15, 0, 0, 0);
  const [e] = await sql`select app.sample_car_enquiry(${sql.json({ vehicle_id: sample, note: 'Is the DOST free?', renter: { full_name: `Sam Sample ${tag()}`, email: `r50s.sample.${tag()}@example.test`, mobile: '416-555-0144' },
    pickup_at: day.toISOString(), return_at: new Date(day.getTime() + 3 * 86_400_000).toISOString() })}) as r`;
  const ref = (e!.r as { booking_number: string }).booking_number;
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto('/admin/requests', { waitUntil: 'networkidle' });
  const row = page.getByTestId(`rq-${ref}`);
  await expect(row).toBeVisible();
  await expect(page.getByTestId(`rq-sample-${ref}`)).toHaveText('Sample car: not a real car');
  await expect(row).toContainText('Is the DOST free?');
  const go = page.getByTestId(`rq-go-${ref}`);
  await expect(go).toHaveAttribute('href', /\/admin\/offers\/new\?(car=[0-9a-f-]{36}&)?from=/);
  await expect(page.getByTestId(`rq-lead-${ref}`)).toHaveAttribute('href', /\/admin\/sales-leads\/[0-9a-f-]{36}$/);
  await noOverflow(page);
  await page.context().close();
  await sql.end();
});

test('item 3: the renter adds a note to their request and Admin sees it', async ({ browser }) => {
  test.setTimeout(120_000);
  const sql = db();
  const admin = await person(sql, 'admin', `Nia Notes ${tag()}`);
  const renter = await person(sql, 'renter', `Rae Requester ${tag()}`);
  const vehicle = await car(sql, admin.id, `K5 ${tag()}`);
  const [rn] = await sql`select id from renters where user_id = ${renter.id}`;
  const number = `RSN-${tag().toUpperCase()}`;
  const off = 250 + Math.floor(Math.random() * 100);
  await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, pickup_at, return_at, original_return_at, billable_days,
      daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total,
      overage_cents_per_km, deposit_cents, blocks_calendar, total_due_at_booking_cents, requested_at)
    values (${number}, 'standard', 'requested', ${vehicle}, ${rn!.id as string}, now() + make_interval(days => ${off}), now() + make_interval(days => ${off + 3}), now() + make_interval(days => ${off + 3}), 3,
      10000, 10000, 70000, 300000, 'daily', 30000, 200, 600, 25, 30000, true, 30000, now())`;
  const rp = await ctx(browser);
  await signIn(rp, renter.email, '/account');
  await rp.goto(`/account/bookings/${encodeURIComponent(number)}`, { waitUntil: 'networkidle' });
  const card = rp.getByTestId('renter-request-notes');
  await expect(card).toBeVisible();
  await expect(rp.getByTestId('request-note-add')).toBeDisabled();
  await rp.getByTestId('request-note-input').fill('Flight AC 857 lands at 9 pm');
  await rp.getByTestId('request-note-add').click();
  await expect(card).toContainText('Flight AC 857 lands at 9 pm');
  await expect(card.getByRole('status')).toContainText('Added');
  await noOverflow(rp);
  await rp.context().close();

  const ap = await ctx(browser);
  await signIn(ap, admin.email, '/admin');
  await ap.goto('/admin/requests', { waitUntil: 'networkidle' });
  await expect(ap.getByTestId(`rq-notes-${number}`)).toContainText('Flight AC 857 lands at 9 pm');
  await ap.context().close();
  await sql`update bookings set status = 'declined' where booking_number = ${number} and status = 'requested'`;
  await sql.end();
});

test('item 6: a lead generator adds an owner, follows it, and the credit is approved', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const admin = await person(sql, 'admin', `Ada Leadgen ${tag()}`);
  const eric = await person(sql, 'va', `Eric Finder ${tag()}`, 'sales');
  await sql`select app.lead_gen_set(${admin.id}::uuid, ${sql.json({ staff: eric.id, on: true })})`;
  const owner = `Olive Owner ${tag()}`;
  const phone = `416-555-${String(1000 + Math.floor(Math.random() * 8999))}`;
  const page = await ctx(browser);
  await signIn(page, eric.email, '/staff');
  await page.goto('/staff/my-owner-leads', { waitUntil: 'networkidle' });
  await expect(page.getByRole('heading', { name: 'My owner leads' })).toBeVisible();
  await page.getByTestId('owner-lead-add').click();
  const dlg = page.getByRole('dialog');
  await dlg.getByLabel('Owner\'s name').fill(owner);
  await dlg.getByLabel('Phone').fill(phone);
  await dlg.getByLabel('Car (year, make, model)').fill('2021 Honda Civic');
  await dlg.getByRole('button', { name: 'Add the owner' }).click();
  const list = page.getByTestId('my-owner-leads');
  await expect(list).toContainText(owner);
  await expect(list).toContainText('New: waiting for a closer');
  await noOverflow(page);

  await sql`update leads set pipeline_stage = 'signed' where generated_by = ${eric.id} and name = ${owner}`;
  await page.reload({ waitUntil: 'networkidle' });
  await expect(list).toContainText('Signed');
  await expect(list).toContainText('Waiting for an Admin');
  await page.context().close();

  const ap = await ctx(browser);
  await signIn(ap, admin.email, '/admin');
  await ap.goto('/admin/lead-generators', { waitUntil: 'networkidle' });
  const credits = ap.getByTestId('lead-gen-credits');
  await expect(credits).toContainText(owner);
  const [c] = await sql`select c.id from lead_gen_credits c join leads l on l.id = c.lead_id where l.name = ${owner}`;
  await ap.getByTestId(`lgc-approve-${String(c!.id).slice(0, 8)}`).click();
  await expect(credits).toContainText('Approved, not paid');
  await noOverflow(ap);
  await ap.context().close();
  await sql.end();
});
