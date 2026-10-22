import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { db, noOverflow } from './helpers';

// Migration 0088 end to end, at 375 and 1440: Turo emails find their car by themselves. Two identical real cars (the
// same make, model, year and colour, no name on Turo typed): a Turo email naming that model waits as "Which car is
// this?"; To do offers "Choose the car"; the pop-up lists the two best guesses first (colour, the plate's last 3); one
// click adds the trip, checks the email and teaches the car its Turo car number, so the next email for that car (another
// trip) is applied by itself. The guest's name and phone show on the trip.
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
const jobToken = () => {
  const env = readFileSync(path.join(process.cwd(), '.env.local'), 'utf8');
  return createHmac('sha256', /^LINK_SIGNING_KEY=(.*)$/m.exec(env)![1]!.trim()).update('carmacars-listing-worker-v1').digest('hex');
};
const fmt = (d: Date) => new Intl.DateTimeFormat('en-US', { timeZone: 'America/Toronto', weekday: 'short', month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' }).format(d).replace(/,(?= \d{1,2}:)/, '');

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
async function admin(sql: Sql) {
  const id = randomUUID(); const email = `admin.turosmart.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Ada Admin ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await b.isVisible().catch(() => false)) await b.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
}
async function forward(page: Page, raw: string) {
  const r = await page.request.post('/api/inbound/turo', { data: raw, headers: { authorization: `Bearer ${jobToken()}`, 'content-type': 'message/rfc822',
    'x-envelope-from': 'rent+caf_=trips=in.carmacars.ca@carmacars.ca' } });
  expect(r.status()).toBe(200);
  return (await r.json()) as { ok: boolean; status: string; reason?: string; audit?: string; id?: string };
}
/** A Turo "booked" email in HTML: the car's Turo page link (its Turo car number), the guest and their phone. */
const booked = (o: { id: string; car: string; turoCar: string; trip: string; start: Date; end: Date; guest: string; phone: string }) => `From: Turo <noreply@mail.turo.com>
To: rent@carmacars.ca
Subject: ${o.guest.split(' ')[0]} booked your ${o.car}
Date: ${new Date().toUTCString()}
Message-ID: <${o.id}@mail.turo.com>
MIME-Version: 1.0
Content-Type: text/html; charset="UTF-8"

<html><body><h1>${o.guest} booked your ${o.car}</h1>
<table><tr><td>Trip start</td><td>${fmt(o.start)}</td></tr><tr><td>Trip end</td><td>${fmt(o.end)}</td></tr>
<tr><td>Car</td><td><a href="https://turo.com/ca/en/car-rental/canada/toronto-on/volkswagen/x/${o.turoCar}">${o.car}</a></td></tr>
<tr><td>Guest</td><td>${o.guest}</td></tr><tr><td>Reservation ID</td><td>${o.trip}</td></tr></table>
<p>Message ${o.guest.split(' ')[0]} at ${o.phone} if plans change.</p>
<p><a href="https://turo.com/ca/en/reservation/${o.trip}">View trip details</a></p></body></html>
`;

test.describe.configure({ mode: 'serial' });

test('Turo emails find their car by themselves: "Which car is this?" once, then the car is known', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const a = await admin(sql);
  // two identical real cars of a model no other car has (one model per width, so both widths can run at once)
  const model = isPhone() ? 'Golf' : 'Passat';
  const [owner] = await sql`select owner_id from vehicles where is_sample order by created_at limit 1`;
  const plates = [`TS${tag().toUpperCase()}`, `TS${tag().toUpperCase()}`];
  await sql`update vehicles set retired_at = now() where make = 'Volkswagen' and model = ${model} and retired_at is null`;
  const cars: Array<{ id: string }> = [];
  for (const plate of plates) {
    const [c] = await sql`insert into vehicles (owner_id, year, make, model, trim, colour, plate, status) values (${owner!.owner_id}, 2021, 'Volkswagen', ${model}, 'Comfortline', 'Black', ${plate}, 'onboarding') returning id`;
    cars.push(c as { id: string });
  }
  const carName = `Volkswagen ${model} 2021`;
  const turoCar = String(7_000_000 + Math.floor(Math.random() * 900_000));
  const trip = String(60_000_000 + Math.floor(Math.random() * 9_000_000));
  const start = new Date(Date.now() + (500 + Math.floor(Math.random() * 100) * 7) * 86_400_000); start.setUTCHours(15, 0, 0, 0);
  const end = new Date(start.getTime() + 2 * 86_400_000);

  const page = await ctx(browser);
  await signIn(page, a.email);

  // the email cannot tell the two apart: it waits as "Which car is this?", with both cars as the best guesses
  const r1 = await forward(page, booked({ id: `ts-${trip}-1`, car: carName, turoCar, trip, start, end, guest: 'Noor H.', phone: '+1 (416) 555-0177' }));
  expect(`${r1.status} ${r1.reason}`).toMatch(/^review Which car: matches 2 cars/);
  const [e1] = await sql`select id, candidates from turo_inbound_emails where message_id = ${`ts-${trip}-1@mail.turo.com`}`;
  expect((e1!.candidates as Array<{ vehicle_id: string }>).map((c) => c.vehicle_id).sort()).toEqual(cars.map((c) => c.id).sort());

  // To do: "which car is this?" with its button to the pop-up
  await page.goto('/admin', { waitUntil: 'networkidle' });
  const todo = page.getByTestId('todo-turo_emails');
  await expect(todo).toContainText('Turo emails: which car is this?');
  await expect(todo.getByRole('link', { name: 'Choose the car' })).toHaveAttribute('href', /^\/admin\/calendar-sync\?pick=[0-9a-f-]{36}#turo-review$/);
  await check(page, 'admin to do with a Turo email to place');

  // the pop-up (opened by the link's pick=), best guesses first, one click
  await page.goto(`/admin/calendar-sync?pick=${e1!.id}#turo-review`, { waitUntil: 'networkidle' });
  const dlg = page.getByTestId('turo-which-car');
  await expect(dlg).toBeVisible();
  await expect(dlg.getByRole('heading', { name: 'Which car is this?' })).toBeVisible();
  await expect(dlg).toContainText(carName);
  await expect(dlg).toContainText('Noor H.');
  const guesses = dlg.getByTestId('turo-which-guess');
  await expect(guesses).toHaveCount(2);
  await expect(guesses.first()).toContainText('black');
  await check(page, 'the Which car is this? pop-up');
  const second = plates[1]!.slice(-3);
  await guesses.filter({ hasText: `plate ends ${second}` }).click();
  await expect(dlg).toBeHidden({ timeout: 15_000 });
  await expect(page.getByTestId('turo-msg')).toContainText('trip added, and remembered for this car', { timeout: 15_000 });
  const [res] = await sql`select e.status, e.method, t.vehicle_id, t.guest_name, t.guest_phone from turo_inbound_emails e join turo_calendar_trips t on t.id = e.turo_trip where e.id = ${e1!.id}`;
  expect(`${res!.status} ${res!.method} ${res!.vehicle_id} ${res!.guest_name} ${res!.guest_phone}`).toBe(`resolved staff ${cars[1]!.id} Noor H. +14165550177`);
  const [learned] = await sql`select vehicle_id, source from turo_identities where kind = 'turo_car_id' and value = ${turoCar}`;
  expect(`${learned!.vehicle_id} ${learned!.source}`).toBe(`${cars[1]!.id} staff`);
  // the car shows what it learned and the trip with the guest
  const tc = page.getByTestId(`turo-car-${cars[1]!.id}`);
  await expect(tc.getByTestId('turo-learned')).toContainText(`Turo car ${turoCar}`);
  await expect(tc.getByTestId('turo-trips')).toContainText(`Turo trip ${trip} (Noor H., 416-555-0177)`);
  await check(page, 'calendar sync after the car was chosen');

  // the next email for that car (another trip, another guest) is applied by itself, by the learned Turo car number
  const trip2 = String(Number(trip) + 1);
  const r2 = await forward(page, booked({ id: `ts-${trip}-2`, car: carName, turoCar, trip: trip2, start: new Date(start.getTime() + 7 * 86_400_000), end: new Date(end.getTime() + 7 * 86_400_000), guest: 'Sam K.', phone: '(647) 555-0188' }));
  expect(`${r2.status} ${r2.audit}`).toMatch(new RegExp(`^applied Booked: Turo trip ${trip2}, `));
  const [t2] = await sql`select vehicle_id from turo_calendar_trips where trip_id = ${trip2}`;
  expect(t2!.vehicle_id).toBe(cars[1]!.id);

  // clean up: the trips, the cars
  await sql`update turo_calendar_trips set status = 'cancelled' where trip_id in (${trip}, ${trip2})`;
  for (const c of cars) await sql`select app.turo_feed_refresh(${c.id})`;
  await sql`update vehicles set retired_at = now() where id in ${sql(cars.map((c) => c.id))}`;
  await sql.end();
});
