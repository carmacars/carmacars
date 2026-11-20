import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ROUTES, ROUTE_IDS, bearerOf, compareVersions, matchRoute, routePath, type RouteDef } from './contract.ts';
import { parse } from './shape.ts';
import { answerOf, answerOfError } from './respond.ts';

const def = (id: (typeof ROUTE_IDS)[number]) => ROUTES[id] as RouteDef<unknown>;
const seg = (p: string) => p.split('/').filter(Boolean);

test('every route is found by its own method and path, and by no other method', () => {
  for (const id of ROUTE_IDS) {
    const d = def(id);
    const path = d.path.replace(/:([a-z]+)/g, 'x1');
    assert.equal(matchRoute(d.method, seg(path))?.id, id, id);
    const other = d.method === 'GET' ? 'DELETE' : 'GET';
    assert.notEqual(matchRoute(other, seg(path))?.id, id, `${id} by ${other}`);
  }
});

test('no two routes share a method and a path', () => {
  const seen = new Set<string>();
  for (const id of ROUTE_IDS) { const k = `${def(id).method} ${def(id).path.replace(/:[a-z]+/g, ':')}`; assert.ok(!seen.has(k), k); seen.add(k); }
});

test('only the listed routes work without a session: the public catalogue and the ways to sign in', () => {
  const open = ROUTE_IDS.filter((id) => def(id).auth === 'public').sort();
  assert.deepEqual(open, ['auth.passkeyOptions', 'auth.passkeyVerify', 'auth.phoneStart', 'auth.phoneVerify', 'auth.refresh', 'auth.signIn', 'car', 'car.quote', 'cars', 'cars.available', 'config']);
  for (const id of ROUTE_IDS) if (/^(me|trip|trips|field|sales|owner|notices|request|upload)\b/.test(id)) assert.equal(def(id).auth, 'user', id);
});

test('a write always has a shape or takes nothing; a read never takes a body', () => {
  for (const id of ROUTE_IDS) { const d = def(id); if (d.method === 'GET') assert.equal(d.body, undefined, id); }
});

test('path parameters are filled in and read back; an unknown path is not a route', () => {
  assert.equal(routePath('trip.message', { number: 'CC-1042' }), '/trips/CC-1042/messages');
  assert.deepEqual(matchRoute('POST', ['trips', 'CC-1042', 'messages']), { id: 'trip.message', params: { number: 'CC-1042' } });
  assert.deepEqual(matchRoute('get', ['trips', 'CC-1042']), { id: 'trip', params: { number: 'CC-1042' } });
  assert.equal(matchRoute('GET', ['trips', 'CC-1042', 'messages', 'x']), null);
  assert.equal(matchRoute('GET', ['admin']), null);
  assert.equal(matchRoute('GET', ['trips', 'x'.repeat(201)]), null);
  assert.throws(() => routePath('trip', {}));
  assert.equal(routePath('car', { slug: 'a b' }), '/cars/a%20b');
});

test('the bearer token: read from the header, never from anything else', () => {
  const t = 'a'.repeat(30) + '.' + 'b'.repeat(30) + '.' + 'c_-'.repeat(10);
  assert.equal(bearerOf(`Bearer ${t}`), t);
  assert.equal(bearerOf(`bearer ${t}`), t);
  assert.equal(bearerOf('Bearer short'), null);
  assert.equal(bearerOf(`Basic ${t}`), null);
  assert.equal(bearerOf(`Bearer ${t} extra`), null);
  assert.equal(bearerOf(null), null);
});

test('request shapes: the cleaned fields, unknown fields dropped, the first wrong field named', () => {
  const signIn = def('auth.signIn').body!;
  assert.deepEqual(parse(signIn, { email: ' rita@example.test ', password: ' keep spaces ', admin: true }), { ok: true, data: { email: 'rita@example.test', password: ' keep spaces ' } });
  assert.deepEqual(parse(signIn, { email: 'rita@example.test' }), { ok: false, field: 'password', message: 'Your password is missing.' });
  assert.equal(parse(signIn, 'x').ok, false);
  assert.equal(parse(signIn, null).ok, false);
  const act = def('field.act').body!;
  assert.equal(parse(act, { action: 'complete_handover', p: { job: 'j1' } }).ok, true);
  // a step the app does not take (the licence review, the staff tools) is refused before the server action is reached
  assert.deepEqual(parse(act, { action: 'licence_approve_all', p: {} }), { ok: false, field: 'action', message: 'Check action.' });
  assert.equal(parse(act, { action: 'start', p: [] }).ok, false);
  const lead = def('sales.leadAct').body!;
  assert.equal(parse(lead, { action: 'lead_claim', p: { id: 'x' } }).ok, true);
  for (const admins of ['lead_reassign', 'sales_lead_settings_save', 'lead_phone_unlock', 'leads_bulk_assign']) assert.equal(parse(lead, { action: admins, p: {} }).ok, false, admins);
  const offer = def('sales.offer').body!;
  for (const money of ['record_booking_payment', 'deposit_return_offline', 'booking_fees_change']) assert.equal(parse(offer, { action: money, p: {} }).ok, false, money);
  const push = def('me.pushOn').body!;
  assert.equal(parse(push, { token: 'f'.repeat(60), platform: 'ios' }).ok, true);
  assert.equal(parse(push, { token: 'f'.repeat(60), platform: 'web' }).ok, false);
  const sign = def('trip.sign').body!;
  assert.equal(parse(sign, { consents: ['a'], sha: 'not-a-hash' }).ok, false);
  assert.equal(parse(sign, { consents: ['a'], sha: 'ab'.repeat(32), typedName: 'Rita Renter' }).ok, true);
  const upload = def('trip.upload').body!;
  assert.equal(parse(upload, { kind: 'selfie', contentType: 'image/jpeg', size: 400_000 }).ok, true);
  assert.equal(parse(upload, { kind: 'passport', contentType: 'image/jpeg', size: 1 }).ok, false);
  assert.equal(parse(upload, { kind: 'selfie', contentType: 'image/svg+xml', size: 1 }).ok, false);
  assert.equal(parse(def('auth.passkeyVerify').body!, { challenge_id: 'nope', credential: {} }).ok, false);
});

test('a large free-form part is refused by size', () => {
  const r = parse(def('request.submit').body!, { data: { notes: 'x'.repeat(70_000) }, requestKey: 'abcdefgh-1234' });
  assert.deepEqual(r, { ok: false, field: 'data', message: 'data is too large.' });
});

test('answers: the envelope as it is, a refusal with its status, a plain value wrapped', () => {
  assert.deepEqual(answerOf({ ok: true, data: { a: 1 } }), { status: 200, body: { ok: true, data: { a: 1 } } });
  assert.deepEqual(answerOf([1, 2]), { status: 200, body: { ok: true, data: [1, 2] } });
  assert.deepEqual(answerOf(undefined), { status: 200, body: { ok: true, data: null } });
  assert.deepEqual(answerOf({ ok: false, code: 'auth', message: 'Sign in first.' }), { status: 401, body: { ok: false, code: 'auth', message: 'Sign in first.' } });
  assert.equal(answerOf({ ok: false, code: 'invalid', message: 'x', fieldErrors: { a: 'b' } }).status, 400);
  assert.equal(answerOf({ ok: false, code: 'not_found', message: 'x', status: 404 }).status, 404);
  assert.equal(answerOf({ ok: false, code: 'rate_limited', message: 'x' }).status, 429);
  assert.equal(answerOf({ ok: false, message: '' }).body.ok, false);
});

test('errors: a redirect after a step is a success with where the site goes next; sign-in and not found are refusals', () => {
  const redirect = (to: string) => Object.assign(new Error('NEXT_REDIRECT'), { digest: `NEXT_REDIRECT;push;${to};307;` });
  assert.deepEqual(answerOfError(redirect('/account/bookings/CC-1/checkout?signed=1#pay')).body, { ok: true, data: null, next: '/account/bookings/CC-1/checkout?signed=1#pay' });
  assert.equal(answerOfError(redirect('/sign-in?next=%2Faccount')).status, 401);
  assert.equal(answerOfError(redirect('/two-step?next=/staff')).body.ok, false);
  assert.deepEqual(answerOfError(redirect('https://evil.example.test/')).body, { ok: true, data: null });
  assert.equal(answerOfError(Object.assign(new Error('x'), { digest: 'NEXT_HTTP_ERROR_FALLBACK;404' })).status, 404);
  const db = (message: string, code?: string) => Object.assign(new Error(message), { name: 'DbError', code });
  assert.deepEqual(answerOfError(db('Only field staff may do this.', '42501')), { status: 403, body: { ok: false, code: 'forbidden', message: 'Only field staff may do this.' } });
  assert.equal(answerOfError(db('Two-step sign-in is required.', 'two_step')).body.ok, false);
  assert.equal(answerOfError(db('Booking not found', 'P0002')).status, 404);
  assert.equal(answerOfError(db('This offer was updated.')).status, 400);
  const boom = answerOfError(new TypeError('cannot read x of undefined'));
  assert.equal(boom.status, 500); assert.equal(boom.unexpected, true);
  assert.equal((boom.body as { message: string }).message.includes('undefined'), false);
});

test('app versions compare by number, not by text', () => {
  assert.ok(compareVersions('1.9.0', '1.10.0') < 0);
  assert.ok(compareVersions('2.0.0', '1.99.99') > 0);
  assert.equal(compareVersions('1.0', '1.0.0'), 0);
});
