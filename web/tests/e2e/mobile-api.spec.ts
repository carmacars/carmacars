import { expect, test, type APIRequestContext } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { db } from './helpers';

// The mobile API of the native app (release 48, /api/m/v1; src/features/mobile-api/contract.ts). No browser: the app
// sends JSON with "Authorization: Bearer", so these tests do the same. What they hold: the public catalogue needs no
// session; everything else needs the token and never a cookie; a route runs the website's own action as that person, so
// the same refusals come back in the same words; and nothing here can do what the website would not.
const API = '/api/m/v1';
const PASSWORD = 'correct horse battery staple';
const TURNSTILE = 'XXXX.DUMMY.TOKEN.XXXX';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const day = (n: number) => new Date(Date.now() + n * 86400_000).toISOString().slice(0, 10);

/** An account with a password, made as an import would (the local stand-in for the sign-in service keeps the hash). */
async function account(label: string, role: 'renter' | 'field' = 'renter'): Promise<{ id: string; email: string }> {
  const sql = db();
  const id = randomUUID();
  const email = `app.${label}.${Date.now()}.${id.slice(0, 6)}@example.test`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'App Tester')`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role}::app_role)`;
  if (role === 'field') {
    await sql`insert into staff_profiles (user_id, staff_type, field_function) values (${id}, 'field', 'driver_detailer')`;
    await sql`update staff_profiles set home_address = '1 App Lane, Testville', home_postal_code = 'X9X 9X9', onboarding_exempt = true where user_id = ${id}`;
  }
  await sql`insert into local_auth.users (id, email, password_hash, email_confirmed_at) values (${id}, ${email}, ${hash(PASSWORD)}, now())`;
  await sql.end();
  return { id, email };
}
type Json = { ok: boolean; data?: unknown; code?: string; message?: string; next?: string };
async function call(request: APIRequestContext, method: 'GET' | 'POST' | 'PUT' | 'DELETE', path: string, o: { token?: string; body?: unknown; headers?: Record<string, string> } = {}) {
  const r = await request.fetch(`${API}${path}`, { method, data: o.body === undefined ? undefined : JSON.stringify(o.body), failOnStatusCode: false,
    headers: { 'x-carmacars-app': '1.0.0 ios', ...(o.body === undefined ? {} : { 'content-type': 'application/json' }), ...(o.token ? { authorization: `Bearer ${o.token}` } : {}), ...o.headers } });
  const json = (await r.json().catch(() => ({ ok: false, code: 'not_json' }))) as Json;
  return { status: r.status(), json, data: json.data as unknown, headers: r.headers() };
}
async function signIn(request: APIRequestContext, email: string) {
  const r = await call(request, 'POST', '/auth/sign-in', { body: { email, password: PASSWORD } });
  expect(r.status, r.json.message).toBe(200);
  return r.data as { access_token: string; refresh_token: string; expires_at: number; user: { id: string; email: string } };
}

test('the catalogue is open: settings, the cars, one car with its photos, the price for dates', async ({ request }) => {
  const config = await call(request, 'GET', '/config');
  expect(config.status).toBe(200);
  expect(config.data).toMatchObject({ brand: 'CarmaCars', turnstile: 'fake', payments: 'fake', min_app_version: '1.0.0' });
  expect((config.data as { rules: { licence_classes: string[] } }).rules.licence_classes.length).toBeGreaterThan(0);
  expect(config.headers['cache-control']).toBe('no-store');

  const cars = await call(request, 'GET', '/cars');
  const list = (cars.data as { cars: Array<{ slug: string; make: string; daily_rate_cents: number; cover: { url: string } | null }> }).cars;
  expect(list.length).toBeGreaterThan(5);
  const car = list.find((c) => c.cover) ?? list[0]!;
  expect(car.daily_rate_cents).toBeGreaterThan(0);

  const page = await call(request, 'GET', `/cars/${car.slug}`);
  expect(page.status).toBe(200);
  expect((page.data as { car: { make: string } }).car.make).toBe(car.make);
  expect(Array.isArray((page.data as { photos: unknown[] }).photos)).toBe(true);

  const free = await call(request, 'POST', '/cars/available', { body: { from: day(200), to: day(203) } });
  expect(free.status).toBe(200);
  expect((free.data as Array<{ total_cents: number; billable_days: number }>)[0]).toMatchObject({ billable_days: 3 });
  const quote = await call(request, 'POST', `/cars/${car.slug}/quote`, { body: { from: day(200), to: day(203) } });
  expect((quote.data as { total_cents: number }).total_cents).toBeGreaterThan(0);

  expect((await call(request, 'GET', '/cars/not-a-car-anywhere')).status).toBe(404);
  expect((await call(request, 'GET', '/admin/everything')).json).toMatchObject({ ok: false, code: 'not_found' });
  // dates the wrong way round or not dates at all never reach the database
  expect((await call(request, 'POST', '/cars/available', { body: { from: 'tomorrow', to: day(3) } })).status).toBe(400);
});

test('a session is the bearer token only: no token, a bad token and a cookie are all signed out', async ({ request }, info) => {
  const a = await account(`session-${info.project.name}`);
  expect((await call(request, 'GET', '/trips')).json).toMatchObject({ ok: false, code: 'auth' });
  expect((await call(request, 'GET', '/me', { token: 'x'.repeat(60) })).status).toBe(401);
  expect((await call(request, 'POST', '/auth/sign-in', { body: { email: a.email } })).json).toMatchObject({ code: 'invalid', message: 'Your password is missing.' });
  const wrong = await call(request, 'POST', '/auth/sign-in', { body: { email: a.email, password: 'not the password' } });
  expect(wrong.status).toBe(401);
  expect(wrong.json.message).toBe('That email and password do not match an account.');

  const s = await signIn(request, a.email);
  expect(s.user).toMatchObject({ id: a.id, email: a.email });
  expect(s.expires_at * 1000).toBeGreaterThan(Date.now());
  const me = await call(request, 'GET', '/me', { token: s.access_token });
  expect(me.data).toMatchObject({ user: { id: a.id }, aal: 'aal1', needs_two_step: false, roles: { renter: true, staff: false, admin: false } });

  // the website's session cookie carrying the same token is not a session here
  const viaCookie = await call(request, 'GET', '/trips', { headers: { cookie: `cc-local-session=${s.access_token}` } });
  expect(viaCookie.status).toBe(401);
  // and signing in through the API sets no cookie
  const again = await call(request, 'POST', '/auth/sign-in', { body: { email: a.email, password: PASSWORD } });
  expect(again.headers['set-cookie']).toBeUndefined();

  // a new access token from the refresh token; an access token is not a refresh token
  const fresh = await call(request, 'POST', '/auth/refresh', { body: { refresh_token: s.refresh_token } });
  expect(fresh.status).toBe(200);
  expect((await call(request, 'GET', '/me', { token: (fresh.data as { access_token: string }).access_token })).status).toBe(200);
  expect((await call(request, 'POST', '/auth/refresh', { body: { refresh_token: s.access_token } })).json).toMatchObject({ ok: false, code: 'expired' });
  // an app too old for this server is told to update before anything else
  expect((await call(request, 'GET', '/me', { token: s.access_token, headers: { 'x-carmacars-app': '0.9.0 ios' } })).status).toBe(426);
});

test('a renter asks for a car from the app: the same request, the same bot check, made once however often it is sent', async ({ request }, info) => {
  const a = await account(`book-${info.project.name}`);
  const s = await signIn(request, a.email);
  const cars = (await call(request, 'GET', '/cars')).data as { cars: Array<{ slug: string }> };
  const free = (await call(request, 'POST', '/cars/available', { body: { from: day(210), to: day(213) } })).data as Array<{ slug: string }>;
  const slug = free.find((f) => cars.cars.some((c) => c.slug === f.slug))!.slug;
  const data = { car: slug, from: day(210), to: day(213), tf: '10:00', tt: '10:00', pickupAt: 'ours', pickupAddress: { label: '', placeId: '' }, pickupAirport: '', returnAt: 'ours', returnAddress: { label: '', placeId: '' },
    returnAirport: '', first: 'App', last: 'Tester', email: a.email, phone: '647-555-0143', dobY: '1990', dobM: '5', dobD: '5', drivers: [], referrer: '', heardAbout: '', licClass: 'G', licIssuer: '', coverage: '3',
    coverageCard: '', coverageCardAck: false, opcfAck: false, bookingType: 'standard', winter: false, babySeats: 0, notes: 'Sent from the app', addons: [], agree: true, marketing: false, notifyChannel: '', promo: '' };
  const key = `app-e2e-${randomUUID()}`;

  expect((await call(request, 'POST', '/requests', { token: s.access_token, body: { data, requestKey: key } })).json).toMatchObject({ ok: false, code: 'turnstile' });
  expect((await call(request, 'POST', '/requests', { body: { data, requestKey: key, turnstile: TURNSTILE } })).status).toBe(401);
  const bad = await call(request, 'POST', '/requests', { token: s.access_token, body: { data: { ...data, agree: false }, requestKey: `app-e2e-${randomUUID()}`, turnstile: TURNSTILE } });
  expect(bad.json).toMatchObject({ ok: false, code: 'invalid' });

  const sent = await call(request, 'POST', '/requests', { token: s.access_token, body: { data, requestKey: key, turnstile: TURNSTILE } });
  expect(sent.status, sent.json.message).toBe(200);
  const number = (sent.data as { bookingNumber: string; created: boolean }).bookingNumber;
  expect(sent.data).toMatchObject({ created: true });
  const twice = await call(request, 'POST', '/requests', { token: s.access_token, body: { data, requestKey: key, turnstile: TURNSTILE } });
  expect(twice.data).toMatchObject({ bookingNumber: number, created: false });

  const trips = (await call(request, 'GET', '/trips', { token: s.access_token })).data as Array<{ booking_number: string; status: string }>;
  expect(trips.map((t) => t.booking_number)).toContain(number);
  const trip = await call(request, 'GET', `/trips/${number}`, { token: s.access_token });
  expect(trip.data).toMatchObject({ booking: { booking_number: number, status: 'requested' }, messages: [] });

  // a message goes to the booking's own thread, as from the booking page
  expect((await call(request, 'POST', `/trips/${number}/messages`, { token: s.access_token, body: { body: 'Can I pick up an hour earlier?' } })).status).toBe(200);
  const after = (await call(request, 'GET', `/trips/${number}`, { token: s.access_token })).data as { messages: Array<{ direction: string; body: string }> };
  expect(after.messages.at(-1)).toMatchObject({ direction: 'inbound', body: 'Can I pick up an hour earlier?' });

  // the steps that are not due yet answer with the website's own reasons
  expect((await call(request, 'GET', `/trips/${number}/agreement`, { token: s.access_token })).json).toMatchObject({ ok: false, code: 'no_agreement' });
  expect((await call(request, 'POST', `/trips/${number}/payment`, { token: s.access_token })).json.ok).toBe(false);
  expect((await call(request, 'POST', `/trips/${number}/checkin`, { token: s.access_token, body: { photos: [] } })).json.message).toBe('Add the photo of the dashboard (odometer and fuel gauge).');
  expect((await call(request, 'POST', `/trips/${number}/uploads`, { token: s.access_token, body: { kind: 'selfie', contentType: 'image/svg+xml', size: 10 } })).status).toBe(400);

  // another renter cannot read it: the number reads as not found
  const other = await signIn(request, (await account(`other-${info.project.name}`)).email);
  expect((await call(request, 'GET', `/trips/${number}`, { token: other.access_token })).status).toBe(404);
  expect((await call(request, 'POST', `/trips/${number}/messages`, { token: other.access_token, body: { body: 'Let me in' } })).json.ok).toBe(false);
});

test('each role keeps to its own part: the database refuses the rest, whatever the app sends', async ({ request }, info) => {
  const renter = await signIn(request, (await account(`role-renter-${info.project.name}`)).email);
  const field = await signIn(request, (await account(`role-field-${info.project.name}`, 'field')).email);
  for (const path of ['/field/today', '/field/jobs', '/field/shifts', '/sales/leads']) expect((await call(request, 'GET', path, { token: renter.access_token })).status, path).toBe(403);
  expect((await call(request, 'GET', '/owner', { token: renter.access_token })).json).toMatchObject({ ok: false, code: 'not_owner' });
  expect((await call(request, 'POST', '/field/clock', { token: renter.access_token, body: { what: 'in' } })).json.message).toBe('Only field staff clock in and out.');
  expect((await call(request, 'POST', '/sales/offers/read', { token: renter.access_token, body: { what: 'offer_form', p: {} } })).json.ok).toBe(false);

  expect((await call(request, 'GET', '/me', { token: field.access_token })).data).toMatchObject({ roles: { field: true, renter: false } });
  const today = await call(request, 'GET', '/field/today', { token: field.access_token });
  expect(today.status, today.json.message).toBe(200);
  expect(today.data).toMatchObject({ clock: null });
  expect((await call(request, 'GET', '/field/shifts', { token: field.access_token })).status).toBe(200);
  expect((await call(request, 'GET', '/sales/leads', { token: field.access_token })).status).toBe(403);
  expect((await call(request, 'GET', '/field/jobs/00000000-0000-4000-8000-000000000000', { token: field.access_token })).status).toBe(404);
  // steps the app does not take never reach the server action, even for staff
  expect((await call(request, 'POST', '/field/act', { token: field.access_token, body: { action: 'licence_approve_all', p: {} } })).json).toMatchObject({ ok: false, code: 'invalid' });
  expect((await call(request, 'POST', '/sales/leads/act', { token: field.access_token, body: { action: 'lead_reassign', p: {} } })).json).toMatchObject({ ok: false, code: 'invalid' });
  expect((await call(request, 'POST', '/sales/offers', { token: field.access_token, body: { action: 'record_booking_payment', p: {} } })).json).toMatchObject({ ok: false, code: 'invalid' });
});

test('alerts, passkeys and deleting the account from the app', async ({ request }, info) => {
  const a = await account(`self-${info.project.name}`);
  const s = await signIn(request, a.email);
  const t = { token: s.access_token };
  const sql = db();

  // alerts: this phone becomes one of the account's devices in the site's own push outbox
  const push = `e2e-${randomUUID()}-${'f'.repeat(80)}`;
  const on = await call(request, 'POST', '/me/push', { ...t, body: { token: push, platform: 'ios', portal: 'renter', device: 'CarmaCars app on iPhone' } });
  expect(on.status, on.json.message).toBe(200);
  const dev = await sql`select kind, platform from push_subscriptions where user_id = ${a.id}`;
  expect(dev).toHaveLength(1);
  expect(dev[0]).toMatchObject({ kind: 'fcm', platform: 'ios' });
  expect((await call(request, 'POST', '/me/push/test', t)).data).toMatchObject({ queued: 1 });
  expect((await call(request, 'PUT', '/me/push/topics', { ...t, body: { topics: ['bookings', 'payments'] } })).data).toMatchObject({ topics: ['bookings', 'payments'] });
  expect((await call(request, 'PUT', '/me/push/topics', { ...t, body: { topics: ['everything'] } })).status).toBe(400);
  expect((await call(request, 'POST', '/me/push/off', { ...t, body: { token: push } })).status).toBe(200);
  expect(await sql`select 1 from push_subscriptions where user_id = ${a.id}`).toHaveLength(0);

  // passkeys: a one-time challenge for this person; an answer the phone did not sign is refused and adds nothing
  const options = await call(request, 'POST', '/me/passkeys/options', t);
  const o = options.data as { challenge_id: string; challenge: string; rp_id: string; user: { id: string } };
  expect(o.challenge).toMatch(/^[A-Za-z0-9_-]{43}$/);
  expect(o.user.id).toBe(a.id);
  const forged = await call(request, 'POST', '/me/passkeys', { ...t, body: { challenge_id: o.challenge_id, credential: { id: 'a'.repeat(22), response: { clientDataJSON: 'e30', attestationObject: 'AA' } } } });
  expect(forged.json).toMatchObject({ ok: false, message: 'The phone\'s passkey could not be checked. Try again.' });
  expect((await call(request, 'GET', '/me/passkeys', t)).data).toEqual([]);
  const anon = await call(request, 'POST', '/auth/passkey/options');
  expect((anon.data as { user?: unknown }).user).toBeUndefined();
  const refused = await call(request, 'POST', '/auth/passkey/verify', { body: { challenge_id: (anon.data as { challenge_id: string }).challenge_id, credential: { id: 'a'.repeat(22), response: { clientDataJSON: 'e30', authenticatorData: 'AA', signature: 'AA' } } } });
  expect(refused.status).toBe(401);

  // delete my account: asked in the app, an Admin's task on the site; it can be withdrawn until it is done
  const asked = await call(request, 'POST', '/me/deletion', { ...t, body: { reason: 'Testing the app' } });
  expect(asked.data).toMatchObject({ allowed: true, request: { status: 'open' } });
  expect(await sql`select 1 from account_deletion_requests where user_id = ${a.id} and status = 'open'`).toHaveLength(1);
  expect((await call(request, 'GET', '/me', t)).data).toMatchObject({ deletion: { request: { status: 'open' } } });
  expect((await call(request, 'DELETE', '/me/deletion', t)).data).toMatchObject({ request: { status: 'withdrawn' } });
  await sql.end();

  // signing out ends the phone's session; the bot check page the app opens is there and says nothing to search engines
  expect((await call(request, 'POST', '/auth/sign-out', t)).status).toBe(200);
  const page = await request.get('/app-check');
  expect(page.status()).toBe(200);
  expect(page.headers()['x-robots-tag']).toContain('noindex');
  expect(await page.text()).toContain('ReactNativeWebView');
});
