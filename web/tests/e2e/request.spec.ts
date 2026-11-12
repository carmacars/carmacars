import { expect, test } from '@playwright/test';
import { acceptCookies, db, noOverflow, phoneGatePassed, watch , chooseCardCoverage } from './helpers';

// The request flow end to end: car page, dates, the four steps, send; then the database holds a
// booking with status requested and the renter_request_received event, and the draft is closed.
async function freeWindow(slug: string) {
  const sql = db();
  let range = futureRange(60);
  for (let off = 60; off < 150; off += 4) {
    range = futureRange(off);
    const busy = await sql`select count(*)::int n from bookings b join vehicle_listings l using (vehicle_id) where l.slug = ${slug} and b.status in ('confirmed','on_rent') and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${range.from}::date::timestamptz, ${range.to}::date::timestamptz + interval '1 day')`;
    if (busy[0]!.n === 0) break;
  }
  await sql.end();
  return range;
}

function futureRange(offsetDays: number) {
  const d = new Date(); d.setUTCDate(d.getUTCDate() + offsetDays);
  const from = d.toISOString().slice(0, 10); d.setUTCDate(d.getUTCDate() + 3);
  return { from, to: d.toISOString().slice(0, 10) };
}

test('request to book creates a requested booking and its event', async ({ page }, info) => {
  { const s0 = db(); await s0`delete from app.rate_limit_hits`; await s0.end(); }
  const errors = watch(page);
  const sql = db();
  // a car and dates with no sample booking: search the calendar for a free 3-day window
  const slug = info.project.name.startsWith('phone') ? 'toyota-corolla' : 'kia-forte';
  const email = `e2e.${info.project.name}.${Date.now()}@example.test`;
  const range = await freeWindow(slug);
  await page.goto(`/book/${slug}?from=${range.from}&to=${range.to}&tf=10:00&tt=10:00`);
  await acceptCookies(page);
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Request to book');
  // step 1: the dates came from the link; choose delivery with the address lookup
  await page.locator('label.option', { hasText: 'Deliver it to an address' }).click();
  await page.locator('#rq-addr1').fill('union');
  await page.getByRole('option', { name: /Union Station/ }).click();
  await expect(page.locator('#rq-addr1')).toHaveValue(/Union Station/);
  await page.getByRole('button', { name: 'Continue to driver details' }).click();
  // step 2
  await expect(page.getByRole('heading', { name: 'The driver' })).toBeVisible();
  await page.locator('#rq-first').fill('Avery');
  await page.locator('#rq-last').fill('Tester');
  await page.locator('#rq-email').fill(email);
  await page.locator('#rq-phone').fill('647-555-0142');
  await page.locator('#rq-dobm').selectOption('4');
  await page.locator('#rq-dobd').fill('9');
  await page.locator('#rq-doby').fill('1990');
  await page.getByRole('button', { name: 'More additional drivers' }).click();
  await page.locator('#rq-ad0-first').fill('Jordan');
  await page.locator('#rq-ad0-last').fill('Second');
  await page.locator('#rq-ad0-email').fill(`second.${email}`);
  await page.locator('#rq-ad0-dobm').selectOption('2');
  await page.locator('#rq-ad0-dobd').fill('14');
  await page.locator('#rq-ad0-doby').fill('1988');
  await page.getByRole('button', { name: 'Continue to licence' }).click();
  // step 3: an error first, then the right answers
  await page.getByRole('button', { name: 'Continue to add-ons' }).click();
  await expect(page.getByText('Choose your licence class.')).toBeVisible();
  await page.locator('label', { hasText: 'Ontario G2' }).click();
  await chooseCardCoverage(page);
  await page.locator('#rq-notes').fill('Flight AC 123.');
  await page.getByRole('button', { name: 'Continue to add-ons' }).click();
  // step 4: add-ons (0070), priced in the estimate
  await expect(page.getByRole('heading', { name: 'Add-ons' })).toBeVisible();
  await page.locator('#rq-umbrella').check();
  await page.getByRole('button', { name: 'Review request' }).click();
  // step 5
  await expect(page.getByRole('heading', { name: 'Check it and send' })).toBeVisible();
  await expect(page.locator('.req__review')).toContainText('Avery Tester');
  await expect(page.locator('.req__review')).toContainText('Umbrella');
  await noOverflow(page);
  await page.getByRole('button', { name: 'Send request' }).click();
  await expect(page.getByText('Tick this box to send your request.')).toBeVisible();
  await page.locator('input[name="agree"]').check();
  // r41 (2490): no "send me deals" box
  await expect(page.locator('input[name="marketing"]')).toHaveCount(0);
  await page.getByRole('button', { name: 'Send request' }).click();
  // confirmation
  await page.waitForURL(/\/book\/sent\//, { timeout: 30_000 });
  const number = decodeURIComponent(page.url().split('/').pop()!);
  await expect(page.getByTestId('request-number')).toHaveText(number);
  await expect(page.getByRole('heading', { level: 1 })).toContainText('Request sent, Avery');
  // the database
  const rows = await sql`select b.id, b.status::text, b.coverage_option, b.pickup_location_kind, b.request_key, l.slug,
                          (select count(*)::int from booking_drivers d where d.booking_id = b.id) drivers,
                          (select count(*)::int from consents c where c.booking_id = b.id) consents
                     from bookings b join vehicle_listings l using (vehicle_id) where b.booking_number = ${number}`;
  expect(rows).toHaveLength(1);
  const b = rows[0]!;
  expect(b.status).toBe('requested');
  expect(b.slug).toBe(slug);
  expect(b.coverage_option).toBe(2);
  expect(b.pickup_location_kind).toBe('delivery');
  expect(b.drivers).toBe(2);
  expect(b.consents).toBe(2); // terms and privacy (r41: no marketing opt-in box on the request; implied consent covers marketing)
  const ev = await sql`select code from app_events where entity = 'booking' and entity_id = ${b.id} and code = 'renter_request_received'`;
  expect(ev).toHaveLength(1);
  const draft = await sql`select count(*)::int n from form_drafts where form_code = 'booking_request' and submitted_at is not null and result ->> 'booking_number' = ${number}`;
  expect(draft[0]!.n).toBe(1);
  await sql.end();
  expect(errors).toEqual([]);
});

test('the wizard keeps a draft and resumes it', async ({ page }) => {
  await page.goto('/book/honda-civic');
  await acceptCookies(page);
  await page.locator('label.option', { hasText: 'At the airport' }).first().click();
  await page.locator('#rq-airport1').selectOption({ index: 1 });
  // the autosave is done when the draft (with its token) is on the device: a fixed 1.5 s wait was too short on a busy runner
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('cc.request.v2') ?? '{}').token ?? null), { timeout: 15_000 }).toBeTruthy();
  await page.reload();
  await expect(page.getByText('We kept your place')).toBeVisible({ timeout: 10_000 });
  await expect(page.locator('#rq-airport1')).not.toHaveValue('');
  const token = await page.evaluate(() => JSON.parse(localStorage.getItem('cc.request.v2') ?? '{}').token as string | null);
  expect(token).toBeTruthy();
  const sql = db();
  const d = await sql`select count(*)::int n from form_drafts where form_code = 'booking_request' and submitted_at is null and data ->> 'car' = 'honda-civic'`;
  expect(d[0]!.n).toBeGreaterThan(0);
  await sql.end();
});

test('car page: calendar shows the turnaround, estimate comes from the database, bar carries the total', async ({ page }) => {
  const errors = watch(page);
  const sql = db();
  const [bk] = await sql`select (b.return_at at time zone 'America/Toronto')::date::text d,
      to_char((b.return_at at time zone 'America/Toronto') + make_interval(mins => (app.settings()).turnaround_buffer_minutes), 'FMHH12:MI') free,
      extract(hour from (b.return_at at time zone 'America/Toronto') + make_interval(mins => (app.settings()).turnaround_buffer_minutes)) >= 12 pm from bookings b join vehicle_listings l using (vehicle_id) where l.slug = 'mercedes-benz-c300' and b.status = 'confirmed' and b.return_at > now() + interval '1 day' order by b.return_at limit 1`;
  await sql.end();
  await page.goto('/cars/mercedes-benz-c300');
  await acceptCookies(page);
  // the cookie choice refreshes the page: wait for it to settle before working the calendar
  await page.waitForLoadState('networkidle');
  // 0280: the booked days show once this device gave a mobile number (the box is on by default)
  await expect(page.getByTestId('see-full-availability')).toBeVisible();
  await phoneGatePassed(page, test.info().project.use.baseURL!);
  await page.reload({ waitUntil: 'networkidle' });
  await expect(page.getByTestId('full-availability')).toContainText('Days already booked are crossed out.');
  // the day a booking ends is free from the turnaround after its return (r27: one buffer between trips, 90 minutes by default)
  const day = page.locator(`.cal [data-date="${bk!.d}"]`);
  await expect(async () => { await page.locator('#dates').scrollIntoViewIfNeeded({ timeout: 2_000 }); }).toPass({ timeout: 15_000 });
  for (let i = 0; i < 4 && !(await day.count()); i++) await page.getByRole('button', { name: 'Next month' }).first().click();
  await expect(day).toHaveClass(/is-part/);
  await expect(day).toHaveAttribute('aria-label', new RegExp(`partly available, free from ${bk!.free} ${bk!.pm ? 'p' : 'a'}\\.m\\.`));
  // dates in the address (from the fleet) fill the calendar, and the estimate is the database's quote
  const { from, to } = await freeWindow('mercedes-benz-c300');
  await page.goto(`/cars/mercedes-benz-c300?from=${from}&to=${to}&tf=10:00&tt=10:00`);
  const q = db();
  const [v] = await q`select vehicle_id from vehicle_listings where slug = 'mercedes-benz-c300'`;
  const [quote] = await q`select (public.quote_booking(${v!.vehicle_id}, (${from} || ' 10:00')::timestamp at time zone 'America/Toronto', (${to} || ' 10:00')::timestamp at time zone 'America/Toronto') ->> 'total_cents')::int t`;
  await q.end();
  await expect.poll(async () => (await page.locator('.estimate__lines tfoot td').textContent())?.replace(/[^0-9]/g, '')).toBe(String(quote!.t));
  const shown = await page.locator('.estimate__lines tfoot td').textContent();
  // the sticky bar carries the same total once the car header has scrolled away
  await page.locator('#questions').scrollIntoViewIfNeeded();
  await expect(page.locator('.bookbar.is-on .bookbar__price b')).toHaveText(shown!.trim());
  await expect(page.locator('.estimate__lines')).toContainText('Rental charge');
  expect(errors).toEqual([]);
});

// 2670: a refused request says exactly why, keeps everything typed, and reaches Sales once per person, car and day.
test('a refused request says why, keeps the answers and leaves one Sales follow-up', async ({ page }, info) => {
  const sql = db();
  const slug = 'honda-civic';
  const email = `e2e.refused.${info.project.name}.${Date.now()}@example.test`.toLowerCase();
  // this person already has 3 requests open (the limit): the fourth is refused with a result
  const [car] = await sql`select vehicle_id from vehicle_listings where slug = ${slug}`;
  for (let i = 0; i < 3; i++) {
    const from = new Date(Date.now() + (200 + i * 6) * 864e5).toISOString(); const to = new Date(Date.now() + (203 + i * 6) * 864e5).toISOString();
    const made = await sql`select app.submit_booking_request(${sql.json({ request_key: `e2e-refused-${i}-${Date.now()}`, vehicle_id: car!.vehicle_id, pickup_at: from, return_at: to, booking_type: 'standard', coverage_option: 2,
      consents: { terms: { accepted: true, version: 'e2e', text: 'I agree to the Terms of use.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree to the Privacy policy.' } },
      renter: { email, full_name: 'Robin Refused', mobile: '647-555-0163', date_of_birth: '1990-04-09', licence_class: 'G', licence_issuer: 'ON' } })}::jsonb) as r`;
    expect((made[0]!.r as { ok: boolean }).ok).toBe(true);
  }
  const range = await freeWindow(slug);
  await page.goto(`/book/${slug}?from=${range.from}&to=${range.to}&tf=10:00&tt=10:00`);
  await acceptCookies(page);
  await page.getByRole('button', { name: 'Continue to driver details' }).click();
  await expect(page.getByRole('heading', { name: 'The driver' })).toBeVisible();
  await page.locator('#rq-first').fill('Robin');
  await page.locator('#rq-last').fill('Refused');
  await page.locator('#rq-email').fill(email);
  await page.locator('#rq-phone').fill('647-555-0163');
  await page.locator('#rq-dobm').selectOption('4');
  await page.locator('#rq-dobd').fill('9');
  await page.locator('#rq-doby').fill('1990');
  await page.getByRole('button', { name: 'Continue to licence' }).click();
  await page.locator('label', { hasText: 'Ontario G2' }).click();
  await chooseCardCoverage(page);
  await page.getByRole('button', { name: 'Continue to add-ons' }).click();
  await page.getByRole('button', { name: 'Review request' }).click();
  await page.locator('input[name="agree"]').check();
  await page.getByRole('button', { name: 'Send request' }).click();
  // the exact reason and what to do, never "try again or call us"; the form stays with everything typed
  const failure = page.getByTestId('rq-failure');
  await expect(failure).toContainText('You already have 3 requests open', { timeout: 30_000 });
  await expect(failure).toContainText('Your answers are saved');
  await expect(failure).not.toContainText('call us');
  await expect(page.locator('#rq-first')).toHaveValue('Robin');
  await expect(page.locator('#rq-email')).toHaveValue(email);
  // staff: one row with the reason, the car and the dates, and one Sales To-do; a second try adds to the same row
  const kept = async () => sql`select f.code, f.tries, f.full_name, (f.vehicle_id = ${car!.vehicle_id}) car, (f.pickup_at is not null) dates,
                                     (select count(*)::int from tasks t where t.id = f.task_id and t.queue = 'sales' and t.status = 'open') todo
                                from booking_request_failures f where f.email = ${email}`;
  await expect.poll(async () => (await kept()).length, { timeout: 15_000 }).toBe(1);
  expect((await kept())[0]).toMatchObject({ code: 'too_many_open_requests', tries: 1, full_name: 'Robin Refused', car: true, dates: true, todo: 1 });
  await page.getByRole('button', { name: 'Send request' }).click();
  await expect.poll(async () => (await kept())[0]?.tries, { timeout: 30_000 }).toBe(2);
  expect(await kept()).toHaveLength(1);
  // the draft is on the device and on the server: coming back fills the form in again
  await page.reload();
  await expect(page.getByText('We kept your place')).toBeVisible({ timeout: 10_000 });
  await expect(page.locator('#rq-email')).toHaveValue(email);
  const draft = await sql`select count(*)::int n from form_drafts where form_code = 'booking_request' and submitted_at is null and data ->> 'email' = ${email}`;
  expect(draft[0]!.n).toBeGreaterThan(0);
  await sql.end();
});
