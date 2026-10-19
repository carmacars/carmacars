import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0062 end to end, at 375 and 1440. Calendar sync: Fleet pastes a calendar link into a car (here the
// CarmaCars link of another car, which carries a block far in the future), "Sync now" reads it, the trip blocks the
// car (availability, the public calendar and search follow at once), the car's own link answers an iCal file with
// "Booked" only, a new link ends the old one, removing the link frees the car. A clash with a confirmed booking shows
// on the Admin To do and Calendar sync. Recovery: a renter opens an offer and does not answer; the recovery job
// queues one reminder; she approves the offer and the reminder still waiting is not sent. Site check: three failures
// open one alert (To do, Site health, one email to the alert address of Program settings, a test address here),
// a fourth sends nothing more, and a pass resolves it with one recovery email.
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;

const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
async function account(sql: Sql, role: 'admin' | 'fleet' | 'renter') {
  const id = randomUUID(); const email = `${role}.cal.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, ${`Rhea Recover ${tag()}`}, null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${role === 'admin' ? `Ada Admin ${tag()}` : `Fen Fleet ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role === 'admin' ? 'admin' : 'va'})`;
  if (role === 'fleet') await sql`insert into staff_profiles (user_id, staff_type, va_function, home_address, home_postal_code) values (${id}, 'va', 'fleet', '1 Fleet Lane, Toronto', 'M6P 1Z2')`;
  return { id, email };
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await b.isVisible().catch(() => false)) await b.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
}
/** Two public cars of their own for each width (the two widths run at the same time). */
async function twoCars(sql: Sql) {
  const rows = await sql`select v.id, l.slug, x.token from vehicles v join vehicle_listings l on l.vehicle_id = v.id join vehicle_calendar_exports x on x.vehicle_id = v.id
    where l.status = 'published' order by l.slug`;
  const off = isPhone() ? 0 : 2;
  return { a: rows[off]!, b: rows[off + 1]! };
}
const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);

test.describe.configure({ mode: 'serial' });

test('Calendar sync: Fleet adds a calendar link, its trip blocks the car at once, the export link answers "Booked" only, rotate and remove', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const fleet = await account(sql, 'fleet');
  const { a, b } = await twoCars(sql);
  // a block far ahead on car A (a day of its own per width); car A's CarmaCars link carries it as "Booked"
  // (within the 18 months a calendar link covers)
  const start = new Date(Date.now() + (300 + (isPhone() ? 0 : 7) + Math.floor(Math.random() * 15) * 14) * 86_400_000);
  start.setUTCHours(14, 0, 0, 0);
  const end = new Date(start.getTime() + 2 * 86_400_000);
  await sql`delete from calendar_feeds where vehicle_id = ${b.id}`;
  await sql`delete from vehicle_calendar_blocks where vehicle_id = ${a.id} and note = 'e2e calendar sync'`;
  const [blk] = await sql`insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, note) values (${a.id}, 'service', ${start.toISOString()}, ${end.toISOString()}, 'e2e calendar sync') returning id`;
  const base = test.info().project.use.baseURL ?? 'http://localhost:3000';
  const link = `${base}/api/ical/${a.token}.ics?for=all`;

  const page = await ctx(browser);
  page.on('dialog', (d) => { void d.accept(); });
  await signIn(page, fleet.email, '/va');
  if (isPhone()) await page.getByTestId('va-nav').getByRole('button', { name: /^Menu\. You are on/ }).click();
  await page.getByTestId('va-nav').getByRole('button', { name: 'Cars', exact: true }).click();
  await expect(page.getByTestId('va-nav').getByRole('link', { name: 'Calendar sync' })).toBeVisible();
  await page.goto('/va/calendar-sync', { waitUntil: 'networkidle' });
  const car = page.getByTestId(`cs-car-${b.id}`);
  await expect(car).toBeVisible();
  await car.getByText('Add a calendar link').click();
  await car.getByLabel('Platform', { exact: true }).selectOption('other');
  await car.getByTestId('feed-url').fill(link);
  await car.getByTestId('feed-add-submit').click();
  await expect(car.getByTestId('cs-msg')).toContainText(/Added and synced: [1-9]/, { timeout: 30_000 });
  await expect(car.getByTestId('feed-other')).toContainText('Working', { timeout: 15_000 });
  await expect(car.getByTestId('feed-other')).toContainText('Booked');
  await check(page, 'fleet calendar sync');

  // the trip blocks car B at once: availability, the public calendar, search
  const [blocks] = await sql`select count(*)::int n from vehicle_calendar_blocks where vehicle_id = ${b.id} and source = 'external' and removed_at is null and starts_at <= ${start.toISOString()} and ends_at >= ${end.toISOString()}`;
  expect(blocks!.n).toBe(1);
  const inside = [new Date(start.getTime() + 3_600_000).toISOString(), new Date(start.getTime() + 20 * 3_600_000).toISOString()];
  const [av] = await sql`select public.vehicle_is_available(${b.id}, ${inside[0]!}::timestamptz, ${inside[1]!}::timestamptz) as ok`;
  expect(av!.ok).toBe(false);
  const [cal] = await sql`select count(*)::int n from app.public_vehicle_calendar(${b.id}, ${ymd(start)}::date, ${ymd(end)}::date) c where c.unavailable_from <= ${inside[0]!}::timestamptz and c.unavailable_to >= ${inside[1]!}::timestamptz`;
  expect(cal!.n).toBe(1);
  const [srch] = await sql`select count(*)::int n from jsonb_array_elements(to_jsonb(public.search_available(${inside[0]!}::timestamptz, ${inside[1]!}::timestamptz, '{}'::jsonb))) x where x ->> 'vehicle_id' = ${b.id}::text`.catch(() => [{ n: 0 }]);
  expect(srch!.n).toBe(0);

  // car B's own link: a calendar of "Booked" times; the plain link leaves the imported trip out, ?for=all has it
  const plain = await page.request.get(`/api/ical/${b.token}.ics`);
  expect(plain.status()).toBe(200);
  expect(plain.headers()['content-type']).toContain('text/calendar');
  const body = await plain.text();
  expect(body.startsWith('BEGIN:VCALENDAR\r\n')).toBe(true);
  const stamp = start.toISOString().replace(/[-:]/g, '').slice(0, 13);
  expect(body).not.toContain(`DTSTART:${stamp}`);
  const all = await (await page.request.get(`/api/ical/${b.token}.ics?for=all`)).text();
  expect(all).toMatch(/SUMMARY:Booked/);
  expect(all).not.toMatch(/Rhea|e2e calendar sync|CC-\d/);
  // a new link: the old one stops
  await car.getByRole('button', { name: 'Make a new link' }).click();
  await expect(car.getByTestId('cs-msg')).toContainText('New link made', { timeout: 15_000 });
  expect((await page.request.get(`/api/ical/${b.token}.ics`)).status()).toBe(404);
  const [nt] = await sql`select token from vehicle_calendar_exports where vehicle_id = ${b.id}`;
  await expect(car.getByTestId(`export-turo-${b.id}`)).toHaveValue(new RegExp(`/api/ical/${nt!.token}\\.ics\\?for=turo$`));
  expect((await page.request.get(`/api/ical/${nt!.token}.ics?for=turo`)).status()).toBe(200);

  // remove the link: the car is free again
  await car.getByTestId('feed-other').getByRole('button', { name: 'Remove' }).click();
  await expect(car.getByTestId('feed-other')).toHaveCount(0, { timeout: 15_000 });
  const [av2] = await sql`select public.vehicle_is_available(${b.id}, ${inside[0]!}::timestamptz, ${inside[1]!}::timestamptz) as ok`;
  expect(av2!.ok).toBe(true);
  await sql`delete from vehicle_calendar_blocks where id = ${blk!.id}`;
  await sql.end();
});

test('Admin: a clash with a confirmed booking on To do and Calendar sync; the site check opens one alert and recovers', async ({ browser }) => {
  test.skip(isPhone(), 'one width: the site check and the clash are shared state');
  test.setTimeout(120_000);
  const sql = db();
  const admin = await account(sql, 'admin');
  // a calendar link on a car with a confirmed booking, whose platform has a trip over it
  const [bk] = await sql`select b.id, b.booking_number, b.vehicle_id, b.pickup_at, b.return_at from bookings b where b.status = 'confirmed' and b.blocks_calendar and b.return_at > now() order by b.pickup_at limit 1`;
  const [feed] = await sql`insert into calendar_feeds (vehicle_id, platform, url) values (${bk!.vehicle_id}, 'turo', ${`https://turo.example/e2e/${tag()}.ics`}) returning id`;
  await sql`select app.calendar_feed_apply(${feed!.id}, ${sql.json([{ uid: `e2e-${tag()}`, summary: 'Turo trip', starts_at: bk!.pickup_at.toISOString(), ends_at: bk!.return_at.toISOString() }])}::jsonb)`;
  // the site check: alerts go to a test address here, never to the real one
  await sql`update program_settings set uptime_alert_email = 'site.alerts.e2e@example.test'`;
  await sql`update site_alerts set resolved_at = now() where resolved_at is null`;
  for (let i = 0; i < 3; i++) await sql`select app.uptime_record('sign_in', false, 503, 800, 'Answered 503 with Error 1102 (the web host stopped the page)')`;
  await sql`select app.uptime_record('sign_in', false, 503, 800, 'Answered 503 with Error 1102 (the web host stopped the page)')`;
  const [alert] = await sql`select id, emailed from site_alerts where check_key = 'sign_in' and resolved_at is null`;
  const [ev] = await sql`select count(*)::int n from app_events where code = 'staff_site_alert' and entity_id = ${alert!.id}`;
  expect(ev!.n).toBe(alert!.emailed ? 1 : 0);

  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await expect(page.getByTestId('todo-site_alerts')).toContainText('Site problems found by the site check');
  await expect(page.getByTestId('todo-calendar_conflicts')).toContainText('Double bookings with Turo or another platform');
  await expect(page.getByTestId('site-health')).toContainText('Error 1102');
  await expect(page.getByTestId('check-sign_in')).toHaveAttribute('data-status', 'failing');
  await check(page, 'admin to do with site health');
  await page.getByTestId('todo-calendar_conflicts').getByRole('link').click();
  await page.waitForURL(/\/admin\/calendar-sync/);
  await expect(page.getByTestId('cs-clashes')).toContainText(bk!.booking_number);
  await check(page, 'admin calendar sync');

  // the check passes again: resolved, one recovery email (when the alert was emailed), the panel shows it working
  await sql`select app.uptime_record('sign_in', true, 200, 120, 'Answered 200')`;
  const [rec] = await sql`select count(*)::int n from app_events where code = 'staff_site_recovered' and entity_id = ${alert!.id}`;
  expect(rec!.n).toBe(alert!.emailed ? 1 : 0);
  await sql`select app.process_events(1000)`;
  const to = await sql`select distinct to_address from notification_outbox where entity_id = ${alert!.id}`;
  expect(to.map((r) => r.to_address).every((a) => a === 'site.alerts.e2e@example.test')).toBe(true);
  await page.goto('/admin', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('check-sign_in')).toHaveAttribute('data-status', 'ok');
  await expect(page.getByTestId('todo-site_alerts')).toHaveCount(0);

  // clean up: the link goes, the clash closes
  await sql`delete from calendar_feeds where id = ${feed!.id}`;
  await sql`select app.calendar_conflicts_check(${bk!.vehicle_id})`;
  await sql`update program_settings set uptime_alert_email = 'rent@carmacars.ca'`;
  await sql.end();
});

test('Recovery: a renter opens her offer and does not answer; one reminder is queued, and she approves before it goes: it is not sent', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const r = await account(sql, 'renter');
  const [u] = await sql`select full_name from users where id = ${r.id}`;
  const from = new Date(Date.now() + (200 + Math.floor(Math.random() * 150)) * 86_400_000); const to = new Date(from.getTime() + 3 * 86_400_000);
  const [car] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id where l.status = 'published' order by random() limit 1`;
  const req = {
    request_key: randomUUID(), vehicle_id: car!.id, pickup_at: `${ymd(from)}T10:00:00-04:00`, return_at: `${ymd(to)}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' },
    coverage_option: 2, extras: { winter_tire: false, baby_seats: 0 },
    renter: { email: r.email, full_name: u!.full_name, mobile: '+16475550123', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [sub] = await sql`select public.submit_booking_request(${sql.json(req)}, ${`198.51.100.${1 + Math.floor(Math.random() * 250)}`}, 'e2e', ${r.id}) v`;
  const v = sub!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  const staff = await account(sql, 'admin');
  // the offer is open for 4 days (its own expiry reminder would cover its last hours)
  await sql`select app.send_offer(${v.booking_id}, ${staff.id}, null, now() + interval '4 days')`;

  // she opens the offer and leaves without answering (recorded for her own booking page, no analytics needed)
  const page = await ctx(browser);
  await signIn(page, r.email, '/account');
  const sent = page.waitForResponse((x) => x.url().endsWith('/api/t') && x.request().method() === 'POST', { timeout: 20_000 });
  await page.goto(`/account/bookings/${v.booking_number}/offer`, { waitUntil: 'load' });
  await sent;
  await acceptCookies(page).catch(() => undefined);
  let sig: { first_at: Date; dedupe_key: string } | undefined;
  for (let i = 0; i < 30 && !sig; i++) {
    [sig] = (await sql`select first_at, dedupe_key from visitor_signals where kind = 'offer_opened' and booking_id = ${v.booking_id}`) as unknown as Array<{ first_at: Date; dedupe_key: string }>;
    if (!sig) await page.waitForTimeout(500);
  }
  expect(sig, 'the offer signal').toBeTruthy();
  // four hours later, inside the sending hours (9 to 21 in Toronto)
  let at = new Date(sig!.first_at.getTime() + (4 * 60 + 5) * 60_000);
  const hour = Number(new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', hourCycle: 'h23' }).format(at));
  if (hour < 9 || hour >= 21) at = new Date(at.getTime() + ((hour >= 21 ? 24 - hour + 10 : 10 - hour) * 60) * 60_000);
  const [early] = await sql`select app.job_booking_recovery(${new Date(sig!.first_at.getTime() + 60 * 60_000).toISOString()}::timestamptz) as r`;
  expect(early!.r).not.toMatch(/sent [1-9]/);
  await sql`select app.job_booking_recovery(${at.toISOString()}::timestamptz)`;
  // the job and the event processing are shared with the other width's test: wait for the row
  let ob: { id: string; status: string; to_address: string; category: string; n: string } | undefined;
  for (let i = 0; i < 20 && !ob; i++) {
    await sql`select app.process_events(1000)`;
    [ob] = (await sql`select id, status, to_address, category, payload ->> 'booking_number' as n from notification_outbox where code = 'renter_recovery_offer' and booking_id = ${v.booking_id}`) as unknown as typeof ob[];
    if (!ob) await page.waitForTimeout(500);
  }
  expect(`${ob?.status} ${ob?.to_address} ${ob?.category} ${ob?.n}`).toBe(`queued ${r.email} transactional ${v.booking_number}`);

  // she approves the offer before the reminder goes out: the series stops and the reminder is not sent
  await page.goto(`/account/bookings/${v.booking_number}/offer`, { waitUntil: 'networkidle' });
  await page.getByRole('button', { name: 'Approve and continue' }).click();
  await page.waitForURL(/\/sign$/, { timeout: 30_000 });
  await sql`select app.job_booking_recovery(${new Date(at.getTime() + 10 * 60_000).toISOString()}::timestamptz)`;
  const [after] = await sql`select status, status_reason from notification_outbox where id = ${ob!.id}`;
  expect(`${after!.status}: ${after!.status_reason}`).toBe('skipped: Not sent: the offer was answered, expired or withdrawn');
  const [series] = await sql`select count(*)::int n, bool_and(stopped_at is not null) as stopped from recovery_emails where subject_key = ${sig!.dedupe_key}`;
  expect(`${series!.n} ${series!.stopped}`).toBe('1 true');
  await sql.end();
});
