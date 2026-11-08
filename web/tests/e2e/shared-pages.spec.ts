import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { acceptCookies, db, noOverflow } from './helpers';

// r31 "Simple": one page per object for Admin and staff (features/booking-page, vehicle-page, listing-page). The Admin
// and staff addresses render the same component; each staff function sees what it saw on its own copy, and an Admin
// keeps everything. Every role (Admin, Sales, customer service, Fleet, Finance, field) opens the same booking in each
// section, the same car and the same listing; the parts each role must and must not get are checked, at 375 and 1440.
// FINGERPRINT_OUT=<file> also writes what each role saw (test ids, headings, buttons), to compare two builds.
const PW = 'correct horse battery';
const SHOTS = 'test-results/shared-pages';
mkdirSync(SHOTS, { recursive: true });
type Sql = ReturnType<typeof db>;
type Role = 'admin' | 'sales' | 'cs' | 'fleet' | 'finance' | 'field';
const ROLES: Role[] = ['admin', 'sales', 'cs', 'fleet', 'finance', 'field'];
const SECTIONS = ['overview', 'money', 'documents', 'car', 'activity', 'extras'];
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function mkUser(sql: Sql, role: Role) {
  const id = randomUUID(); const email = `${role}.sp.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Sp ${role} ${tag()}`})`;
  if (role === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  else if (role === 'field') {
    await sql`insert into user_roles (user_id, role) values (${id}, 'field')`;
    await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver')`;
  } else {
    await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
    await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${role})`;
  }
  return email;
}
async function signedIn(browser: Browser, email: string) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  const page = await c.newPage();
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 20_000 });
  return page;
}
// what a viewer sees in the page's main column: test ids, headings and buttons (numbers, dates and names blanked)
async function seen(page: Page) {
  return page.evaluate(() => {
    const m = document.querySelector('.ad__main') ?? document.body;
    const norm = (s: string | null) => (s ?? '').replace(/\s+/g, ' ').trim().replace(/\d+/g, '#');
    const uniq = (xs: string[]) => [...new Set(xs.filter(Boolean))].sort();
    return {
      ids: uniq([...m.querySelectorAll('[data-testid]')].map((e) => e.getAttribute('data-testid') ?? '').map((x) => x.replace(/[0-9a-f]{8}-[0-9a-f-]{27}|\d+/g, '#'))),
      headings: uniq([...m.querySelectorAll('h1, h2, h3, summary, .ad-card__title, [role="tab"], .ad-tabs a')].map((e) => norm(e.textContent))),
      buttons: uniq([...m.querySelectorAll('button, a.btn')].map((e) => norm(e.textContent)))
    };
  });
}

let fixture: { booking: string; vehicle: string; listing: string | null; paid: boolean } | null = null;
async function pickFixture(sql: Sql) {
  if (fixture) return fixture;
  // a renter's confirmed booking (payments first when the data has them), its car and a listing review of a car
  const [b] = await sql`select b.booking_number, b.vehicle_id, exists (select 1 from payments p where p.booking_id = b.id) as paid from bookings b
    where b.status = 'confirmed' and b.bill_to = 'renter' and b.booking_type <> 'owner' order by 3 desc, b.created_at limit 1`;
  let [l] = await sql`select id from listing_intakes order by created_at limit 1`;
  if (!l) {
    // no listing review in the data yet: one waiting for review on the booking's car
    const [a] = await sql`select user_id from user_roles where role = 'admin' order by user_id limit 1`;
    [l] = await sql`insert into listing_intakes (vehicle_id, started_by, started_role, review_required, state) values (${b!.vehicle_id as string}, ${a!.user_id as string}, 'admin', true, 'needs_review') returning id`;
  }
  fixture = { booking: b!.booking_number as string, vehicle: b!.vehicle_id as string, listing: (l?.id as string | undefined) ?? null, paid: b!.paid as boolean };
  return fixture;
}

const has = (s: { ids: string[] }, id: string) => s.ids.includes(id);
const hasHeading = (s: { headings: string[] }, h: string) => s.headings.some((x) => x.startsWith(h));

test('one booking, vehicle and listing page: each role sees exactly its parts, the staff addresses still open it', async ({ browser }) => {
  test.setTimeout(600_000);
  const sql = db();
  const f = await pickFixture(sql);
  const out: Record<string, unknown> = {};
  for (const role of ROLES) {
    const page = await signedIn(browser, await mkUser(sql, role));
    const portal = role === 'admin' ? '/admin' : '/staff';
    // ---- the booking, every section
    const bookingUrl = `${portal}/bookings/${encodeURIComponent(f.booking)}`;
    if (role === 'field') {
      // field work only: the office pages say so, as before
      await page.goto(bookingUrl, { waitUntil: 'networkidle' });
      expect.soft(new URL(page.url()).pathname, 'field: no office booking page').toBe('/staff/no-access');
      await page.context().close();
      continue;
    }
    const bk: Record<string, Awaited<ReturnType<typeof seen>>> = {};
    for (const s of SECTIONS) {
      const r = await page.goto(`${bookingUrl}?tab=${s}`, { waitUntil: 'networkidle' });
      expect.soft(r?.status(), `${role} booking ${s}`).toBe(200);
      // Sales opens a booking it works on; another says it is not theirs (the database refuses the read)
      await noOverflow(page);
      bk[s] = await seen(page);
    }
    out[`${role} booking`] = bk;
    if (role !== 'sales' || !has(bk.overview!, 'booking-not-yours')) {
    const tabs = bk.overview!.headings;
    // the sections each role gets (shared-pages/viewer bookingTabs)
    expect.soft(hasHeading({ headings: tabs }, 'Money'), `${role}: Money`).toBe(role !== 'fleet');
    if (role !== 'sales') {
    expect.soft(hasHeading({ headings: tabs }, 'Claims & extras'), `${role}: Claims & extras`).toBe(role === 'admin' || role === 'cs');
    // the header buttons
    expect.soft(has(bk.overview!, 'email-renter-link'), `${role}: Email the renter`).toBe(true);
    expect.soft(has(bk.overview!, 'edit-booking'), `${role}: Change the booking`).toBe(role === 'admin' || role === 'cs');
    expect.soft(has(bk.overview!, 'schedule-job'), `${role}: Schedule a field job`).toBe(role === 'fleet');
    expect.soft(has(bk.overview!, 'placeholder-on'), `${role}: Mark as a placeholder`).toBe(role === 'admin');
    // the money: an Admin's New refund, Finance's Request a refund; nobody else asks for one
    expect.soft(has(bk.money!, 'new-refund'), `${role}: New refund`).toBe(role === 'admin' && f.paid);
    expect.soft(has(bk.money!, 'request-refund'), `${role}: Request a refund`).toBe(role === 'finance');
    if (role !== 'admin') expect.soft(has(bk.money!, 'booking-manual-payments'), `${role}: paid another way`).toBe(role === 'finance');
    expect.soft(hasHeading(bk.money!, 'Offers'), `${role}: the offers table`).toBe(role === 'admin');
    // documents: no paper signature card unless one was recorded before 0720 (none here); the full renter documents card for an Admin
    expect.soft(has(bk.documents!, 'booking-paper'), `${role}: signed on paper`).toBe(false);
    expect.soft(has(bk.documents!, 'booking-doc-review') && hasHeading(bk.documents!, 'Renter documents'), `${role}: renter documents`).toBe(role === 'admin');
    // history: the status history and the emails stay with an Admin
    expect.soft(hasHeading(bk.activity!, 'Status history'), `${role}: status history`).toBe(role === 'admin');
    expect.soft(hasHeading(bk.activity!, 'Emails sent'), `${role}: emails sent`).toBe(role === 'admin');
    // claims & extras: the change requests for an Admin and customer service only, even at the old address
    expect.soft(hasHeading(bk.extras!, 'Change requests'), `${role}: change requests`).toBe(role === 'admin' || role === 'cs');
    }
    }
    if (role === 'cs' && !isPhone()) {
      await page.goto(`${bookingUrl}?tab=overview`, { waitUntil: 'networkidle' });
      await page.screenshot({ path: `${SHOTS}/staff-booking-cs-1440.png`, fullPage: true });
    }
    // ---- the car: every tab the role has, together (staff had one page before r31, now the Admin's tabs)
    const carTabs = ['overview', 'rates', 'listing', 'maintenance', 'records'];
    const vr = await page.goto(`${portal}/vehicles/${f.vehicle}`, { waitUntil: 'networkidle' });
    expect.soft(vr?.status(), `${role} vehicle`).toBe(role === 'sales' ? 404 : 200);
    if (role !== 'sales') {
      const v = { ids: [] as string[], headings: [] as string[], buttons: [] as string[] };
      for (const t of carTabs) {
        await page.goto(`${portal}/vehicles/${f.vehicle}?tab=${t}`, { waitUntil: 'networkidle' });
        await noOverflow(page);
        const x = await seen(page);
        out[`${role} vehicle ${t}`] = x;
        v.ids.push(...x.ids); v.headings.push(...x.headings); v.buttons.push(...x.buttons);
      }
      expect.soft(has(v, 'va-rate-form-submit') || has(v, 'rate-form-submit'), `${role}: the rates form`).toBe(role === 'admin' || role === 'fleet');
      expect.soft(has(v, 'va-listing'), `${role}: the staff listing card`).toBe(role === 'cs' || role === 'fleet');
      expect.soft(hasHeading(v, 'Fees for this car'), `${role}: the fees`).toBe(role === 'admin');
      // staff: the maintenance (an Admin has it too, as before)
      if (role !== 'admin') expect.soft(has(v, 'maint-records') || v.headings.some((h) => /service|maintenance/i.test(h)), `${role}: maintenance`).toBe(role === 'fleet' || role === 'finance');
      // an old task link with #maintenance lands on the Maintenance tab
      if (role === 'fleet') {
        await page.goto(`${portal}/vehicles/${f.vehicle}#maintenance`, { waitUntil: 'networkidle' });
        await expect.soft(page).toHaveURL(/[?&]tab=maintenance/, { timeout: 15_000 });
      }
    }
    // ---- the listing review
    if (f.listing) {
      const lr = await page.goto(`${portal}/listings/${f.listing}`, { waitUntil: 'networkidle' });
      const opens = role === 'admin' || role === 'cs' || role === 'fleet';
      expect.soft(lr?.status(), `${role} listing`).toBe(opens ? 200 : 404);
      if (opens) {
        await noOverflow(page);
        const l = await seen(page);
        out[`${role} listing`] = l;
        expect.soft(has(l, 'va-listing-car'), `${role}: the car and its rates`).toBe(role === 'fleet');
      }
    }
    // ---- the shared lists: requests, bookings, renters, add a car for an owner (each role's access as before r31)
    const LISTS: Array<[string, Role[]]> = [['/requests', ['admin', 'cs', 'sales']], ['/bookings', ['admin', 'sales', 'cs', 'fleet', 'finance']], ['/bookings?view=all', ['admin', 'sales', 'cs', 'fleet', 'finance']],
      ['/bookings?q=sample', ['admin', 'sales', 'cs', 'fleet', 'finance']], ['/renters', ['admin', 'cs', 'fleet', 'finance']], ['/renters?q=sample', ['admin', 'cs', 'fleet', 'finance']],
      ['/owners/add-car', ['admin', 'cs', 'fleet', 'sales']]];
    for (const [path, who] of LISTS) {
      const r = await page.goto(`${portal}${path}`, { waitUntil: 'networkidle' });
      const opens = who.includes(role);
      expect.soft(r?.status(), `${role} ${path}`).toBe(opens ? 200 : 404);
      if (opens) { await noOverflow(page); out[`${role} ${path}`] = await seen(page); }
    }
    await page.context().close();
  }
  if (process.env.FINGERPRINT_OUT) writeFileSync(`${process.env.FINGERPRINT_OUT}.${isPhone() ? 375 : 1440}.json`, JSON.stringify(out, null, 1));
  await sql.end();
});
