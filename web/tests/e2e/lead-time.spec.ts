import { expect, test } from '@playwright/test';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Lead-time pricing (migration 0360), at 375 and 1440: with dates chosen, a car page's estimate shows one plain line
// for the adjustment, "Short-notice pricing +10%" for a pickup 24 to 72 hours away and "Booked ahead −5%" for one 14
// days or more away; "From $X a day" stays at the base rate. A car of 01 Motors (0361) is priced from its listed rates
// less 10% like any car of ours.
const MINUS = '−';
const day = (offset: number) => { const d = new Date(Date.now() + offset * 86_400_000); return d.toLocaleDateString('en-CA', { timeZone: 'America/Toronto' }); };

/** A published 01 Motors car free on both windows (with a day either side), and its base rates. */
async function freeCar(windows: Array<[number, number]>) {
  const sql = db();
  try {
    const cars = await sql`select l.slug, v.id, rc.daily_rate_cents, pr.base_cents from vehicles v join vehicle_listings l on l.vehicle_id = v.id and l.status = 'published'
      join partners p on p.id = v.partner_id join partner_rates pr on pr.vehicle_id = v.id
      join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
      where p.business_name = '01 Motors' and v.lead_time_mode = 'program' and not v.insurance_included order by v.partner_sheet_name desc`;
    for (const c of cars) {
      let free = true;
      for (const [a, b] of windows) {
        const [r] = await sql`select count(*)::int n from bookings b where b.vehicle_id = ${c.id} and b.status not in ('declined', 'expired', 'cancelled')
          and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${day(a)}::date::timestamptz, ${day(b)}::date::timestamptz + interval '1 day')`;
        const [k] = await sql`select count(*)::int n from vehicle_calendar_blocks k where k.vehicle_id = ${c.id} and k.removed_at is null
          and tstzrange(k.starts_at - interval '1 day', coalesce(k.ends_at, 'infinity') + interval '1 day') && tstzrange(${day(a)}::date::timestamptz, ${day(b)}::date::timestamptz + interval '1 day')`;
        if (r!.n || k!.n) free = false;
      }
      if (free) return c as unknown as { slug: string; id: string; daily_rate_cents: number; base_cents: number };
    }
    throw new Error('no free 01 Motors car');
  } finally { await sql.end(); }
}

test('the car page estimate shows the lead-time line once dates are chosen', async ({ page }, info) => {
  test.setTimeout(180_000);
  const errors = watch(page);
  const sql = db();
  const [s] = await sql`select lead_time_enabled from program_settings where effective_from <= now() order by effective_from desc limit 1`;
  await sql.end();
  test.skip(!s?.lead_time_enabled, 'lead-time pricing is off in Program settings');
  const car = await freeCar([[2, 4], [20, 22]]);
  // our base rate is the listed rate less 10%, to the dollar
  expect(car.daily_rate_cents).toBe(Math.round((car.base_cents * 9000) / 1_000_000) * 100);

  // 2 days ahead at 10:00: 24 to 72 hours, +10%
  await page.goto(`/cars/${car.slug}?from=${day(2)}&to=${day(4)}&tf=10:00&tt=10:00`);
  await acceptCookies(page);
  const lines = page.locator('.estimate__lines');
  await expect(lines).toContainText('Rental charge', { timeout: 30_000 });
  const near = lines.locator('tr', { hasText: 'Short-notice pricing +10%' });
  await expect(near).toHaveCount(1);
  await expect(lines).not.toContainText('Booked ahead');
  // the line comes right after the rental charge, before the HST
  const heads = await lines.locator('tbody th').allTextContents();
  expect(heads.findIndex((h) => h.startsWith('Short-notice pricing'))).toBe(heads.findIndex((h) => h.startsWith('Rental charge')) + 1);
  await noOverflow(page);
  await page.screenshot({ path: `test-results/lead-time-near-${info.project.name}.png`, fullPage: false });

  // 20 days ahead: 14 days or more, -5%
  await page.goto(`/cars/${car.slug}?from=${day(20)}&to=${day(22)}&tf=10:00&tt=10:00`);
  await expect(lines).toContainText('Rental charge', { timeout: 30_000 });
  await expect(lines.locator('tr', { hasText: `Booked ahead ${MINUS}5%` })).toHaveCount(1);
  await expect(lines).not.toContainText('Short-notice pricing');
  await noOverflow(page);
  expect(errors.filter((e) => !/favicon|Failed to load resource.*404/.test(e))).toEqual([]);
});
