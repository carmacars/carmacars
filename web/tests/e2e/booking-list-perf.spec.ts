import { expect, test } from '@playwright/test';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0102 end to end: the /book car list labels (year, make, model, trim, colour and the from price, a car code
// only between two identical labels, by price), the form rendered on the server with its car and price summary, the
// review step's Edit links on one line at every width, and a request on a sample car offered a real car free for its
// dates (one tap to switch; kept on the enquiry when the renter does not switch).
const SAMPLE = 'bmw-330i';
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;
function range(offsetDays: number) {
  const d = new Date(); d.setUTCDate(d.getUTCDate() + offsetDays);
  const from = d.toISOString().slice(0, 10); d.setUTCDate(d.getUTCDate() + 3);
  return { from, to: d.toISOString().slice(0, 10) };
}

test('the /book car list: one line per car that tells the cars apart, by price', async ({ page }) => {
  const sql = db();
  const want = await sql`select x ->> 'label' label, (x ->> 'from_cents')::int c from jsonb_array_elements(public.booking_cars()) x`;
  await sql.end();
  await page.goto('/book');
  await acceptCookies(page);
  const labels = (await page.locator('#rq-car option').allInnerTexts()).slice(1);
  expect(labels).toEqual(want.map((r) => r.label));
  expect(new Set(labels).size, 'no two cars read the same').toBe(labels.length);
  for (const l of labels) expect(l).toMatch(/, from \$[\d,]+(\.\d\d)? a day$/);
  const cents = want.map((r) => r.c as number);
  expect(cents).toEqual([...cents].sort((a, b) => a - b));
  // a car whose year is known starts with it
  expect(labels.some((l) => /^20\d\d /.test(l))).toBe(true);
  await noOverflow(page);
});

test('/book/<car>: the form and its car summary come with the page; the price follows the dates', async ({ page }) => {
  const r = range(150 + (isPhone() ? 0 : 5));
  // without JavaScript the server's page already has the form and the car summary (no client-side waterfall)
  const html = await (await page.request.get(`/book/mercedes-benz-c300?from=${r.from}&to=${r.to}`)).text();
  expect(html).toContain('id="rq-car"');
  expect(html).toMatch(/Your request/);
  expect(html).toMatch(/From \$[\d,]+ a day/);
  await page.goto(`/book/mercedes-benz-c300?from=${r.from}&to=${r.to}&tf=10:00&tt=10:00`);
  await acceptCookies(page);
  await expect(page.locator('#rq-car')).toHaveValue('mercedes-benz-c300');
  await expect(page.locator('.req__side .estimate__lines')).toBeVisible({ timeout: 10_000 });
});

test('review step: the Edit links stay on one line at 375, 768, 1024 and 1440', async ({ page }) => {
  test.setTimeout(90_000);
  const r = range(170 + (isPhone() ? 0 : 5));
  await page.goto(`/book/mercedes-benz-c300?from=${r.from}&to=${r.to}&tf=10:00&tt=10:00`);
  await acceptCookies(page);
  // the review step, reached as a renter does (each step checked)
  await page.getByRole('button', { name: 'Continue to driver details' }).click();
  await page.locator('#rq-first').fill('Edie');
  await page.locator('#rq-last').fill('Linewidth');
  await page.locator('#rq-email').fill(`edit.${Date.now()}@example.test`);
  await page.locator('#rq-phone').fill('647-555-0123');
  await page.locator('#rq-dobm').selectOption('3');
  await page.locator('#rq-dobd').fill('12');
  await page.locator('#rq-doby').fill('1988');
  await page.getByRole('button', { name: 'Continue to licence' }).click();
  await page.locator('label', { hasText: 'Ontario G' }).first().click();
  await page.locator('label.option', { hasText: 'Option 2' }).click();
  await page.getByRole('button', { name: 'Continue to add-ons' }).click();
  await page.getByRole('button', { name: 'Review request' }).click();
  for (const width of [375, 768, 1024, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    const edit = page.locator('.req__review button').first();
    await expect(edit).toBeVisible();
    const m = await edit.evaluate((el) => {
      const lh = parseFloat(getComputedStyle(el).lineHeight) || parseFloat(getComputedStyle(el).fontSize) * 1.5;
      return { h: el.getBoundingClientRect().height, lh, rects: el.getClientRects().length };
    });
    expect(m.h, `Edit at ${width}px is one line`).toBeLessThanOrEqual(m.lh + 1);
    expect(m.rects, `Edit at ${width}px`).toBe(1);
    await noOverflow(page);
  }
});

test('a sample car: a real car free for the dates is offered; one tap switches; an enquiry keeps it', async ({ page }, info) => {
  test.setTimeout(120_000);
  const sql = db();
  const r = range(200 + (isPhone() ? 0 : 7));
  const [match] = await sql`select public.sample_car_match((select vehicle_id from vehicle_listings where slug = ${SAMPLE}),
    (${r.from}::date + time '10:00') at time zone 'America/Toronto', (${r.to}::date + time '10:00') at time zone 'America/Toronto') m`;
  const m = match!.m as { slug: string; name: string } | null;
  expect(m, 'the local fleet has a real car like the sample BMW 330i').not.toBeNull();
  await sql`delete from app.rate_limit_hits`;
  try {
    await sql`update vehicles set sample_bookable = false where id = (select vehicle_id from vehicle_listings where slug = ${SAMPLE})`;
    // the car page: the real car, one tap to book it
    await page.goto(`/cars/${SAMPLE}?from=${r.from}&to=${r.to}&tf=10:00&tt=10:00`);
    await acceptCookies(page);
    await expect(page.getByTestId('sample-match')).toContainText(`Good news: we have a ${m!.name} free for your dates`);
    await expect(page.getByTestId('sample-match-switch')).toHaveAttribute('href', new RegExp(`^/book/${m!.slug}\\?from=${r.from}&to=${r.to}`));
    // the form: switch in one tap, with the real price
    await page.goto(`/book/${SAMPLE}?from=${r.from}&to=${r.to}&tf=10:00&tt=10:00`);
    await expect(page.getByTestId('sample-match')).toBeVisible();
    await noOverflow(page);
    await page.getByTestId('sample-match-switch').click();
    await expect(page.locator('#rq-car')).toHaveValue(m!.slug);
    await expect(page.getByTestId('sample-match')).toHaveCount(0);
    await expect(page.locator('.req__car b')).toContainText(m!.name.replace(/^\d{4} /, ''));
    // keeping the example car: the enquiry says a similar car is waiting
    await page.locator('#rq-car').selectOption(SAMPLE);
    await expect(page.getByTestId('sample-match')).toBeVisible();
    await page.getByRole('button', { name: 'Continue to driver details' }).click();
    const email = `match.${info.project.name}.${Date.now()}@example.test`;
    await page.locator('#rq-first').fill('Mara');
    await page.locator('#rq-last').fill('Matcher');
    await page.locator('#rq-email').fill(email);
    await page.locator('#rq-phone').fill('647-555-0178');
    await page.locator('#rq-dobm').selectOption('4');
    await page.locator('#rq-dobd').fill('2');
    await page.locator('#rq-doby').fill('1987');
    await page.getByRole('button', { name: 'Continue to licence' }).click();
    await page.locator('label', { hasText: 'Ontario G' }).first().click();
    await page.locator('label.option', { hasText: 'Option 2' }).click();
    await page.getByRole('button', { name: 'Continue to add-ons' }).click();
    await page.getByRole('button', { name: 'Review request' }).click();
    await page.locator('input[name="agree"]').check();
    await page.getByRole('button', { name: 'Send request' }).click();
    await page.waitForURL(/\/book\/sent\/EQ-/, { timeout: 30_000 });
    await expect(page.getByTestId('enquiry-match')).toContainText('We have a similar car for your dates; we’ll confirm it within 2 hours');
    const lead = await sql`select id, payload from leads where kind = 'sample_car' and email = ${email}`;
    expect(lead[0]?.payload?.suggested?.slug).toBe(m!.slug);
    const task = await sql`select title from tasks where task_type = 'sample_car_enquiry' and related_id = ${lead[0]!.id}`;
    expect(task[0]?.title).toContain('Free: ');
  } finally {
    await sql`update vehicles set sample_bookable = true where id = (select vehicle_id from vehicle_listings where slug = ${SAMPLE})`;
    await sql.end();
  }
});
