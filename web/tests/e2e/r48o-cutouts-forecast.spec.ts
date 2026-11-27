import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';
import { PW, seedOwner } from './portal-design-seed';

// Release 48 O (docs/changes/2026-11-15-r48o-cutouts-forecast.md), at 375 and 1440:
//   3081: the owner's Home shows the Forecast (the next 12 months of each car, projected occupancy and owner revenue), a
//   statement says whether next month is projected higher or lower and why, and the Admin's view of the owner shows the
//   same Forecast; nothing runs off the screen.
//   3080: the home hero and the photo sections show either their photo or real cars cut out where the sample car stood,
//   inside the section's own box (no sideways scroll, nothing over the text's width).
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' }).catch(() => page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' }));
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(next), { timeout: 60_000 });
  await page.waitForLoadState('networkidle');
}

test('the owner forecast: Home, a statement, and the Admin view of the owner', async ({ page, browser }, info) => {
  test.setTimeout(240_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const errors = watch(page);
  const o = await seedOwner(sql);
  await signIn(page, o.email, '/owner');
  const f = page.getByTestId('owner-forecast');
  await expect(f.getByRole('heading', { name: 'Forecast' })).toBeVisible();
  await expect(f.getByTestId('owner-forecast-car')).toHaveCount(3);
  await expect(f.getByTestId('owner-forecast-total')).toContainText('All 3 cars, the next 12 months');
  const first = f.getByTestId('owner-forecast-car').first();
  await expect(first.locator('tbody tr')).toHaveCount(12);
  await expect(first.locator('tbody tr').first()).toContainText(/\d+%/);
  await expect(first.locator('tbody tr').first()).toContainText(/\$\d/);
  await expect(f).toContainText('Bookings hidden from you are not counted');
  await f.scrollIntoViewIfNeeded();
  await noOverflow(page);

  // the newest statement: next month against its month, and why
  const [st] = await sql`select id from owner_statements where owner_id = ${o.ownerId} and status in ('approved', 'paid') order by statement_month desc limit 1`;
  await page.goto(`/owner/statements/${st!.id}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('statement-forecast')).toHaveText(/^Forecast: next month \(\w+\) is projected (higher|lower|about the same)/);
  await expect(page.getByTestId('statement-forecast')).toContainText(/Why: the season|about the same/);
  await noOverflow(page);

  // the Admin's view of the owner shows the same Forecast
  const admin = randomUUID(); const email = `admin.r48o.${Date.now()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${admin}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${admin}, ${email}, 'Ada Forecast')`;
  await sql`insert into user_roles (user_id, role) values (${admin}, 'admin')`;
  const ctx = await browser.newContext({ viewport: page.viewportSize() ?? undefined, hasTouch: info.project.name.startsWith('phone'), baseURL: info.project.use.baseURL });
  const ap = await ctx.newPage();
  await signIn(ap, email, `/admin/owners/${o.ownerId}`);
  const af = ap.getByTestId('admin-owner-forecast');
  await expect(af.getByTestId('admin-owner-forecast-car')).toHaveCount(3);
  await expect(af).toContainText('Bookings hidden from the owner are not counted');
  await noOverflow(ap);
  await ctx.close();
  expect(errors.filter((e) => !/favicon|Download the React DevTools/.test(e))).toEqual([]);
  await sql.end();
});

test('the home hero and the photo sections stay in their box: real cars only as cutouts where the sample car stood, or the section photo', async ({ page }) => {
  test.setTimeout(120_000);
  const errors = watch(page);
  for (const path of ['/', '/delivery', '/list-your-car', '/cars']) {
    await page.goto(path, { waitUntil: 'networkidle' });
    await acceptCookies(page);
    await noOverflow(page);
    // 5080 (REQ-002): a real car only as its cutout over the section's own photo, never a whole studio photo
    await expect(page.locator('img[src*="/site-plates/"]')).toHaveCount(0);
    await expect(page.locator('[data-testid="slot-car"]:not([src*="site/cutouts/"])')).toHaveCount(0);
    const scenes = page.getByTestId('slot-cars');
    for (let i = 0; i < await scenes.count(); i++) {
      const s = scenes.nth(i);
      const box = await s.boundingBox();
      const parent = await s.locator('xpath=..').boundingBox();
      expect(box && parent && Math.abs(box.width - parent.width) < 2 && Math.abs(box.height - parent.height) < 2, `${path}: the cars fill the section's photo box`).toBeTruthy();
      await expect(s.locator('img').first()).toBeAttached();
    }
  }
  // the hero's text stays readable: its gradient is over the photo
  await page.goto('/', { waitUntil: 'networkidle' });
  const after = await page.locator('.hero__media').evaluate((e) => getComputedStyle(e, '::after').backgroundImage);
  expect(after).toContain('gradient');
  expect(errors.filter((e) => !/favicon|Download the React DevTools/.test(e))).toEqual([]);
});
