import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// The admin portal end to end. At 375 and 1440: the dashboard, the request review (adjust, live
// re-pricing, the renter's view, send the offer, the renter sees it) and the calendar (blocks; at 1440
// a mouse drag with the database's confirm). At 1440: a rate change reaches the public car page, a site
// setting reaches the public site, a listing draft is approved and published, a toll statement is
// imported, matched and charged, an owner statement is built and approved, the company statement is
// built with its ties. Every admin page visited is checked with axe, for overflow and with the copy rules.
const SHOTS = 'test-results/admin';
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/18122211(?! Canada Inc\.?,? (?:operating as|o\/a) CarmaCars)|Canada Inc\b(?!\.?,? (?:operating as|o\/a) CarmaCars)/i, 'numbered company name (the payee "<legal name>, operating as CarmaCars" is allowed)'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;
mkdirSync(SHOTS, { recursive: true });

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.slice(0, 3).map((n) => `${n.target.join(' ')} ${n.html.slice(0, 160)} ${(n.failureSummary ?? '').replace(/\s+/g, ' ').slice(0, 200)}`).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(next.split('?')[0]!));
}
async function mkAdmin(sql: Sql, tag: string) {
  const id = randomUUID(); const email = `admin.${tag}.${Date.now()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Ada Admin')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function mkRenter(sql: Sql, email: string, name: string) {
  const id = randomUUID();
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`select public.register_account(${id}, ${email}, ${name}, null)`;
  return id;
}
/** A car with no booking or block within a day of [start, start + days] (days from today). */
async function freeCar(sql: Sql, start: number, days: number, skip: string[] = []) {
  const from = new Date(Date.now() + start * 86_400_000); const to = new Date(from.getTime() + days * 86_400_000);
  const rows = await sql`select v.id, l.slug from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable) and not (l.slug = any(${skip}))
      and not exists (select 1 from bookings b where b.vehicle_id = v.id and b.status in ('requested','offered','pending_payment','confirmed','on_rent','returned','closed')
                        and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${from.toISOString()}::timestamptz, ${to.toISOString()}::timestamptz))
      and not exists (select 1 from vehicle_calendar_blocks k where k.vehicle_id = v.id and k.removed_at is null and k.starts_at < ${to.toISOString()}::timestamptz and (k.ends_at is null or k.ends_at > ${from.toISOString()}::timestamptz))
    order by random() limit 1`;
  if (!rows[0]) throw new Error('no free car');
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  return { id: rows[0].id as string, slug: rows[0].slug as string, from: ymd(from), to: ymd(to) };
}
async function seedRequest(sql: Sql, user: string, email: string, name: string, vehicle: string, from: string, to: string) {
  const req = {
    request_key: randomUUID(), vehicle_id: vehicle, pickup_at: `${from}T10:00:00-04:00`, return_at: `${to}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' },
    coverage_option: 2, extras: { winter_tire: false, baby_seats: 0 },
    renter: { email, full_name: name, mobile: '+16475550123', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${user}) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  return v;
}
async function adminCtx(browser: Browser, viewport: { width: number; height: number }, email: string, next = '/admin') {
  const ctx = await browser.newContext({ viewport, baseURL: test.info().project.use.baseURL });
  const page = await ctx.newPage();
  await signIn(page, email, next);
  return page;
}
const vp = (phone: boolean) => (phone ? { width: 375, height: 812 } : { width: 1440, height: 900 });

test('admin: dashboard, review a request, adjust, re-price, send the offer, the renter sees it', async ({ page, browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const a = await mkAdmin(sql, `rv${phone ? 'p' : 'd'}`);
  const email = `renter.rv.${info.project.name}.${Date.now()}@example.test`;
  const user = await mkRenter(sql, email, 'Riley Review');
  const car = await freeCar(sql, 40 + (phone ? 0 : 20), 3);
  const req = await seedRequest(sql, user, email, 'Riley Review', car.id, car.from, car.to);
  const errors = watch(page);

  const ap = await adminCtx(browser, vp(phone), a.email);
  await expect(ap.getByRole('heading', { name: 'To do', level: 1 })).toBeVisible();
  // each request is a To do prompt of its own (0078) with Answer it
  await expect(ap.locator('[data-kind="requests"]').first()).toBeVisible();
  await ap.goto('/admin/overview', { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('dash-requests')).toBeVisible();
  await ap.screenshot({ path: `${SHOTS}/dashboard-${info.project.name}.png`, fullPage: true });
  await check(ap, 'dashboard');

  await ap.goto('/admin/requests', { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('requests')).toContainText(req.booking_number);
  await check(ap, 'requests');
  await ap.getByRole('link', { name: req.booking_number }).first().click();
  await ap.waitForURL(new RegExp(`/admin/bookings/${req.booking_number}`));
  await expect(ap.getByTestId('booking-review')).toBeVisible();
  const before = (await ap.getByTestId('review-total').innerText()).trim();
  const [rc] = await sql`select daily_rate_cents::int d from bookings where id = ${req.booking_id}`;
  const newDaily = ((rc!.d as number) - 1000) / 100;
  await ap.getByLabel('Daily ($)').fill(newDaily.toFixed(2));
  await expect(ap.getByTestId('review-price')).toContainText('Re-priced, not saved');
  await expect.poll(async () => (await ap.getByTestId('review-total').innerText()).trim(), { timeout: 10_000 }).not.toBe(before);
  const after = (await ap.getByTestId('review-total').innerText()).trim();
  await expect(ap.getByTestId('renter-preview')).toContainText(after);
  await ap.getByLabel('Message to the renter').fill('We lowered the daily rate for you.');
  await expect(ap.getByTestId('renter-preview')).toContainText('We lowered the daily rate for you.');
  await ap.screenshot({ path: `${SHOTS}/request-review-${info.project.name}.png`, fullPage: true });
  await check(ap, 'request review');
  await ap.getByTestId('review-send').click();
  await expect(ap.getByRole('status').filter({ hasText: 'Offer sent' })).toBeVisible({ timeout: 15_000 });
  const [b] = await sql`select status::text, daily_rate_cents::int d, total_due_at_booking_cents::int t from bookings where id = ${req.booking_id}`;
  expect(b!.status).toBe('offered');
  expect(b!.d).toBe(Math.round(newDaily * 100));
  await ap.goto(`/admin/bookings/${req.booking_number}?tab=history`, { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('timeline')).toContainText('offer sent');
  await check(ap, 'booking history');

  // the renter sees the offer with the new price and the message
  await signIn(page, email, `/account/bookings/${req.booking_number}/offer`);
  await expect(page.getByText('We lowered the daily rate for you.')).toBeVisible();
  await expect(page.getByTestId('total-due')).toHaveText(after);
  expect(errors.filter((e) => !/favicon|Failed to load resource/.test(e))).toEqual([]);
  await sql.end();
});

test('admin: master calendar, blocks, and a drag with the confirm', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const a = await mkAdmin(sql, `cal${phone ? 'p' : 'd'}`);
  const ap = await adminCtx(browser, vp(phone), a.email, '/admin/calendar');
  await expect(ap.getByTestId('master-calendar')).toBeVisible();
  await ap.screenshot({ path: `${SHOTS}/calendar-${info.project.name}.png`, fullPage: true });
  await check(ap, 'calendar');

  // create a block on a free car, then remove it
  const car = await freeCar(sql, 3, 2);
  const [veh] = await sql`select app.vehicle_name(${car.id}) n, plate from vehicles where id = ${car.id}`;
  await ap.getByTestId('cal-new-block').click();
  const form = ap.getByTestId('block-form');
  await form.getByLabel('Vehicle').selectOption(car.id);
  await form.getByLabel('Reason').selectOption('service');
  await form.getByLabel('From').fill(`${car.from}T09:00`);
  await form.getByLabel(/^To/).fill(`${car.to}T09:00`);
  await form.getByLabel(/^Note/).fill('Brake service e2e');
  await check(ap, 'calendar block form');
  await form.getByTestId('block-create').click();
  await expect.poll(async () => (await sql`select count(*)::int n from vehicle_calendar_blocks where vehicle_id = ${car.id} and note = 'Brake service e2e' and removed_at is null`)[0]!.n).toBe(1);
  if (!phone) {
    await ap.getByLabel('Find a plate, fleet number, booking or surname').fill(String(veh!.plate));
    // the car may also carry the cleaning block after a trip (0040): pick the block made here
    await ap.locator(`[data-vehicle="${car.id}"] .cal__item.is-block`).filter({ hasText: 'Brake service e2e' }).first().click();
  } else {
    await ap.getByTestId('cal-agenda').getByRole('button', { name: /Brake service e2e/ }).first().click();
  }
  const panel = ap.getByTestId('cal-panel');
  await panel.getByLabel('Reason for removing').fill('Service moved');
  await panel.getByTestId('block-remove').click();
  await expect.poll(async () => (await sql`select removed_reason from vehicle_calendar_blocks where vehicle_id = ${car.id} and note = 'Brake service e2e'`)[0]?.removed_reason).toBe('Service moved');

  if (!phone) {
    // a request inside the window, dragged one day later with the mouse
    const c2 = await freeCar(sql, 4, 3, [car.slug]);
    const email = `renter.cal.${Date.now()}@example.test`;
    const user = await mkRenter(sql, email, 'Drew Dragger');
    const r = await seedRequest(sql, user, email, 'Drew Dragger', c2.id, c2.from, c2.to);
    await ap.reload({ waitUntil: 'networkidle' });
    await ap.getByLabel('Find a plate, fleet number, booking or surname').fill(r.booking_number);
    const bar = ap.getByTestId(`bar-${r.booking_number}`);
    await bar.scrollIntoViewIfNeeded();
    const box = (await bar.boundingBox())!;
    await ap.mouse.move(box.x + 10, box.y + box.height / 2);
    await ap.mouse.down();
    for (let i = 1; i <= 12; i++) await ap.mouse.move(box.x + 10 + i * 6, box.y + box.height / 2);
    await ap.mouse.up();
    const confirm = ap.getByTestId('cal-confirm');
    await expect(confirm.getByTestId('cal-price')).toBeVisible({ timeout: 10_000 });
    await ap.screenshot({ path: `${SHOTS}/calendar-confirm-${info.project.name}.png` });
    await check(ap, 'calendar confirm');
    const [old] = await sql`select pickup_at from bookings where id = ${r.booking_id}`;
    await confirm.getByLabel('Reason').fill('Renter asked by phone');
    await confirm.getByTestId('cal-apply').click();
    await expect.poll(async () => (await sql`select extract(epoch from pickup_at - ${old!.pickup_at}::timestamptz)::int s from bookings where id = ${r.booking_id}`)[0]!.s, { timeout: 10_000 }).toBe(86_400);
  }
  await sql.end();
});

test('admin: rates, site settings, listing review, tolls, statements', async ({ browser }, info) => {
  test.skip(info.project.name.startsWith('phone'), 'desktop flows');
  test.setTimeout(600_000); // the longest scenario: about 2 minutes locally, near 5 on a 2-CPU CI runner
  const sql = db();
  const a = await mkAdmin(sql, 'flows');
  const ap = await adminCtx(browser, vp(false), a.email, '/admin/vehicles');
  await check(ap, 'vehicles');

  // ---------------------------------------------------------------- a rate change reaches the public car page
  // (a seeded car with its signed schedule: cars other specs add are published too since 0070)
  const [car] = await sql`select v.id, l.slug, r.daily_rate_cents::int d, r.weekend_rate_cents::int we, r.weekly_rate_cents::int wk, r.monthly_rate_cents::int m
    from vehicles v join vehicle_listings l on l.vehicle_id = v.id join rate_cards r on r.vehicle_id = v.id and r.effective_to is null
    where l.status = 'published' and v.management_mode = 'managed' and v.is_sample order by l.slug limit 1`;
  const daily = car!.d + 1300;
  await ap.goto(`/admin/vehicles/${car!.id}?tab=rates`, { waitUntil: 'networkidle' });
  await check(ap, 'vehicle rates');
  const rf = ap.getByTestId('rate-form-form');
  await rf.getByTestId('rate-form-daily').fill((daily / 100).toFixed(2));
  await rf.getByTestId('rate-form-submit').click();
  await expect(ap.getByText('New rates saved.')).toBeVisible({ timeout: 10_000 });
  const pub = await browser.newPage();
  await pub.goto(`/cars/${car!.slug}`, { waitUntil: 'networkidle' });
  await expect(pub.locator('body')).toContainText(`$${(daily / 100).toLocaleString('en-CA')}`);
  await sql`select app.set_rate_card(${car!.id}, ${car!.d}, ${car!.we}, ${car!.wk}, ${car!.m}, now(), null)`;

  // ---------------------------------------------------------------- a site setting reaches the public site
  const [site] = await sql`select tagline from site_settings`;
  const tagline = `Drive the good karma ${Date.now() % 10000}`;
  await ap.goto('/admin/settings/site', { waitUntil: 'networkidle' });
  await ap.screenshot({ path: `${SHOTS}/settings-site.png`, fullPage: true });
  await check(ap, 'site settings');
  const sf = ap.getByTestId('site-brand');
  await sf.getByLabel('Tagline').fill(tagline);
  await sf.getByTestId('site-brand-save').click();
  await expect(sf.getByText('Saved.')).toBeVisible({ timeout: 10_000 });
  await pub.goto('/', { waitUntil: 'networkidle' });
  await expect(pub.locator('body')).toContainText(tagline);
  await sql`update site_settings set tagline = ${site!.tagline}`;
  for (const s of ['program', 'fees', 'airports', 'coverage', 'staff', 'content']) { await ap.goto(`/admin/settings/${s}`, { waitUntil: 'networkidle' }); await check(ap, `settings ${s}`); }
  await ap.goto('/admin/settings/program', { waitUntil: 'networkidle' });
  await ap.screenshot({ path: `${SHOTS}/settings-program.png`, fullPage: true });

  // ---------------------------------------------------------------- a listing draft approved and published
  const [lc] = await sql`select v.id, l.slug from vehicles v join vehicle_listings l on l.vehicle_id = v.id where l.status = 'published' and v.partner_id is null and l.slug <> ${car!.slug} order by l.slug desc limit 1`;
  await sql`update listing_intakes set state = 'cancelled' where vehicle_id = ${lc!.id} and state not in ('published', 'cancelled')`;
  const [ik] = await sql`insert into listing_intakes (vehicle_id, started_by, started_role, state, review_required) values (${lc!.id}, ${a.id}, 'owner', 'started', true) returning id`;
  const [cover] = await sql`select coalesce(processed_path, original_path) p from vehicle_photos where vehicle_id = ${lc!.id} and replaced_at is null and coalesce(processed_path, original_path) is not null order by is_cover desc limit 1`;
  // the photo pipeline's worker, faked: every required shot uploaded and processed, a copy draft written
  await sql`select app.record_listing_upload(${a.id}, ${ik!.id}, jsonb_build_object('shot_type', s.code, 'original_path', ${cover!.p}::text, 'width', 3000, 'height', 2000, 'byte_size', 900000, 'mime_type', 'image/jpeg'))
    from listing_shot_types s where s.required and s.is_active order by s.seq`;
  await sql`select app.submit_listing_intake(${a.id}, ${ik!.id})`;
  const words = Array.from({ length: 140 }, (_, i) => ['smooth', 'quiet', 'roomy', 'comfortable', 'efficient', 'bright', 'clean', 'easy'][i % 8]).join(' ');
  const copy = { headline: 'A comfortable car for the city and the highway', description: words, features: ['Heated seats', 'Apple CarPlay', 'Android Auto', 'Backup camera', 'Keyless entry', 'Blind spot assist', 'LED headlights'],
    faq: [{ question: 'How many suitcases fit?', answer: 'Two large suitcases.' }, { question: 'Can I fit a child seat?', answer: 'Yes, two.' }, { question: 'Is it good in winter?', answer: 'Yes, with winter tires.' }],
    seo_title: 'Car rental in Toronto', seo_description: 'Rent this car in Toronto.', model: 'e2e', prompt_version: 'e2e' };
  for (let k = 0; k < 10; k++) {
    const jobs = await sql`select * from app.claim_listing_jobs('e2e-worker', 100, null, now())`;
    if (!jobs.length) break;
    for (const j of jobs) {
      const out = j.kind === 'draft_copy' ? copy : j.kind === 'process_photo' ? { processed_path: cover!.p, width: 2400, height: 1600 } : j.kind === 'decode_vin' ? { ok: false } : {};
      await sql`select app.complete_listing_job(${j.id}, ${sql.json(out)}, 'fake', 0, 10)`;
    }
  }
  expect((await sql`select state from listing_intakes where id = ${ik!.id}`)[0]!.state).toBe('needs_review');
  // a sample car's short sample text would not pass the listing lint; this one carries a full text (a real car's copy is
  // written by the search job, 0061)
  await sql`update vehicle_listings set description = ${words} where vehicle_id = ${lc!.id}`;
  await ap.goto(`/admin/listings/${ik!.id}`, { waitUntil: 'networkidle' });
  await check(ap, 'listing review');
  // the copy is written by itself (0061): the review has no copy text boxes, only the copy card
  await expect(ap.getByTestId('listing-review').locator('#lr-headline, #lr-description')).toHaveCount(0);
  const [before] = await sql`select headline, description from vehicle_listings where vehicle_id = ${lc!.id}`;
  // every public photo needs a plate decision before publishing (0042): the sample photos show no plate
  await ap.getByTestId('plates-none-visible').click();
  await ap.getByTestId('plates-none-visible-yes').click();
  await expect(ap.getByTestId('plates-none-visible')).toHaveCount(0, { timeout: 20_000 });
  await ap.getByTestId('listing-approve').click();
  await expect(ap.getByText('Approved and published.')).toBeVisible({ timeout: 15_000 });
  expect((await sql`select state from listing_intakes where id = ${ik!.id}`)[0]!.state).toBe('published');
  await pub.goto(`/cars/${lc!.slug}`, { waitUntil: 'networkidle' });
  expect(await pub.locator('h1').count()).toBe(1);
  // approving sends no copy: the listing's text is what it was (a sample car keeps its sample text)
  expect((await sql`select headline from vehicle_listings where vehicle_id = ${lc!.id}`)[0]!.headline).toBe(before!.headline);

  // ---------------------------------------------------------------- a toll statement imported, a match confirmed, charged
  const tc = await freeCar(sql, -12, 5, [car!.slug, lc!.slug]);
  const temail = `renter.toll.${Date.now()}@example.test`;
  const tuser = await mkRenter(sql, temail, 'Toby Toll');
  const [renter] = await sql`insert into renters (user_id, legal_name, email, mobile) values (${tuser}, 'Toby Toll', ${temail}, '+16475550177') returning id`;
  const number = `E2E-T${Date.now() % 1_000_000}`;
  const pick = new Date(Date.now() - 11 * 86_400_000); const ret = new Date(Date.now() - 7 * 86_400_000);
  await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days, handed_over_at, checked_in_at,
      daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days, rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km,
      deposit_cents, subtotal_at_booking_cents, hst_at_booking_cents, total_due_at_booking_cents)
    values (${number}, 'standard', 'returned', ${tc.id}, ${renter!.id}, ${new Date(pick.getTime() - 5 * 86_400_000).toISOString()}, ${pick.toISOString()}, ${ret.toISOString()}, ${ret.toISOString()}, 4, ${pick.toISOString()}, ${ret.toISOString()},
      10000, 12000, 56000, 180000, 'daily', 4, 0, 40000, 0, 200, 800, 35, 100000, 40000, 5200, 45200)`;
  const [plate] = await sql`select plate from vehicles where id = ${tc.id}`;
  const tripAt = new Date(pick.getTime() + 2 * 86_400_000);
  const local = new Intl.DateTimeFormat('sv-SE', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }).format(tripAt);
  const trip = `TR${Date.now()}`;
  const csv = `Transaction ID,Licence Plate,Trip Date Time,Entry,Exit,Amount\n${trip},${plate!.plate},${local},Hwy 400,Hwy 404,12.34\n`;
  await ap.goto('/admin/tolls/import', { waitUntil: 'networkidle' });
  await check(ap, 'toll import');
  await ap.getByLabel('Operator').fill('407 ETR');
  await ap.getByLabel(/The statement itself/).setInputFiles({ name: 'statement.pdf', mimeType: 'application/pdf', buffer: Buffer.from('%PDF-1.4\n% e2e statement\n%%EOF\n') });
  await expect(ap.getByText('Attached: statement.pdf')).toBeVisible({ timeout: 10_000 });
  await ap.getByLabel('CSV file').setInputFiles({ name: 'statement.csv', mimeType: 'text/csv', buffer: Buffer.from(csv) });
  await expect(ap.getByLabel('Licence Plate')).toHaveValue('plate');
  await ap.getByLabel('Trip Date Time').selectOption('occurred_at');
  await ap.getByLabel('Transaction ID').selectOption('notice_number');
  await ap.getByTestId('toll-import-run').click();
  await expect(ap.getByTestId('toll-import-result')).toContainText('1 imported', { timeout: 15_000 });
  const [tt] = await sql`select id, matched_to, booking_id is not null b from toll_tickets where notice_number = ${trip}`;
  await ap.goto(`/admin/tolls/${tt!.id}`, { waitUntil: 'networkidle' });
  await check(ap, 'toll match review');
  if (tt!.matched_to !== 'renter') { await ap.getByTestId('toll-confirm-0').click(); await expect.poll(async () => (await sql`select matched_to from toll_tickets where id = ${tt!.id}`)[0]!.matched_to).toBe('renter'); await ap.reload(); }
  await ap.getByTestId('toll-charge').click();
  await ap.getByTestId('toll-charge-submit').click();
  await expect.poll(async () => (await sql`select charged_at is not null c from toll_tickets where id = ${tt!.id}`)[0]!.c, { timeout: 15_000 }).toBe(true);
  await ap.goto('/admin/tolls', { waitUntil: 'networkidle' });
  await check(ap, 'toll queue');

  // ---------------------------------------------------------------- an owner statement built and approved
  const [ow] = await sql`select o.id, m.month::text from owners o cross join lateral (select (date_trunc('month', now()) - make_interval(months => g))::date as month from generate_series(0, 24) g) m
    where o.status = 'active' and o.kind <> 'company' -- the company fleet has no owner statement (0046)
      and exists (select 1 from vehicles v where v.owner_id = o.id and v.enrollment_date is not null and v.enrollment_date < m.month + interval '1 month')
      and not exists (select 1 from owner_statements s where s.owner_id = o.id and s.status <> 'draft' and s.statement_month = m.month)
    order by m.month desc limit 1`;
  await ap.goto('/admin/statements', { waitUntil: 'networkidle' });
  await check(ap, 'statements');
  let owner = ow?.id as string | undefined; let month = ow?.month as string | undefined;
  if (ow) {
    await ap.getByTestId('statement-build').click();
    const sd = ap.getByTestId('statement-build-form');
    await sd.getByLabel('Owner').selectOption(ow.id);
    await sd.getByLabel('Month (first day)').fill(String(ow.month));
    await sd.getByTestId('statement-build-submit').click();
    await ap.waitForURL(/\/admin\/statements\/[0-9a-f-]{36}/, { timeout: 15_000 });
  } else {
    // every month already approved (an earlier run): reissue the latest, which builds the next version as a draft
    const [ls] = await sql`select id, owner_id, statement_month::text m from owner_statements where status = 'approved' order by built_at desc limit 1`;
    const [re] = await sql`select app.reissue_owner_statement(${ls!.id}, ${a.id}, 'e2e: build again') id`;
    owner = ls!.owner_id as string; month = ls!.m as string;
    await ap.goto(`/admin/statements/${re!.id}`, { waitUntil: 'networkidle' });
  }
  await check(ap, 'statement');
  await ap.getByTestId('statement-approve').click();
  await ap.getByTestId('statement-approve-submit').click();
  await expect.poll(async () => (await sql`select status from owner_statements where owner_id = ${owner!} and statement_month = ${month!}::date order by version desc limit 1`)[0]!.status, { timeout: 15_000 }).toBe('approved');

  // ---------------------------------------------------------------- the company statement and its ties
  await ap.goto('/admin/reports', { waitUntil: 'networkidle' });
  await ap.getByTestId('company-build').click();
  await expect(ap.getByTestId('company-ties')).toBeVisible({ timeout: 20_000 });
  await ap.screenshot({ path: `${SHOTS}/company-statement.png`, fullPage: true });
  await check(ap, 'company statement');
  await expect(ap.getByTestId('company-ties')).toContainText('The ties pass');

  // every other admin screen opens and passes axe
  for (const p of ['/admin/bookings', '/admin/listings', '/admin/vehicles/bulk-rates', '/admin/money', '/admin/money?tab=refunds', '/admin/insurer-invoices', '/admin/invoices', '/admin/payouts', '/admin/expenses',
    '/admin/reconciliation', '/admin/damages', '/admin/incidents', '/admin/tasks', '/admin/owners', '/admin/investors', '/admin/reviews', '/admin/messages', '/admin/audit', '/admin/settings']) {
    const res = await ap.goto(p, { waitUntil: 'networkidle' });
    expect(res?.status(), p).toBe(200);
    await check(ap, p);
  }
  await sql.end();
});
