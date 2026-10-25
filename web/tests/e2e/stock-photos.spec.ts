import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { acceptCookies, db, noOverflow } from './helpers';

// Licensed stock photos on the vehicle pages (migration 0149, docs/changes/2026-10-24-seo-photos.md), on the fixture
// catalog's Volkswagen Jetta (2019 to 2021): a photo of the 2019 to 2020 generation shows on the model, 2020 year, 2020
// trim and /buy pages with its always-visible credit (author, licence, Wikimedia Commons, with links), the alt text of
// its generation, a srcset, its own width and height (no layout shift) and an ImageObject with license and creditText;
// the 2021 page (a model year off) shows it marked "not the exact year"; a colour page keeps the studio drawing; an
// Admin's Hide takes it off at once (the Jetta then has no photo: the drawing).
// At 375 and 1440, with axe and no sideways scroll. Fixture rows are removed at the end.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = randomBytes(3).toString('hex');
const BASE = `seo-photos/volkswagen/jetta/2019-2020-e2e${tag}`;
// serve.mjs serves the local public bucket from .local-storage/vehicle-public (scripts/serve.mjs)
const STORE = path.join(process.env.LOCAL_STORAGE_DIR ?? path.join(process.cwd(), '.local-storage'), 'vehicle-public');

// one test at a time changes the Jetta's photo
test.describe.configure({ mode: 'serial' });

let id = '';
test.beforeAll(async () => {
  // two small WebP files (a 2 x 1 grey picture, scaled by the browser): the page only needs them to load
  const webp = Buffer.from('UklGRiQAAABXRUJQVlA4IBgAAAAwAQCdASoCAAEAAUAmJaQAA3AA/vuUAAA=', 'base64');
  mkdirSync(path.join(STORE, path.dirname(BASE)), { recursive: true });
  for (const w of [640, 1280]) writeFileSync(path.join(STORE, `${BASE}-${w}.webp`), webp);
  const sql = db();
  await sql`delete from vehicle_stock_photos where make = 'volkswagen' and model = 'jetta'`;
  id = (await sql`insert into vehicle_stock_photos (make, model, year_from, year_to, generation, file_title, source_url, author, licence, licence_url, path, sizes, width, height)
    values ('volkswagen', 'jetta', 2019, 2020, 'Volkswagen Jetta (A7)', 'File:E2E Jetta front.jpg', 'https://commons.wikimedia.org/wiki/File:E2E_Jetta_front.jpg', 'E2E Tester',
            'CC BY-SA 4.0', 'https://creativecommons.org/licenses/by-sa/4.0/', ${BASE}, '{640,1280}', 1280, 853) returning id`)[0]!.id as string;
  await sql.end();
});
test.afterAll(async () => {
  const sql = db();
  await sql`delete from vehicle_stock_photos where make = 'volkswagen' and model = 'jetta'`;
  await sql.end();
  for (const w of [640, 1280]) rmSync(path.join(STORE, `${BASE}-${w}.webp`), { force: true });
});

async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes[0]?.target}`)).toEqual([]);
}
const imageObjects = (page: Page) => page.evaluate(() => [...document.querySelectorAll('script[type="application/ld+json"]')].flatMap((s) => {
  const out: Array<Record<string, unknown>> = [];
  const walk = (x: unknown) => { if (x && typeof x === 'object') { const o = x as Record<string, unknown>; if (o['@type'] === 'ImageObject') out.push(o); Object.values(o).forEach(walk); } };
  walk(JSON.parse(s.textContent ?? 'null'));
  return out;
}));

for (const url of ['/cars/volkswagen/jetta', '/cars/volkswagen/jetta/2020', '/cars/volkswagen/jetta/2020/sportline', '/buy/volkswagen/jetta/2020']) {
  test(`${url}: the generation's photo with its credit, alt text, srcset, size and ImageObject`, async ({ page }) => {
    test.setTimeout(120_000);
    const res = await page.goto(url);
    expect(res?.status(), url).toBe(200);
    await acceptCookies(page);
    const fig = page.getByTestId('stock-photo').first();
    await expect(fig).toBeVisible();
    const img = fig.locator('img');
    await expect(img).toHaveAttribute('alt', 'Volkswagen Jetta of the 2019 to 2020 generation');
    await expect(img).toHaveAttribute('width', '1280');
    await expect(img).toHaveAttribute('height', '853');
    expect(await img.getAttribute('srcset')).toMatch(new RegExp(`${BASE}-640\\.webp 640w, .*${BASE}-1280\\.webp 1280w`));
    await expect.poll(() => img.evaluate((el) => (el as HTMLImageElement).complete && (el as HTMLImageElement).naturalWidth > 0)).toBe(true);
    const credit = fig.getByTestId('photo-credit');
    await expect(credit).toBeVisible();
    await expect(credit).toContainText('Photo: E2E Tester, CC BY-SA 4.0, Wikimedia Commons');
    await expect(credit.getByRole('link', { name: 'E2E Tester' })).toHaveAttribute('href', 'https://commons.wikimedia.org/wiki/File:E2E_Jetta_front.jpg');
    await expect(credit.getByRole('link', { name: 'CC BY-SA 4.0' })).toHaveAttribute('href', 'https://creativecommons.org/licenses/by-sa/4.0/');
    await expect(credit).toContainText('not one of our cars');
    const ld = await imageObjects(page);
    expect(ld.length, 'an ImageObject').toBeGreaterThan(0);
    expect(ld[0]).toMatchObject({ license: 'https://creativecommons.org/licenses/by-sa/4.0/', creditText: 'Photo: E2E Tester, CC BY-SA 4.0, Wikimedia Commons',
      acquireLicensePage: 'https://commons.wikimedia.org/wiki/File:E2E_Jetta_front.jpg', width: 1280, height: 853 });
    expect(String(ld[0]!.contentUrl)).toContain(`${BASE}-1280.webp`);
    expect(await page.locator('meta[property="og:image"]').first().getAttribute('content')).toContain(`${BASE}-1280.webp`);
    await axe(page, url);
  });
}

test('a model year off the generation shows it, marked not the exact year; a colour page keeps the drawing', async ({ page }) => {
  const res = await page.goto('/cars/volkswagen/jetta/2021');
  expect(res?.status()).toBe(200);
  const credit = page.getByTestId('stock-photo').first().getByTestId('photo-credit');
  await expect(credit).toContainText('Photo: E2E Tester, CC BY-SA 4.0, Wikimedia Commons');
  await expect(credit).toContainText('Representative photo of the Volkswagen Jetta, not the exact year');
  await axe(page, '/cars/volkswagen/jetta/2021');
  await page.goto('/cars/volkswagen/jetta/2020/sportline/colour/gold');
  await expect(page.getByTestId('stock-photo')).toHaveCount(0);
});

test('an Admin hides the photo in Settings > Vehicle pages and the page goes back to the studio drawing', async ({ page }) => {
  test.setTimeout(150_000);
  const sql = db();
  const uid = randomUUID(); const email = `admin.sp37.${Date.now()}.${tag}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${uid}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${uid}, ${email}, 'Photo Admin')`;
  await sql`insert into user_roles (user_id, role) values (${uid}, 'admin')`;
  try {
    await page.goto(`/sign-in?next=${encodeURIComponent('/admin/settings/vehicle-pages')}`, { waitUntil: 'networkidle' });
    await acceptCookies(page);
    await page.locator('input[type="email"]').fill(email);
    await page.locator('input[type="password"]').fill(PW);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 30_000 });
    if (!page.url().includes('/admin/settings/vehicle-pages')) await page.goto('/admin/settings/vehicle-pages');
    const card = page.getByTestId('vp-stock-photos');
    await expect(card).toBeVisible();
    await card.getByTestId('stock-make-volkswagen').locator('summary').click();
    await expect(card.getByTestId(`stock-row-${id}`)).toContainText('Photo: E2E Tester, CC BY-SA 4.0, Wikimedia Commons');
    await card.getByTestId(`stock-hide-${id}`).click();
    await expect.poll(async () => (await sql`select status from vehicle_stock_photos where id = ${id}`)[0]?.status, { timeout: 30_000 }).toBe('hidden');
    await page.goto('/cars/volkswagen/jetta/2020');
    await expect(page.getByTestId('stock-photo')).toHaveCount(0);
  } finally {
    await sql`update vehicle_stock_photos set status = 'active' where id = ${id}`;
    await sql`delete from user_roles where user_id = ${uid}`.catch(() => undefined);
    await sql.end();
  }
});
