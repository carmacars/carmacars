import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, carByHand, db, noOverflow, strongSign } from './helpers';

// Migration 0046 end to end: Admin > Partners (add a partner), Admin > Vehicles > Add a car (a partner's car and a
// CarmaCars-owned car), Add a rental by hand (Admin, and customer service in the VA portal within its limits), the renter
// signing a rental added by hand in their portal (no payment step), retire and restore, delete a car added by mistake,
// the sample cars page, and the partner portal signing the partner agreement. Every page is checked with axe, for
// overflow at 375 and 1440 pixels, and for the copy rules.
const SHOTS = 'test-results/supply-rentals';
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;
mkdirSync(SHOTS, { recursive: true });

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
// a VIN that passes the check digit is not needed (only length and letters); letters I, O and Q are not used in VINs
const vin = () => `2T1BU4EE${randomBytes(5).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
const plate = () => `E2E${randomBytes(2).toString('hex').toUpperCase()}`;

async function mkUser(sql: Sql, kind: 'admin' | 'va' | 'renter' | 'partner', name: string) {
  const id = randomUUID(); const email = `${kind}.sr.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (kind === 'renter') {
    await sql`select public.register_account(${id}, ${email}, ${name}, null)`;
    // the renter record a first booking request would make
    await sql`insert into renters (user_id, legal_name, email, mobile, date_of_birth) values (${id}, ${name}, ${email}, '+14165550142', '1988-04-12')
              on conflict (user_id) do update set date_of_birth = excluded.date_of_birth, mobile = excluded.mobile`;
    return { id, email, name };
  }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  if (kind === 'va') { await sql`insert into user_roles (user_id, role) values (${id}, 'va')`; await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'cs')`; }
  if (kind === 'partner') await sql`insert into user_roles (user_id, role) values (${id}, 'owner')`;
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
  const p = await c.newPage();
  p.on('dialog', (d) => void d.accept());
  return p;
}
async function addCar(page: Page, supply: 'company' | 'partner', o: { partnerId?: string; vin: string; plate: string; daily?: string }) {
  await page.goto('/admin/vehicles/new', { waitUntil: 'networkidle' });
  await page.getByTestId(`add-car-supply-${supply}`).check();
  if (o.partnerId) await page.getByTestId('add-car-partner').selectOption(o.partnerId);
  await page.getByTestId('add-car-vin').fill(o.vin);
  await page.getByTestId('add-car-plate').fill(o.plate);
  await carByHand(page, 'add-car', { year: '2022', make: 'Toyota', model: 'Corolla' });
  if (o.daily) { await page.getByTestId('add-car-daily').fill(o.daily); await page.getByTestId('add-car-deposit').fill('300'); }
  await page.getByTestId('add-car-submit').click();
  await page.waitForURL(/\/admin\/vehicles\/[0-9a-f-]{36}\?added=1/, { timeout: 30_000 });
  return page.url().match(/vehicles\/([0-9a-f-]{36})/)![1]!;
}

test.describe.configure({ mode: 'serial' });

test('admin: partners, add a car (partner and company), add a rental, retire, delete, sample cars', async ({ browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', `Ada Admin ${tag()}`);
  const renter = await mkUser(sql, 'renter', `Robin Walkin ${tag()}`);
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');

  // a partner rental company
  await page.goto('/admin/partners', { waitUntil: 'networkidle' });
  await check(page, 'partners');
  const biz = `Lakeshore Rentals ${tag()}`;
  await page.getByTestId('partner-add').click();
  const form = page.getByTestId('partner-add-form');
  await form.getByLabel('Business name', { exact: true }).fill(biz);
  await form.getByLabel('Contact person (signs the agreement)', { exact: true }).fill('Pat Partner');
  await form.getByLabel('Email', { exact: true }).fill(`pat.${tag()}@example.test`);
  await form.getByLabel('Their insurance company', { exact: true }).fill('Example Mutual');
  await form.getByLabel('Insurance expiry', { exact: true }).fill('2027-08-31');
  await page.getByTestId('partner-add-submit').click();
  await page.waitForURL(/\/admin\/partners\/[0-9a-f-]{36}/, { timeout: 20_000 });
  const partnerId = page.url().match(/partners\/([0-9a-f-]{36})/)![1]!;
  await expect(page.getByTestId('partner-agreement-status')).toHaveText('Not signed yet');
  await check(page, 'partner page');
  const pdf = await page.request.get(`/admin/partners/${partnerId}/agreement`);
  expect(pdf.status()).toBe(200);
  expect((await pdf.body()).subarray(0, 4).toString()).toBe('%PDF');

  // Add a car: the three choices; a partner's car, then a CarmaCars-owned car with rates
  await page.goto('/admin/vehicles/new', { waitUntil: 'networkidle' });
  await check(page, 'add a car');
  const pCar = await addCar(page, 'partner', { partnerId, vin: vin(), plate: plate() });
  await expect(page.getByTestId('vehicle-supply-label')).toHaveText('Partner rental company');
  await expect(page.getByTestId('vehicle-supply')).toContainText(biz);
  await check(page, 'partner car');
  const cPlate = plate();
  const cCar = await addCar(page, 'company', { vin: vin(), plate: cPlate, daily: '79' });
  await expect(page.getByTestId('vehicle-supply-label')).toContainText('CarmaCars');
  const [v] = await sql`select supply_type, partner_id from vehicles where id = ${pCar}`;
  expect(`${v!.supply_type}/${v!.partner_id}`).toBe(`partner/${partnerId}`);
  await page.goto('/admin/vehicles?supply=partner', { waitUntil: 'networkidle' });
  await expect(page.locator('body')).toContainText('Corolla');
  await check(page, 'vehicles filtered by supply');

  // Add a rental by hand on the company car: the renter on file, paid by e-Transfer, no email
  await page.goto('/admin/bookings/new', { waitUntil: 'networkidle' });
  await check(page, 'add a rental');
  await page.getByTestId('mr-vehicle_id').selectOption(cCar);
  await page.getByTestId('mr-renter-q').fill(renter.name);
  await page.getByTestId('mr-renter-search').click();
  await page.getByTestId('mr-renter-results').getByRole('button', { name: renter.name }).click();
  await expect(page.getByTestId('mr-renter-chosen')).toContainText(renter.name);
  await page.getByTestId('mr-source').selectOption('walk_in');
  await page.getByTestId('mr-check').click();
  await expect(page.getByTestId('mr-free')).toBeVisible({ timeout: 20_000 });
  await expect(page.getByTestId('mr-price')).toContainText('Total from the rate sheet');
  await page.getByTestId('mr-paid-by').selectOption('e_transfer');
  await page.getByTestId('mr-reference').fill('ET-1234');
  await page.getByTestId('mr-do-not-email').check();
  await check(page, 'add a rental, priced');
  await page.getByTestId('mr-submit').click();
  await expect(page.getByTestId('mr-done')).toContainText('Confirmed and on the calendar.', { timeout: 30_000 });
  const number = (await page.getByTestId('mr-done').locator('h2').innerText()).match(/Rental (\S+) added/)![1]!;
  const [bk] = await sql`select status, source, added_by_staff, payment_mode, do_not_email, blocks_calendar from bookings where booking_number = ${number}`;
  expect(`${bk!.status}/${bk!.source}/${bk!.added_by_staff}/${bk!.payment_mode}/${bk!.do_not_email}/${bk!.blocks_calendar}`).toBe('confirmed/walk_in/true/other_way/true/true');
  await page.getByTestId('mr-open').click();
  await page.waitForURL(new RegExp(`/admin/bookings/${number}`));
  await expect(page.locator('body')).toContainText('Added by hand');
  // confirmed, but awaiting the renter's signature: not ready for handover (0051)
  await expect(page.locator('h1')).toContainText('Awaiting signature');
  await check(page, 'booking added by hand');

  // the same dates again: a clash, which an Admin may add over with a reason
  await page.goto('/admin/bookings/new', { waitUntil: 'networkidle' });
  await page.getByTestId('mr-vehicle_id').selectOption(cCar);
  await page.getByTestId('mr-new-renter').check();
  await page.getByTestId('mr-check').click();
  await expect(page.getByTestId('mr-clash')).toContainText(number, { timeout: 20_000 });

  // the renter signs it in their portal: no payment step
  const rp = await ctx(browser);
  await signIn(rp, renter.email, '/account');
  await rp.goto(`/account/bookings/${number}`, { waitUntil: 'networkidle' });
  await expect(rp.getByTestId('status-badge').first()).toHaveText('Awaiting signature');
  await rp.goto(`/account/bookings/${number}/sign`, { waitUntil: 'networkidle' });
  await expect(rp.getByRole('heading', { level: 1 })).toHaveText('Sign your rental agreement');
  if (await rp.locator('#pt-d-address_line1').isVisible()) {
    await rp.locator('#pt-d-address_line1').fill('100 Queen Street West');
    await rp.locator('#pt-d-city').fill('Toronto');
    await rp.locator('#pt-d-postal_code').fill('M5H 2N2');
    await rp.locator('#pt-d-licence_number').fill('W1234-56789-01234');
    await rp.locator('#pt-d-licence_expiry').fill('2031-06-30');
    await rp.getByRole('button', { name: 'Save details' }).click();
    await expect(rp.locator('.agreement')).toContainText('100 Queen Street West', { timeout: 15_000 });
  }
  await check(rp, 'renter signs a rental added by hand');
  await rp.getByTestId('consents-all').check();
  await strongSign(rp);
  await rp.getByRole('button', { name: 'Sign the agreement' }).click();
  await rp.waitForURL(new RegExp(`/account/bookings/${number}(\\?|$)`), { timeout: 30_000 });
  const [sig] = await sql`select string_agg(r.signer_role || ':' || r.method, ',' order by r.signer_role) recs
    from signature_records r join bookings b on b.signature_request_id = r.signature_request_id where b.booking_number = ${number}`;
  expect(sig!.recs).toBe('carmacars:automatic,renter:drawn');
  await expect(rp.getByTestId('status-badge').first()).toHaveText('Confirmed');
  await rp.context().close();
  await page.goto(`/admin/bookings/${number}`, { waitUntil: 'networkidle' });
  await expect(page.locator('h1')).not.toContainText('Awaiting signature');

  // retire: refused while a confirmed booking is ahead; a car with none retires and is restored
  await page.goto(`/admin/vehicles/${cCar}`, { waitUntil: 'networkidle' });
  await page.getByTestId('vehicle-retire').click();
  const rf = page.getByTestId('vehicle-retire-form');
  if (await rf.isVisible()) { await rf.locator('input, textarea').first().fill('Sold'); await page.getByTestId('vehicle-retire-submit').click(); }
  await expect(page.locator('body')).toContainText(/future|confirmed/i, { timeout: 15_000 });
  await page.goto(`/admin/vehicles/${pCar}`, { waitUntil: 'networkidle' });
  await page.getByTestId('vehicle-retire').click();
  const rf2 = page.getByTestId('vehicle-retire-form');
  if (await rf2.isVisible()) { await rf2.locator('input, textarea').first().fill('Back with the partner'); await page.getByTestId('vehicle-retire-submit').click(); }
  await expect(page.getByTestId('vehicle-retired')).toBeVisible({ timeout: 15_000 });
  await check(page, 'retired car');
  await page.getByTestId('vehicle-restore').click();
  await page.getByTestId('vehicle-restore-submit').click();
  await expect(page.getByTestId('vehicle-retired')).toHaveCount(0, { timeout: 15_000 });

  // delete a car added by mistake: the plate must be typed
  const mPlate = plate();
  const mCar = await addCar(page, 'company', { vin: vin(), plate: mPlate });
  await page.getByTestId('vehicle-delete').click();
  await page.getByTestId('vehicle-delete-confirm').fill('WRONG');
  await page.getByTestId('vehicle-delete-submit').click();
  await expect(page.locator('dialog[open] [role="alert"]')).toBeVisible({ timeout: 15_000 });
  await page.getByTestId('vehicle-delete-confirm').fill(mPlate);
  await check(page, 'delete a car');
  await page.getByTestId('vehicle-delete-submit').click();
  await page.waitForURL(/\/admin\/vehicles(\?|$)/, { timeout: 30_000 });
  expect((await sql`select count(*)::int n from vehicles where id = ${mCar}`)[0]!.n).toBe(0);
  // the company car has a booking: delete is not offered, with why
  await page.goto(`/admin/vehicles/${cCar}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('delete-blocked')).toBeVisible();

  // the sample cars page (nothing deleted here: other tests use the sample cars)
  await page.goto('/admin/vehicles/samples', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('delete-samples')).toBeVisible();
  await expect(page.getByTestId('delete-samples-submit')).toBeDisabled();
  await check(page, 'sample cars');
  await page.screenshot({ path: `${SHOTS}/${test.info().project.name}-samples.png`, fullPage: true });
  await page.context().close();
  await sql.end();
});

test('VA customer service: add a rental within the limits', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const va = await mkUser(sql, 'va', `Val Assistant ${tag()}`);
  // a company car with rates and no booking: the assistant's list shows only bookable cars with rates
  const admin = await mkUser(sql, 'admin', `Ada Admin ${tag()}`);
  const [car] = await sql`select app.vehicle_add(${admin.id}, ${sql.json({ supply_type: 'company', vin: vin(), plate: plate(), year: 2023, make: 'Honda', model: 'Civic',
    rates: { daily: 6900, weekend: 7900, weekly: 42000, monthly: 150000, deposit: 30000 } })}) as r`;
  const carId = (car!.r as { vehicle_id: string }).vehicle_id;
  const page = await ctx(browser);
  await signIn(page, va.email, '/va');
  await page.goto('/va/bookings/new', { waitUntil: 'networkidle' });
  await check(page, 'va add a rental');
  await expect(page.getByTestId('mr-past')).toHaveCount(0);
  // a bookable car with no booking in the next weeks
  const cars = await page.getByTestId('mr-vehicle_id').locator('option').evaluateAll((os) => os.map((o) => (o as HTMLOptionElement).value).filter(Boolean));
  expect(cars.length).toBeGreaterThan(0);
  const pick = new Date(Date.now() + 40 * 86_400_000);
  const pad = (n: number) => String(n).padStart(2, '0');
  const local = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T10:00`;
  let free = false;
  expect(cars).toContain(carId);
  for (const id of [carId]) {
    await page.getByTestId('mr-vehicle_id').selectOption(id);
    await page.getByTestId('mr-pickup_at').fill(local(pick));
    await page.getByTestId('mr-return_at').fill(local(new Date(pick.getTime() + 2 * 86_400_000)));
    if (!(await page.getByTestId('mr-new-renter').isChecked())) await page.getByTestId('mr-new-renter').check();
    await page.getByTestId('mr-date_of_birth').fill('1990-02-03');
    await page.getByTestId('mr-check').click();
    await expect(page.getByTestId('mr-quote')).toBeVisible({ timeout: 20_000 });
    if (await page.getByTestId('mr-free').isVisible()) { free = true; break; }
  }
  expect(free).toBe(true);
  // an assistant may type a price with its reason (0058), and has no clash override
  await expect(page.getByTestId('mr-rental_charge')).toBeVisible();
  await expect(page.getByTestId('mr-clash_reason')).toHaveCount(0);
  await page.getByTestId('mr-full_name').fill(`Casey Caller ${tag()}`);
  await page.getByTestId('mr-email').fill(`casey.${tag()}@example.test`);
  await page.getByTestId('mr-mobile').fill('4165550199');
  await page.getByTestId('mr-licence_number').fill('C1234-56789-01234');
  await page.getByTestId('mr-licence_expiry').fill('2030-01-31');
  // a payment link goes by email, so "do not email" stays off for it
  await page.getByTestId('mr-paid-by').selectOption('link');
  await page.getByTestId('choice-for_carmacars').check();
  await check(page, 'va add a rental, priced');
  await page.getByTestId('mr-submit').click();
  await expect(page.getByTestId('mr-done')).toBeVisible({ timeout: 30_000 });
  const number = (await page.getByTestId('mr-done').locator('h2').innerText()).match(/Rental (\S+) added/)![1]!;
  const [bk] = await sql`select b.status, b.payment_mode, b.added_by_staff and b.created_by = ${va.id} by_me from bookings b where b.booking_number = ${number}`;
  expect(`${bk!.status}/${bk!.payment_mode}/${bk!.by_me}`).toBe('pending_payment/link/true');
  await page.context().close();
  // the fixture car was published by itself (0070) without the app rebuilding the fleet page: off the site again
  await sql`update vehicle_listings set status = 'unpublished', unpublished_at = now(), unpublished_reason = 'e2e fixture' where vehicle_id = ${carId}`;
  await sql.end();
});

test('partner portal: the partner agreement, signed on screen and countersigned', async ({ browser }) => {
  test.setTimeout(120_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', `Ada Admin ${tag()}`);
  const pu = await mkUser(sql, 'partner', `Pat Partner ${tag()}`);
  const [r] = await sql`select app.partner_save(${admin.id}, ${sql.json({ business_name: `Harbour Car Hire ${tag()}`, contact_name: pu.name, email: pu.email, commission_bps: 2500 })}) as r`;
  const partnerId = (r!.r as { id: string }).id;
  await sql`update owners set user_id = ${pu.id} where id = (select owner_id from partners where id = ${partnerId})`;
  const page = await ctx(browser);
  await signIn(page, pu.email, '/owner');
  // six tabs since October 23, 2026: the partner agreement is under Documents, and Money has no invoices for a partner
  await expect(page.locator('.pt__nav')).toContainText('Documents');
  await expect(page.locator('.pt__nav, .pt__subnav')).not.toContainText('Invoices');
  await check(page, 'partner home');
  await page.goto('/owner/statements', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('owner-subnav')).toContainText('Payouts');
  await expect(page.getByTestId('owner-subnav')).not.toContainText('Invoices');
  await page.goto('/owner/documents', { waitUntil: 'networkidle' });
  await page.getByTestId('owner-subnav').getByRole('link', { name: 'Partner agreement' }).click();
  await page.waitForURL(/\/owner\/partner-agreement/);
  await page.waitForLoadState('networkidle');
  // the approved text (the legal review, 0053): no draft banner, sections 3 to 11
  await expect(page.locator('#partner-agreement')).not.toContainText('Draft for lawyer review');
  for (const h of ['3. Bookings and renters', '4. Money', '5. Insurance and condition', '6. Damage and claims', '7. Tolls and tickets',
    '8. Information and non-circumvention', '9. Liability', '10. Ending the agreement', '11. General']) await expect(page.locator('#partner-agreement')).toContainText(h);
  await expect(page.locator('#partner-agreement')).toContainText('the Partner will not rent directly to a renter CarmaCars introduced');
  await expect(page.locator('#partner-agreement')).toContainText('the Protection Plan) are CarmaCars\' own');
  await expect(page.locator('#partner-agreement')).toContainText('25%');
  await check(page, 'partner agreement');
  const form = page.getByTestId('portal-sign-form');
  // 0077: the agreement is prepared in its own request; the sign form appears once it is open
  await expect(form).toBeVisible({ timeout: 45_000 });
  await expect(form.getByTestId('signature-adopted')).toContainText(pu.name);
  await form.getByTestId('package-sign').click();
  await expect(page.getByTestId('package-signed').or(page.getByTestId('partner-agreement-signed'))).toBeVisible({ timeout: 30_000 });
  const [p] = await sql`select p.agreement_status, p.agreement_method,
      (select string_agg(x.signer_role || ':' || x.method, ',' order by x.signer_role) from sign_requests s join signature_records x on x.signature_request_id = s.signature_request_id
        where s.owner_id = p.owner_id and s.doc_type = 'partner_agreement' and s.status = 'signed') recs
    from partners p where p.id = ${partnerId}`;
  expect(`${p!.agreement_status}/${p!.recs}`).toBe('signed/carmacars:automatic,partner:typed');
  await page.goto('/owner/partner-agreement', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('partner-agreement-signed')).toContainText('Signed on screen');
  await page.context().close();
  await sql.end();
});
