import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0073 end to end: a real car (a 2022 Chevrolet Malibu LS like the owner's first) published without photos
// renders exactly like a sample car: the same sections and menu, the samples' heading and key specs, no "Example car",
// a short blurb with nothing about where the car is kept, selling features instead of specs, the eight studio
// stand-ins with MALIBU behind the car and a quiet "Representative photo" note, the drive in the JSON-LD, and its old
// address answering 301 to the clean one.
const SAMPLE = 'toyota-camry';
const VIN_CHARS = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789';
const vin = () => Array.from(randomBytes(17), (b) => VIN_CHARS[b % VIN_CHARS.length]).join('');

async function layout(page: Page) {
  return {
    sections: await page.locator('.car-body .car-sec').evaluateAll((els) => els.map((e) => e.id)),
    menu: await page.locator('.car-nav a').allInnerTexts(),
    heading: await page.locator('h1.car-top__name').evaluate((e) => `${e.className}|${e.children.length}|${e.children[0]?.tagName}`),
    keyspecs: await page.locator('.keyspecs dt').allInnerTexts(),
    gallery: await page.locator('.gallery__track img').count(),
    specRows: await page.locator('#specs table.spec th').allInnerTexts()
  };
}

test('a real car without photos looks like a sample car', async ({ page, request }) => {
  test.setTimeout(120_000);
  const sql = db();
  const vid = randomUUID(); const admin = randomUUID(); const v = vin();
  await sql`insert into users (id, email, full_name) values (${admin}, ${`admin.realfmt.${Date.now()}@example.test`}, 'Rae Admin')`;
  await sql`insert into user_roles (user_id, role) values (${admin}, 'admin')`;
  const [o] = await sql`select id from owners where kind = 'program' order by created_at limit 1`;
  await sql`insert into vin_decodes (vin, provider, ok, raw, year, make, model, trim, body_class, fuel, drivetrain, transmission, doors, seats)
            values (${v}, 'vpic', true, ${sql.json({ BodyClass: 'Sedan/Saloon', DriveType: 'FWD/Front-Wheel Drive', Turbo: 'Yes', KeylessIgnition: 'Standard', RearVisibilitySystem: 'Standard', BlindSpotMon: 'Optional' })},
                    2022, 'Chevrolet', 'Malibu', 'LS (1LS)', 'Sedan/Saloon', 'gasoline', 'FWD/Front-Wheel Drive', 'Continuously Variable Transmission (CVT)', 4, 5)`;
  await sql`insert into vehicles (id, owner_id, year, make, model, trim, colour, vin, plate, class, status, management_mode, onboarding_method, body_type)
            values (${vid}, ${o!.id}, 2022, 'Chevrolet', 'Malibu', 'LS', 'Black', ${v}, ${'RF' + randomBytes(2).toString('hex').toUpperCase()}, 'standard', 'available', 'managed', 'transfer', 'Sedan/Saloon')`;
  await sql`select app.ensure_listing(${vid})`;
  await sql`update vehicle_listings set body_style = 'Sedan/Saloon', transmission = 'Continuously Variable Transmission (CVT)', drivetrain = 'FWD/Front-Wheel Drive', seats = 5, doors = 4, home_area = 'Pickering' where vehicle_id = ${vid}`;
  const [pub] = await sql`select app.listing_publish_now(${admin}, ${sql.json({ vehicle_id: vid })}) r`;
  const slug = (pub!.r as { slug: string }).slug;
  try {
    expect(slug).toMatch(/^2022-chevrolet-malibu-ls(-black)?(-[a-f0-9]{4,})?$/);

    await page.goto(`/cars/${SAMPLE}`);
    await acceptCookies(page);
    const sample = await layout(page);
    await page.goto(`/cars/${slug}`);
    const real = await layout(page);
    expect(real.sections).toEqual(sample.sections);
    expect(real.menu).toEqual(sample.menu);
    expect(real.heading).toEqual(sample.heading);
    expect(real.keyspecs).toEqual(sample.keyspecs);
    expect(real.gallery).toBe(8);
    expect(real.specRows.filter((x) => !['Consumption', 'Luggage'].includes(x))).toEqual(sample.specRows.filter((x) => !['Consumption', 'Luggage'].includes(x)));

    await expect(page.locator('h1')).toHaveText('Chevrolet Malibu');
    await expect(page.locator('.car-top').getByTestId('example-car-badge')).toHaveCount(0);
    await expect(page.getByTestId('example-car-note')).toHaveCount(0);
    await expect(page.locator('.keyspecs')).toContainText('Auto');
    await expect(page.locator('#specs')).toContainText('Front-wheel drive');
    await expect(page.locator('#specs')).not.toContainText('Sedan/Saloon');
    const blurb = await page.locator('.car-top__blurb').allInnerTexts();
    expect(blurb.join(' ')).not.toMatch(/Pickering|kept in|This car is/);
    expect(blurb.join(' ').split(/\s+/).length).toBeLessThanOrEqual(40);
    const feats = await page.locator('#specs .featlist li').allInnerTexts();
    expect(feats.length).toBe(6);
    expect(feats).toContain('Push-button start');
    expect(feats.join('|')).not.toMatch(/seats|Gas fuel|drivetrain/i);
    await expect(page.locator('body')).not.toContainText('Pickering');
    const srcs = await page.locator('.gallery__track img').evaluateAll((els) => els.map((e) => (e as HTMLImageElement).getAttribute('src')));
    expect(srcs[0]).toBe('/sample-photos/studio/sedan/black/lead/MALIBU.svg');
    expect(srcs.every((s) => s!.startsWith('/sample-photos/studio/sedan/black/'))).toBe(true);
    await expect(page.getByTestId('sample-photo-caption').first()).toHaveText('Representative photo');
    const ld = await page.locator('script[type="application/ld+json"]').allInnerTexts();
    expect(ld.join('')).toContain('FrontWheelDriveConfiguration');
    // built from the car and its price, exactly as for the sample cars (the copy's own title is not used)
    expect(await page.title()).toMatch(/2022 Chevrolet Malibu.* in Toronto.*\$\d+ a day \| CarmaCars$/);

    const svg = await request.get('/sample-photos/studio/sedan/black/lead/MALIBU.svg');
    expect(svg.status()).toBe(200);
    expect(svg.headers()['content-type']).toContain('image/svg+xml');
    const body = await svg.text();
    expect(body).toContain('>MALIBU</text>');
    expect(body).toContain('REPRESENTATIVE PHOTO');
    expect(body).not.toContain('STAND-IN');
    expect((await request.get('/sample-photos/studio/boat/black/lead/MALIBU.svg')).status()).toBe(404);

    await noOverflow(page);
    const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
    expect(r.violations.filter((x) => x.impact === 'serious' || x.impact === 'critical').map((x) => x.id)).toEqual([]);

    // an address in the old format answers 301 to the clean one
    const old = `${slug}-old-${randomBytes(2).toString('hex')}`;
    await sql.begin(async (tx) => {
      await tx`select set_config('app.listing_slug_move', ${vid}, true)`;
      await tx`update vehicle_listings set slug = ${old} where vehicle_id = ${vid}`;
    });
    const [moved] = await sql`select app.listing_move_to_clean_slug(${vid}) s`;
    expect(moved!.s).toBe(slug);
    await page.goto(`/cars/${old}`);
    await expect(page).toHaveURL(new RegExp(`/cars/${slug}$`));
  } finally {
    await sql`update vehicle_listings set status = 'unpublished' where vehicle_id = ${vid}`;
    await sql.end();
  }
});
