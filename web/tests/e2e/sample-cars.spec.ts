import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0065 end to end: the sample cars marked "Example car" on the fleet and the car page, a request on a sample
// car sent through the real form becoming an enquiry (EQ-) with a customer service task and no booking, Admin > Cars and
// Settings > Site with "Hide sample cars" / "Show sample cars" (hidden from the fleet and back), "Not on the site yet"
// with each real car's next step, and a real car without photos showing its sample photo. The local stack's sample
// cars take real bookings (vehicles.sample_bookable, for the other specs); this spec turns that off for the Ford F-150.
const PW = 'correct horse battery';
const ENQ_CAR = 'ford-f-150';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
}
function futureRange(offsetDays: number) {
  const d = new Date(); d.setUTCDate(d.getUTCDate() + offsetDays);
  const from = d.toISOString().slice(0, 10); d.setUTCDate(d.getUTCDate() + 3);
  return { from, to: d.toISOString().slice(0, 10) };
}

test('a request on a sample car becomes an enquiry for a similar real car, never a booking', async ({ page }, info) => {
  test.setTimeout(120_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  await sql`update vehicles set sample_bookable = false where id = (select vehicle_id from vehicle_listings where slug = ${ENQ_CAR})`;
  const email = `enquiry.${info.project.name}.${Date.now()}@example.test`;
  // the fleet card and the car page say "Example car"
  await page.goto('/cars');
  await acceptCookies(page);
  await expect(page.getByTestId('example-car-badge').first()).toBeVisible();
  await page.goto(`/cars/${ENQ_CAR}`);
  await expect(page.locator('.car-top').getByTestId('example-car-badge')).toHaveText('Example car');
  await expect(page.getByTestId('example-car-note')).toContainText('similar real car');
  await check(page, 'car page');
  // the real form, as for any car
  const range = futureRange(90 + (isPhone() ? 0 : 7));
  await page.goto(`/book/${ENQ_CAR}?from=${range.from}&to=${range.to}&tf=10:00&tt=10:00`);
  await expect(page.getByTestId('example-car-request-note')).toContainText('similar real car');
  await page.getByRole('button', { name: 'Continue to driver details' }).click();
  await page.locator('#rq-first').fill('Erin');
  await page.locator('#rq-last').fill('Enquirer');
  await page.locator('#rq-email').fill(email);
  await page.locator('#rq-phone').fill('647-555-0177');
  await page.locator('#rq-dobm').selectOption('3');
  await page.locator('#rq-dobd').fill('12');
  await page.locator('#rq-doby').fill('1989');
  await page.getByRole('button', { name: 'Continue to licence' }).click();
  await page.locator('label', { hasText: 'Ontario G' }).first().click();
  await page.locator('label.option', { hasText: 'Option 2' }).click();
  await page.locator('#rq-notes').fill('A truck for a move.');
  await page.getByRole('button', { name: 'Continue to add-ons' }).click();
  await page.getByRole('button', { name: 'Review request' }).click();
  await page.locator('input[name="agree"]').check();
  await page.getByRole('button', { name: 'Send request' }).click();
  await page.waitForURL(/\/book\/sent\/EQ-/, { timeout: 30_000 });
  const number = decodeURIComponent(page.url().split('/').pop()!);
  await expect(page.getByTestId('request-number')).toHaveText(number);
  await expect(page.getByTestId('enquiry-sent')).toContainText('Enquiry sent');
  await expect(page.locator('body')).toContainText('similar real car');
  await check(page, 'enquiry sent');
  // the database: a lead and a customer service task, no booking
  const lead = await sql`select id, payload from leads where kind = 'sample_car' and email = ${email}`;
  expect(lead.length).toBe(1);
  expect(lead[0]!.payload.reference).toBe(number);
  const task = await sql`select title, queue from tasks where task_type = 'sample_car_enquiry' and related_id = ${lead[0]!.id}`;
  expect(task[0]?.queue).toBe('cs');
  expect(task[0]?.title).toContain('Suggest a similar real car');
  const booked = await sql`select count(*)::int n from bookings b join renters r on r.id = b.renter_id where lower(r.email) = ${email}`;
  expect(booked[0]!.n).toBe(0);
  await sql.end();
});

test('Admin: hide the sample cars in one click, show them again, and see why each real car is not on the site', async ({ page }) => {
  test.skip(isPhone(), 'once: hiding the sample cars touches the whole fleet');
  test.setTimeout(180_000);
  const sql = db();
  const id = randomUUID(); const email = `admin.samples.${Date.now()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Sam Admin')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  // a real car in onboarding without photos (the owner has not signed yet)
  const [o] = await sql`select id from owners where kind = 'program' and email <> 'sample.owner@example.test' order by created_at limit 1`;
  const vid = randomUUID();
  if (o) {
    await sql`insert into vehicles (id, owner_id, year, make, model, vin, plate, class, status, management_mode, onboarding_method, body_type)
              values (${vid}, ${o.id}, 2017, 'Volkswagen', 'Jetta', ${('E2ES' + randomBytes(7).toString('hex').toUpperCase()).slice(0, 17)}, ${'E2S' + randomBytes(2).toString('hex').toUpperCase()},
                      'standard', 'onboarding', 'managed', 'transfer', 'Sedan')`;
    await sql`insert into vehicle_onboardings (vehicle_id, status) values (${vid}, 'intake')`;
  }
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });

  await page.goto('/admin/vehicles');
  if (o) {
    const row = page.getByTestId('car-not-public').filter({ hasText: '2017 Volkswagen Jetta' }).first();
    await expect(row).toContainText('Next:');
    await expect(row).toContainText('sample photos');
  }
  await check(page, 'admin vehicles');
  // hide: one click, the fleet has no example car; then show: they are back
  const hide = page.getByTestId('sample-cars-hide');
  await expect(hide).toBeVisible();
  await hide.click();
  await expect(page.getByTestId('sample-cars-show')).toBeVisible({ timeout: 20_000 });
  const pub = await sql`select count(*)::int n from vehicle_listings l join vehicles v on v.id = l.vehicle_id where v.is_sample and l.status = 'published'`;
  expect(pub[0]!.n).toBe(0);
  const fleet = await (await page.request.get('/cars')).text();
  expect(fleet).not.toContain('data-testid="example-car-badge"');
  await page.getByTestId('sample-cars-show').click();
  await expect(page.getByTestId('sample-cars-hide')).toBeVisible({ timeout: 20_000 });
  const back = await sql`select count(*)::int n from vehicle_listings l join vehicles v on v.id = l.vehicle_id where v.is_sample and l.status = 'published'`;
  expect(back[0]!.n).toBeGreaterThanOrEqual(20);
  // Settings > Site has the same switch
  await page.goto('/admin/settings/site');
  await expect(page.getByTestId('site-sample-cars')).toContainText('Example car');
  await expect(page.getByTestId('site-sample-cars').getByTestId('sample-cars-hide')).toBeVisible();
  await page.goto('/admin/vehicles/samples');
  await expect(page.getByTestId('sample-cars-state')).toBeVisible();
  await check(page, 'sample cars page');
  // a real car without photos, once published, shows its sample photo on the site
  if (o) {
    // onboarding, then ready to list, then available (the allowed steps of 0011)
    await sql`update vehicles set status = 'ready_to_list' where id = ${vid}`;
    await sql`update vehicles set status = 'available' where id = ${vid}`;
    await sql`insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
              values (${vid}, 5500, 6000, 33000, 110000, 200, 25, 50000, 0, 0, now() - interval '1 day')`;
    const slug = `volkswagen-jetta-e2e-${randomBytes(3).toString('hex')}`;
    await sql`insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style)
              values (${vid}, ${slug}, '2017 Volkswagen Jetta', 'published', now(), 5, 'Automatic', 'Sedan')
              on conflict (vehicle_id) do update set slug = excluded.slug, status = 'published', published_at = now(), seats = 5, transmission = 'Automatic', body_style = 'Sedan'`;
    await page.goto(`/cars/${slug}`);
    await expect(page.getByTestId('sample-photo-caption').first()).toContainText('Representative photo');
    await expect(page.locator('meta[property="og:image"]')).toHaveAttribute('content', /\/sample-photos\//);
    await sql`update vehicle_listings set status = 'unpublished' where vehicle_id = ${vid}`;
  }
  await sql.end();
});
