import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Address autofill everywhere (2026-10-24): every address field of the site, one row each, typed into as a person
// would (3 characters and more, after the pause) in the production build, with the maps module's local stand-in in
// place of Google (MAPS_PROVIDER=fake: the sample Toronto landmarks). Each row proves the suggestions appear and that
// choosing one fills the field and, where the form keeps the address in parts, its street, city, province, postal code
// (and coordinates). The quick rental form, the offer composer, the booking edit and Edit renter screens have their
// own tests (another change converts them).
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
type Who = 'public' | 'renter' | 'owner' | 'va' | 'field' | 'admin';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => test.info().project.name.includes('phone');

async function mkUser(sql: Sql, who: Exclude<Who, 'public'>) {
  const id = randomUUID(); const email = `${who}.addr.${Date.now()}.${randomBytes(3).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (who === 'renter') {
    await sql`select public.register_account(${id}, ${email}, 'Riley Renter', null)`;
    await sql`insert into renters (user_id, legal_name, email, mobile, date_of_birth) values (${id}, 'Riley Renter', ${email}, '+14165550142', '1990-05-05') on conflict (user_id) do nothing`;
    return { id, email };
  }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${'Addr ' + who})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${who})`;
  // a sales assistant: Admin > Staff > Sales has their household address
  if (who === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'sales')`;
  if (who === 'field') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver')`;
  if (who === 'owner') await sql`insert into owners (user_id, owner_type, legal_name, status, email) values (${id}, 'individual', 'Olive Owner', 'active', ${email})`;
  return { id, email };
}
async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 20_000 });
}

type Row = {
  name: string; who: Who; path: string | ((ids: Record<string, string>) => string);
  /** records the page needs (the signed-in person's id) */
  setup?: (sql: Sql, userId: string) => Promise<void>;
  cleanup?: (sql: Sql, userId: string) => Promise<void>;
  /** what to press first (a dialog, a choice) */
  open?: (page: Page) => Promise<void>;
  /** the lookup field */
  field: (page: Page) => ReturnType<Page['locator']>;
  query?: string; option?: RegExp;
  /** what the chosen suggestion filled: [locator, value] (a RegExp for the lookup line itself) */
  filled: (page: Page) => Array<[ReturnType<Page['locator']>, string | RegExp]>;
};
const UNION = /Union Station/;
const id = (suffix: string, scope?: string) => (p: Page) => (scope ? p.getByTestId(scope) : p.locator('body')).locator(`[id$="-${suffix}"]`).first();
const dlg = (p: Page) => p.locator('dialog[open]');

const ROWS: Row[] = [
  // the public site and the renter
  { name: 'booking request: delivery address', who: 'public', path: '/book/mercedes-benz-c300',
    open: async (p) => { await p.locator('label.option', { hasText: 'Deliver it to an address' }).click(); },
    field: (p) => p.locator('#rq-addr1'), filled: (p) => [[p.locator('#rq-addr1'), UNION]] },
  { name: 'chauffeur request: pickup', who: 'public', path: '/chauffeur/request', field: (p) => p.locator('#ch-pickup'), filled: (p) => [[p.locator('#ch-pickup'), UNION]] },
  { name: 'chauffeur request: drop-off', who: 'public', path: '/chauffeur/request', field: (p) => p.locator('#ch-dropoff'), query: 'cn tower', option: /CN Tower/, filled: (p) => [[p.locator('#ch-dropoff'), /CN Tower/]] },
  { name: 'list your car: where the car is', who: 'public', path: '/list-your-car', field: (p) => p.locator('#ow-addr'), filled: (p) => [[p.locator('#ow-addr'), UNION]] },
  { name: 'owner application: address in parts', who: 'public', path: '/list-your-car/apply', field: (p) => p.locator('#ap-addr'),
    filled: (p) => [[p.locator('#ap-line1'), '65 Front Street West'], [p.locator('#ap-city'), 'Toronto'], [p.locator('#ap-prov'), 'ON'], [p.locator('#ap-postal'), 'M5J 1E6']] },
  { name: 'renter profile: home address in parts', who: 'renter', path: '/account/profile', field: (p) => p.getByTestId('pt-p-lookup'),
    filled: (p) => [[p.locator('#pt-p-address_line1'), '65 Front Street West'], [p.locator('#pt-p-city'), 'Toronto'], [p.locator('#pt-p-province'), 'ON'], [p.locator('#pt-p-postal_code'), 'M5J 1E6']] },
  // the owner
  { name: 'owner profile: mailing address in parts', who: 'owner', path: '/owner/profile', field: (p) => p.getByTestId('ow-pr-lookup'),
    filled: (p) => [[p.locator('#ow-pr-address_line1'), '65 Front Street West'], [p.locator('#ow-pr-city'), 'Toronto'], [p.locator('#ow-pr-postal_code'), 'M5J 1E6']] },
  // staff
  { name: 'VA profile: home address and postal code', who: 'va', path: '/staff/profile', field: (p) => p.getByTestId('home-address'),
    filled: (p) => [[p.getByTestId('home-address'), UNION], [p.getByTestId('home-postal'), 'M5J 1E6']] },
  // a car out on a move: End the move opens a panel that asks where it is now (the same field as Start a move's From).
  // Until 2026-10-25 the button itself ended the move, so the field vanished on the refresh while it was typed in (the
  // intermittent failure of the sharded run); now only the panel's own button ends it.
  { name: 'field portal: vehicle move, now at', who: 'field', path: '/staff/field',
    setup: async (sql, userId) => { await sql`insert into vehicle_moves (vehicle_id, staff_user_id, purpose, started_at, from_place) select v.id, ${userId}, 'repositioning', now() - interval '1 minute', 'Our location' from vehicles v
      where not exists (select 1 from vehicle_moves m where m.vehicle_id = v.id and m.ended_at is null) order by random() limit 1`; },
    cleanup: async (sql, userId) => { await sql`update vehicle_moves set ended_at = now(), to_place = 'Our location' where staff_user_id = ${userId} and ended_at is null`; },
    open: async (p) => { await p.getByTestId('move-end').first().click(); await expect(p.locator('#fb-to_place')).toBeVisible(); },
    field: (p) => p.locator('#fb-to_place'), filled: (p) => [[p.locator('#fb-to_place'), UNION]] },
  // Admin
  { name: 'Site settings: business address, city, province, postal code and coordinates', who: 'admin', path: '/admin/settings/site', field: (p) => p.getByTestId('site-business').getByTestId('business_street-lookup'),
    filled: (p) => [[id('business_street', 'site-business')(p), '65 Front Street West'], [id('business_city', 'site-business')(p), 'Toronto'], [id('business_region', 'site-business')(p), 'ON'],
      [id('business_postal_code', 'site-business')(p), 'M5J 1E6'], [id('business_latitude', 'site-business')(p), '43.6453'], [id('business_longitude', 'site-business')(p), '-79.3806']] },
  { name: 'Site settings: mailing address', who: 'admin', path: '/admin/settings/site', field: (p) => p.getByTestId('site-contact').getByTestId('mailing_address-lookup'),
    filled: (p) => [[id('mailing_address', 'site-contact')(p), UNION]] },
  { name: 'Site settings: street address (pickup and returns)', who: 'admin', path: '/admin/settings/site', field: (p) => p.getByTestId('site-contact').getByTestId('street_address-lookup'),
    filled: (p) => [[id('street_address', 'site-contact')(p), UNION]] },
  { name: 'Delivery origin: address and coordinates', who: 'admin', path: '/admin/settings/airports', field: (p) => p.getByTestId('delivery').getByTestId('company_address-lookup'),
    filled: (p) => [[id('company_address', 'delivery')(p), UNION], [id('company_latitude', 'delivery')(p), '43.6453'], [id('company_longitude', 'delivery')(p), '-79.3806']] },
  { name: 'Partners: add a partner, street, city and postal code', who: 'admin', path: '/admin/partners', open: async (p) => { await p.getByTestId('partner-add').click(); },
    field: (p) => dlg(p).getByTestId('address_line1-lookup'), filled: (p) => [[dlg(p).locator('[id$="-address_line1"]'), '65 Front Street West'], [dlg(p).locator('[id$="-city"]'), 'Toronto'], [dlg(p).locator('[id$="-postal_code"]'), 'M5J 1E6']] },
  { name: 'Staff sales: home address and postal code', who: 'admin', path: (ids) => `/admin/staff/${ids.va}/sales`, open: async (p) => { await p.getByTestId('staff-household-set').click(); },
    field: (p) => dlg(p).getByTestId('home_address-lookup'), filled: (p) => [[dlg(p).locator('[id$="-home_address"]'), UNION], [dlg(p).locator('[id$="-home_postal_code"]'), 'M5J 1E6']] },
  { name: 'Tolls and tickets: place', who: 'admin', path: '/admin/tolls/new', field: (p) => p.getByTestId('place-lookup'), filled: (p) => [[p.getByTestId('place-lookup'), UNION]] },
  { name: 'Add an owner\'s car: owner address in parts', who: 'admin', path: '/admin/owners/add-car', open: async (p) => { const n = p.getByTestId('addcar-new-owner'); if (await n.count()) await n.first().click(); },
    field: (p) => p.locator('[data-testid$="-oaddr-lookup"]'), filled: (p) => [[p.locator('[id$="-address_line1"]').first(), '65 Front Street West'], [p.locator('[id$="-city"]').first(), 'Toronto'], [p.locator('[id$="-postal_code"]').first(), 'M5J 1E6']] }
];

async function newPage(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  return c.newPage();
}

// one test a field (table driven), so a field that does not fill is named in the run's summary
for (const r of ROWS) {
  test(`address autofill: ${r.name}`, async ({ browser }) => {
    test.setTimeout(90_000);
    const sql = db();
    // the daily lookup cap (0113) counts every address test in this job's database: not what is tested here
    await sql`update program_settings set maps_daily_cap_autocomplete = 10000, maps_daily_cap_place_details = 10000`;
    const page = await newPage(browser);
    const ids: Record<string, string> = {};
    let uid = '';
    if (r.who !== 'public') { const u = await mkUser(sql, r.who); uid = u.id; await r.setup?.(sql, u.id); await signIn(page, u.email); }
    else { await page.goto('/', { waitUntil: 'networkidle' }); await acceptCookies(page); }
    if (typeof r.path !== 'string') ids.va = (await mkUser(sql, 'va')).id;
    const asked: string[] = [];
    page.on('request', (q) => { if (q.url().includes('/api/address?')) asked.push(q.url()); });
    await page.goto(typeof r.path === 'string' ? r.path : r.path(ids), { waitUntil: 'networkidle' });
    if (r.open) await r.open(page);
    const f = r.field(page);
    await f.scrollIntoViewIfNeeded();
    // typed as a person types: a key at a time
    await f.click();
    await f.fill('');
    await f.pressSequentially(r.query ?? 'union station', { delay: 20 });
    const opt = page.getByRole('option', { name: r.option ?? UNION }).first();
    await expect(opt, 'a suggestion appears').toBeVisible({ timeout: 10_000 });
    await opt.click();
    for (const [loc, v] of r.filled(page)) await expect(loc, 'filled from the suggestion').toHaveValue(v, { timeout: 10_000 });
    // the field asked sparingly: one suggestion request for the whole word (the pause), never one a key
    expect(asked.length, 'suggestion requests').toBeLessThanOrEqual(3);
    await noOverflow(page);
    await page.context().close();
    if (uid) await r.cleanup?.(sql, uid);
    await sql.end();
  });
}

test('the address API: suggestions, the place in parts with coordinates, and who answered', async ({ request }) => {
  const s = await (await request.get('/api/address?q=union%20station&s=e2e-session-0001')).json();
  expect(s.items[0].label).toMatch(UNION);
  expect(s.limited).toBe(false);
  expect(s.via).toBe('fake');
  const p = await (await request.get(`/api/address/place?id=${s.items[0].id}&s=e2e-session-0001`)).json();
  expect(p.place.parts).toMatchObject({ street: '65 Front Street West', city: 'Toronto', province: 'ON', postal_code: 'M5J 1E6' });
  expect(p.place.lat).toBeCloseTo(43.6453); expect(p.place.lng).toBeCloseTo(-79.3806);
  // under 3 characters: Google is never asked
  expect((await (await request.get('/api/address?q=un')).json()).items).toEqual([]);
});
