import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db } from './helpers';
import { squishScan } from '../../scripts/squish-lib.mjs';

// r48 (docs/changes/2026-11-14-r48-squished-text.md): no squished text. On a representative set of pages (public, Admin, a
// staff role, the field guide inside its phone frame, a renter) at 375 and 1440: no word broken letter by letter, no label
// with one word a line, no short button or chip wrapping, no label cut off by its own box, no table cell crushed, no text past
// the window. The same check runs over every page and role at 320, 375, 768 and 1440 with scripts/squish-audit.mjs.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function person(role: 'admin' | 'cs' | 'field' | 'renter') {
  const sql = db();
  const id = randomUUID(); const email = `squish.${role}.${Date.now()}.${Math.floor(Math.random() * 1e4)}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') await sql`select public.register_account(${id}, ${email}, 'Sam Renter', null)`;
  else {
    await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Sam Staff')`;
    await sql`insert into user_roles (user_id, role) values (${id}, ${role === 'cs' ? 'va' : role})`;
    if (role === 'cs') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, cover_functions) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'cs', '{}'::va_function[])`;
    if (role === 'field') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver')`;
  }
  await sql.end();
  return email;
}
async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('#si-email').fill(email);
  await page.locator('#si-pass').fill(PW);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 30_000 });
}
async function check(page: Page, url: string) {
  await page.goto(url, { waitUntil: 'load' });
  await page.waitForTimeout(800); // the portals poll, so the network never goes idle
  // a portal may reload itself once after load (a live update, a fresh build): scan the page it settles on
  const hits = await page.evaluate(squishScan).catch(async (e: unknown) => {
    if (!/context was destroyed|navigat/i.test(String(e))) throw e;
    await page.waitForLoadState('load'); await page.waitForTimeout(800);
    return page.evaluate(squishScan);
  });
  expect(hits.map((h) => `${url} ${h.kind}: ${h.sel} "${h.text}" ${h.extra}`), `squished text on ${url}`).toEqual([]);
}

test('squished text: public pages', async ({ page }) => {
  test.setTimeout(120_000);
  await page.goto('/', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  for (const url of ['/', '/cars', '/cars/mercedes-benz-c300', '/book/mercedes-benz-c300', '/faq', '/contact', '/requirements', '/credit-card-rental-coverage', '/body-shop', '/sign-in']) await check(page, url);
});

test('squished text: Admin, staff, field and renter portals', async ({ browser }) => {
  test.setTimeout(240_000);
  const base = test.info().project.use;
  const visit = async (role: 'admin' | 'cs' | 'field' | 'renter', urls: string[]) => {
    const ctx = await browser.newContext({ viewport: base.viewport ?? { width: 375, height: 812 }, baseURL: base.baseURL, reducedMotion: 'reduce' });
    const page = await ctx.newPage();
    await signIn(page, await person(role));
    for (const url of urls) await check(page, url);
    await ctx.close();
  };
  await visit('admin', ['/admin', '/admin/bookings', '/admin/field-jobs', '/admin/vehicles', '/admin/staff', '/admin/settings/guides/renter']);
  await visit('cs', ['/staff', '/staff/guide', '/staff/card-coverage']);
  await visit('field', ['/staff/field', '/staff/field/guide', '/staff/field/profile']);
  await visit('renter', ['/account', '/account/guide', '/account/notifications']);
});
