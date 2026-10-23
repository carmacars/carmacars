// Sign-in with a provider: the switch, the flow cookie and what /auth/callback does with the provider's code
// (finishOAuth), against fakes of the sign-in service and the database.
//   node --test --experimental-strip-types src/lib/auth/oauth.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { accountName, decodeFlow, enabledProviders, encodeFlow, finishOAuth, oauthMessage, type FinishDeps, type OAuthExchange, type OAuthFlow } from './oauth.ts';

const flow = (o: Partial<OAuthFlow> = {}): OAuthFlow => ({ p: 'google', next: null, intent: 'signin', again: false, state: 's1', t: Date.now(), ...o });

function deps(ex: OAuthExchange, o: { reg?: { ok: boolean; error?: string; created?: boolean }; record?: string | null; relink?: boolean; after?: string } = {}) {
  const calls: string[] = [];
  const d: FinishDeps = {
    exchange: async (code, state) => { calls.push(`exchange:${code}:${state}`); return ex; },
    signOut: async () => { calls.push('signOut'); },
    registerAccount: async (id, email, name) => { calls.push(`register:${id}:${email}:${name}`); return o.reg ?? { ok: true, created: false }; },
    userByEmail: async (email) => { calls.push(`byEmail:${email}`); return o.record ?? null; },
    relinkToRecord: async (fresh, rec) => { calls.push(`relink:${fresh}:${rec}`); return o.relink ?? true; },
    emailVerified: async (id, email) => { calls.push(`verified:${id}:${email}`); },
    clearSessionCookies: async () => { calls.push('clear'); },
    signUpDone: async () => { calls.push('signUpDone'); },
    afterSignIn: async (id, next) => { calls.push(`after:${id}:${next ?? ''}`); return o.after ?? next ?? '/account'; }
  };
  return { d, calls };
}
const ok = (o: Partial<Extract<OAuthExchange, { ok: true }>> = {}): OAuthExchange => ({ ok: true, user: { id: 'u1', email: 'Ann@Example.com' }, emailVerified: true, name: 'Ann Lee', fresh: false, ...o });

test('the switch: only the providers listed, in a fixed order; unset means none', () => {
  assert.deepEqual(enabledProviders(undefined), []);
  assert.deepEqual(enabledProviders(''), []);
  assert.deepEqual(enabledProviders('google'), ['google']);
  assert.deepEqual(enabledProviders(' Facebook, google ,twitter'), ['google', 'facebook']);
  assert.deepEqual(enabledProviders('microsoft apple'), ['microsoft', 'apple']);
});

test('the flow cookie: read back, refused when old, tampered or of an unknown provider', () => {
  const f = flow({ next: '/owner', intent: 'signup', again: true });
  assert.deepEqual(decodeFlow(encodeFlow(f)), f);
  assert.equal(decodeFlow(encodeFlow(flow({ t: Date.now() - 11 * 60_000 }))), null);
  assert.equal(decodeFlow(encodeFlow({ ...flow(), p: 'twitter' as never })), null);
  assert.equal(decodeFlow('%7Bnot json'), null);
  assert.equal(decodeFlow(null), null);
});

test('an existing account (same verified email, linked by the sign-in service): same account, records attached, then afterSignIn', async () => {
  const { d, calls } = deps(ok(), { reg: { ok: true, created: false } });
  const r = await finishOAuth(d, 'c1', flow({ next: '/account/bookings' }));
  assert.deepEqual(r, { kind: 'done', to: '/account/bookings', user: 'u1', created: false });
  assert.deepEqual(calls, ['exchange:c1:s1', 'clear', 'register:u1:ann@example.com:Ann Lee', 'verified:u1:ann@example.com', 'after:u1:/account/bookings']);
});

test('a new account: the users row and renter role (register_account), the welcome (email verified), sign-up capture closed', async () => {
  const { d, calls } = deps(ok({ fresh: true, name: null }), { reg: { ok: true, created: true } });
  const r = await finishOAuth(d, 'c2', flow({ intent: 'signup' }));
  assert.equal(r.kind, 'done');
  assert.equal(r.kind === 'done' && r.created, true);
  assert.ok(calls.includes('register:u1:ann@example.com:ann'), 'falls back to the address before the @ for the name');
  assert.ok(calls.includes('verified:u1:ann@example.com'));
  assert.ok(calls.includes('signUpDone'));
});

test('staff with two-step: the route is whatever afterSignIn says (the code step), never straight to the portal', async () => {
  const { d } = deps(ok(), { after: '/two-step?next=%2Fva' });
  const r = await finishOAuth(d, 'c3', flow({ next: '/va' }));
  assert.equal(r.to, '/two-step?next=%2Fva');
});

test('the provider did not verify the address: signed out, nothing registered or attached', async () => {
  const { d, calls } = deps(ok({ emailVerified: false }));
  const r = await finishOAuth(d, 'c4', flow());
  assert.deepEqual(r, { kind: 'refused', reason: 'unverified', to: '/sign-in?oauth=unverified&provider=google' });
  assert.deepEqual(calls, ['exchange:c4:s1', 'signOut']);
});

test('a code the sign-in service refuses: back to sign-in with the reason', async () => {
  const { d, calls } = deps({ ok: false, message: 'bad code' });
  const r = await finishOAuth(d, 'c5', flow({ p: 'microsoft' }));
  assert.deepEqual(r, { kind: 'refused', reason: 'exchange', to: '/sign-in?oauth=exchange&provider=microsoft' });
  assert.deepEqual(calls, ['exchange:c5:s1']);
});

test('an address on file from a booking request: the fresh sign-in is replaced by one for the record, then a second pass', async () => {
  const { d, calls } = deps(ok({ fresh: true }), { reg: { ok: false, error: 'email_on_record' }, record: 'rec-9' });
  const r = await finishOAuth(d, 'c6', flow({ next: '/account', intent: 'signup' }));
  assert.equal(r.kind, 'again');
  assert.equal(r.to, '/auth/oauth?provider=google&again=1&intent=signup&next=%2Faccount');
  assert.deepEqual(calls.slice(-3), ['byEmail:ann@example.com', 'signOut', 'relink:u1:rec-9']);
  assert.ok(!calls.some((c) => c.startsWith('verified:') || c.startsWith('after:')));
});

test('an address on file, but the sign-in is not fresh or this is already the second pass: refused, never relinked', async () => {
  for (const [ex, f] of [[ok({ fresh: false }), flow()], [ok({ fresh: true }), flow({ again: true })]] as const) {
    const { d, calls } = deps(ex, { reg: { ok: false, error: 'email_on_record' }, record: 'rec-9' });
    const r = await finishOAuth(d, 'c7', f);
    assert.equal(r.kind === 'refused' && r.reason, 'record');
    assert.ok(calls.includes('signOut'));
    assert.ok(!calls.some((c) => c.startsWith('relink:')));
  }
});

test('the account rows could not be made: signed out, a plain message', async () => {
  const { d, calls } = deps(ok(), { reg: { ok: false, error: 'other' } });
  const r = await finishOAuth(d, 'c8', flow());
  assert.equal(r.kind === 'refused' && r.reason, 'account');
  assert.ok(calls.includes('signOut'));
  assert.ok(oauthMessage('account', 'google'));
});

test('names and messages', () => {
  assert.equal(accountName('  Ann   Lee ', 'a@b.c'), 'Ann Lee');
  assert.equal(accountName('', 'jo.smith@b.c'), 'jo.smith');
  assert.equal(accountName('x'.repeat(130), 'a@b.c').length, 120);
  assert.match(oauthMessage('cancelled', 'google')!, /Google was cancelled/);
  assert.match(oauthMessage('unverified', 'facebook')!, /Facebook did not confirm/);
  assert.equal(oauthMessage(null, 'google'), null);
  assert.equal(oauthMessage('nonsense', 'google'), null);
});
