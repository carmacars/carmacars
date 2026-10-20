import { expect, test } from '@playwright/test';
import { acceptCookies, db, noOverflow, watch } from './helpers';

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
  await page.locator('label.option', { hasText: 'Option 2' }).click();
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
  await page.locator('input[name="marketing"]').check();
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
  expect(b.consents).toBe(3); // terms, privacy and the separate marketing opt-in
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
  await page.waitForTimeout(1500); // autosave
  await page.reload();
  await expect(page.getByText('We kept your place')).toBeVisible();
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
  const [bk] = await sql`select (b.return_at at time zone 'America/Toronto')::date::text d from bookings b join vehicle_listings l using (vehicle_id) where l.slug = 'mercedes-benz-c300' and b.status = 'confirmed' and b.return_at > now() + interval '1 day' order by b.return_at limit 1`;
  await sql.end();
  await page.goto('/cars/mercedes-benz-c300');
  await acceptCookies(page);
  // the cookie choice refreshes the page: wait for it to settle before working the calendar
  await page.waitForLoadState('networkidle');
  // the day a booking ends is free from 2 hours after its return (the turnaround)
  const day = page.locator(`.cal [data-date="${bk!.d}"]`);
  await expect(async () => { await page.locator('#dates').scrollIntoViewIfNeeded({ timeout: 2_000 }); }).toPass({ timeout: 15_000 });
  for (let i = 0; i < 4 && !(await day.count()); i++) await page.getByRole('button', { name: 'Next month' }).first().click();
  await expect(day).toHaveClass(/is-part/);
  await expect(day).toHaveAttribute('aria-label', /partly available, free from 12:00 p.m./);
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
