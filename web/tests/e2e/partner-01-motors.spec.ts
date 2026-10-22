import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Migration 0093 end to end, at 375 and 1440: a car of the partner fleet (01 Motors) shows its badges, its tiers (1 to
// 2 days, 3 to 6, 7 or more), the guideline note and "Year confirmed when you book"; a request on a car with insurance
// included and no credit card needed skips the coverage choice and the credit card requirement, and is stored with
// coverage option 4, confirmed; the chauffeur page lists the vehicles and their hourly rates and takes a request.
async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
const slugOf = async (sheet: string) => {
  const sql = db();
  const [r] = await sql`select l.slug from vehicles v join vehicle_listings l on l.vehicle_id = v.id join partners p on p.id = v.partner_id
                        where p.business_name = '01 Motors' and v.partner_sheet_name = ${sheet}`;
  return r!.slug as string;
};
/** A window of 3 days with nothing on the car, at least `start` days ahead. */
async function freeWindow(slug: string, start: number) {
  const sql = db();
  for (let off = start; off < start + 200; off += 5) {
    const d = new Date(); d.setUTCDate(d.getUTCDate() + off);
    const from = d.toISOString().slice(0, 10); d.setUTCDate(d.getUTCDate() + 3);
    const to = d.toISOString().slice(0, 10);
    const [b] = await sql`select count(*)::int n from bookings b join vehicle_listings l using (vehicle_id)
      where l.slug = ${slug} and b.status not in ('declined', 'expired', 'cancelled')
        and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${from}::date::timestamptz, ${to}::date::timestamptz + interval '1 day')`;
    if (b!.n === 0) return { from, to };
  }
  throw new Error('no free window');
}

test('a partner car page shows its badges, tiers, guideline rates and the year note', async ({ page }, info) => {
  test.setTimeout(180_000);
  const errors = watch(page);
  const slug = await slugOf('Mercedes S63 AMG');
  await page.goto(`/cars/${slug}`);
  await acceptCookies(page);
  await expect(page.locator('h1')).toHaveText('Mercedes-Benz S-Class');
  await expect(page.getByTestId('badge-insurance')).toHaveText('Insurance included: no personal auto policy needed');
  await expect(page.getByTestId('badge-no-credit-card')).toHaveText('No credit card needed: debit accepted');
  await expect(page.locator('.car-top .lead')).toContainText('Year confirmed when you book.');
  await expect(page.getByTestId('guideline-note')).toHaveText('Guideline rates; final price confirmed after review.');
  // sheet $700 / $650 / $600 a day, plus 10%: $770, $715, $660
  await expect(page.getByTestId('car-from-price')).toHaveText('$660');
  const tiers = page.getByTestId('rates-tiers');
  await expect(tiers).toContainText('1 to 2 days');
  await expect(tiers).toContainText('$770');
  await expect(tiers).toContainText('3 to 6 days');
  await expect(tiers).toContainText('$715');
  await expect(tiers).toContainText('7 days or more');
  await expect(tiers).toContainText('$660');
  await expect(page.getByTestId('need-card')).toHaveText('No credit card needed: a credit or debit card in your name');
  await expect(page.getByTestId('need-insurance')).toContainText('no personal auto policy needed');
  await expect(page.getByTestId('coverage-included')).toBeVisible();
  await expect(page.locator('#specs')).toContainText('Confirmed when you book');
  await expect(page.locator('#questions')).toContainText('Can I pay for the Mercedes-Benz S-Class with a debit card?');
  await expect(page.locator('#questions')).toContainText('Do I need my own insurance');
  // the JSON-LD names no year it does not know
  const ld = await page.locator('script[type="application/ld+json"]').allTextContents();
  expect(ld.join('')).not.toContain('vehicleModelDate');
  expect(ld.join('')).not.toMatch(/"name":"20\d\d Mercedes-Benz S-Class/);
  await axe(page, `car page ${info.project.name}`);
  // a car of the fleet without the flags follows the normal rules
  await page.goto(`/cars/${await slugOf('Audi A5 Conv')}`);
  await expect(page.getByTestId('car-perks')).toHaveCount(0);
  await expect(page.getByTestId('need-card')).toHaveText('A credit card in your name');
  await expect(page.getByTestId('rates-tiers')).toContainText('$193');
  expect(errors.filter((e) => !/favicon|Failed to load resource.*404/.test(e))).toEqual([]);
});

test('a request on a no-credit-card car with insurance included skips the coverage and credit card requirements', async ({ page }, info) => {
  test.setTimeout(240_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const sheet = info.project.name.startsWith('phone') ? 'Cadillac Escalade ESV' : 'Bentley Bentayga';
  const slug = await slugOf(sheet);
  const range = await freeWindow(slug, 60);
  const email = `p01m.${info.project.name}.${Date.now()}@example.test`;
  await page.goto(`/book/${slug}?from=${range.from}&to=${range.to}&tf=10:00&tt=10:00`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.getByRole('button', { name: 'Continue to driver details' }).click();
  await page.locator('#rq-first').fill('Robin');
  await page.locator('#rq-last').fill('Debit');
  await page.locator('#rq-email').fill(email);
  await page.locator('#rq-phone').fill('647-555-0193');
  await page.locator('#rq-dobm').selectOption('4');
  await page.locator('#rq-dobd').fill('9');
  await page.locator('#rq-doby').fill('1988');
  await page.getByRole('button', { name: 'Continue to licence' }).click();
  await page.locator('label', { hasText: 'Ontario G2' }).click();
  // no coverage choice: the insurance comes with the car, and no credit card is needed
  await expect(page.getByTestId('coverage-included-step')).toContainText('Insurance included');
  await expect(page.getByTestId('coverage-included-step')).toContainText('debit card');
  await expect(page.locator('input[name="coverage"]')).toHaveCount(0);
  await axe(page, `wizard licence ${info.project.name}`);
  await page.getByRole('button', { name: 'Continue to add-ons' }).click();
  await page.getByRole('button', { name: 'Review request' }).click();
  await expect(page.locator('.req')).toContainText('Insurance included with the car');
  await expect(page.locator('.req')).toContainText('No credit card needed: a credit or debit card in your name');
  await page.locator('input[name="agree"]').check();
  await page.getByRole('button', { name: 'Send request' }).click();
  await page.waitForURL(/\/book\/sent\//, { timeout: 90_000 });
  const number = decodeURIComponent(page.url().split('/').pop()!);
  const [b] = await sql`select b.coverage_option, b.coverage_confirmed_at is not null as confirmed, b.rate_applied, b.deposit_cents > 0 as deposit,
      (select c.status from coverage_proofs c where c.booking_id = b.id and c.coverage_option = 4) as proof
    from bookings b where b.booking_number = ${number}`;
  expect(b).toMatchObject({ coverage_option: 4, confirmed: true, rate_applied: 'multi_day', deposit: true, proof: 'confirmed' });
  // the payment accepts a debit card on this car (the same rule the pay step runs)
  const [ok] = await sql`select app.booking_card_ok((select id from bookings where booking_number = ${number}), '{"is_credit": false, "funding": "debit"}') as ok`;
  expect(ok!.ok).toBe(true);
  await sql`update bookings set status = 'declined' where booking_number = ${number} and status = 'requested'`;
});

test('the chauffeur service: the vehicles and hourly rates, and a request', async ({ page }, info) => {
  test.setTimeout(240_000);
  const errors = watch(page);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  await page.goto('/chauffeur');
  await acceptCookies(page);
  await expect(page.locator('h1')).toHaveText('A driver, by the hour.');
  await expect(page.getByTestId('chauffeur-vehicles').locator('li.ch-card')).toHaveCount(11);
  // the S580: $200 and $175 an hour on the sheet, plus 10%
  const s580 = page.getByTestId('chauffeur-mercedes-benz-s580');
  await expect(s580).toContainText('$220');
  await expect(s580).toContainText('$193');
  await expect(s580.getByRole('link', { name: /S-Class S580/ })).toHaveAttribute('href', /^\/cars\//);
  const ld = (await page.locator('script[type="application/ld+json"]').allTextContents()).join('');
  expect(ld).toContain('"@type":"Service"');
  expect(ld).toContain('"unitCode":"HUR"');
  await expect(page.locator('header nav').first()).toContainText('Chauffeur');
  await axe(page, `chauffeur ${info.project.name}`);

  await s580.getByRole('link', { name: /Request the Mercedes-Benz S580/ }).click();
  await page.waitForURL(/\/chauffeur\/request\?vehicle=mercedes-benz-s580/);
  await expect(page.locator('#ch-vehicle option:checked')).toContainText('Mercedes-Benz S580');
  const d = new Date(); d.setUTCDate(d.getUTCDate() + 9);
  await page.locator('#ch-date').fill(d.toISOString().slice(0, 10));
  await page.locator('#ch-time').selectOption('19:30');
  await page.locator('#ch-hours').selectOption('2');
  await expect(page.getByTestId('chauffeur-estimate')).toContainText('2 hours at $220 an hour');
  await page.locator('#ch-hours').selectOption('4');
  // 4 hours at $193: $772, HST 13%: $100.36
  await expect(page.getByTestId('chauffeur-total')).toHaveText('$872.36');
  await page.locator('#ch-pickup').fill('100 Queen Street West, Toronto');
  await page.locator('#ch-dropoff').fill('Toronto Pearson Airport');
  await page.locator('#ch-pax').fill('2');
  await page.locator('#ch-occasion').selectOption('Wedding');
  await page.locator('#ch-name').fill('Jordan Rider');
  const email = `chauffeur.${info.project.name}.${Date.now()}@example.test`;
  await page.locator('#ch-email').fill(email);
  await page.locator('#ch-phone').fill('416-555-0144');
  await axe(page, `chauffeur request ${info.project.name}`);
  await page.getByRole('button', { name: 'Send request' }).click();
  await expect(page.getByTestId('chauffeur-sent')).toContainText(/Request CH-\d+ sent/, { timeout: 90_000 });
  const [r] = await sql`select r.hours, r.renter_cents::int, r.partner_payout_cents::int, l.kind from chauffeur_requests r join leads l on l.id = r.lead_id where r.email = ${email}`;
  expect(r).toMatchObject({ hours: 4, renter_cents: 77200, partner_payout_cents: 56000, kind: 'chauffeur' });
  expect(errors.filter((e) => !/favicon|Failed to load resource.*404|turnstile/i.test(e))).toEqual([]);
});
