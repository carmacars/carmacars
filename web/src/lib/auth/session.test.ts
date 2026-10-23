// The session cookie (@supabase/ssr's format), the refresh in the Worker entry, the access token check and the
// view-as write guard, against mocked fetches and a key made here.
//   node --test --experimental-strip-types src/lib/auth/session.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseCookieHeader, readSession, sessionCookies, type StoredSession } from './session-cookie.ts';
import { refreshSession } from './edge-refresh.ts';
import { resetJwksCache, verifyAccessToken } from './jwt-verify.ts';
import { viewAsRefusal, viewAsWriteRefused } from '../security/view-as-guard.ts';

const NAME = 'sb-abcdref-auth-token';
const b64u = (s: string | Uint8Array) => Buffer.from(s).toString('base64url');
const session = (exp: number, extra = ''): StoredSession => ({ access_token: `h.${b64u(JSON.stringify({ exp }))}.s`, refresh_token: 'r-old', expires_at: exp, token_type: 'bearer', user: { id: 'u1', email: 'a@b.c', note: extra } });
const header = (s: StoredSession, other = 'cc-cookie=1') => [other, ...sessionCookies(NAME, s).map((c) => `${c.name}=${c.value}`)].join('; ');

test('the cookie is written and read as @supabase/ssr does, in chunks when long', () => {
  const short = sessionCookies(NAME, session(100));
  assert.equal(short.length, 1);
  assert.ok(short[0]!.value.startsWith('base64-'));
  const long = sessionCookies(NAME, session(100, 'x'.repeat(5000)));
  assert.deepEqual(long.map((c) => c.name), [`${NAME}.0`, `${NAME}.1`, `${NAME}.2`]);
  assert.ok(long.every((c) => c.value.length <= 3180));
  assert.equal(readSession(parseCookieHeader(header(session(100, 'x'.repeat(5000)))))?.session.user?.note, 'x'.repeat(5000));
  // the older, unencoded form
  assert.equal(readSession(new Map([[NAME, encodeURIComponent(JSON.stringify(session(7)))]]))?.session.expires_at, 7);
  assert.equal(readSession(new Map([[NAME, 'base64-!!!']])), null);
  assert.equal(readSession(new Map([[`${NAME}-code-verifier`, 'x']])), null);
});

function gotrue(status: number, body: unknown) {
  const calls: Array<{ url: string; body: string }> = [];
  const f = (async (u: string | URL | Request, init?: RequestInit) => { calls.push({ url: String(u), body: String(init?.body) }); return new Response(JSON.stringify(body), { status }); }) as typeof fetch;
  return { f, calls };
}
const now = () => 1_000_000 * 1000;

test('a fresh session is left alone; one about to expire is refreshed once and stored', async () => {
  const g = gotrue(200, { access_token: 'new.at.x', refresh_token: 'r-new', expires_in: 3600, token_type: 'bearer', user: { id: 'u1' } });
  const fresh = new Request('https://carmacars.ca/owner', { headers: { cookie: header(session(1_000_000 + 3000)) } });
  assert.equal(await refreshSession(fresh, { url: 'https://p.supabase.co', anonKey: 'anon', fetch: g.f, now }), null);
  assert.equal(g.calls.length, 0);
  const old = new Request('https://carmacars.ca/owner', { headers: { cookie: header(session(1_000_000 + 30)) } });
  const r = await refreshSession(old, { url: 'https://p.supabase.co', anonKey: 'anon', fetch: g.f, now });
  assert.equal(r?.outcome, 'refreshed');
  assert.equal(g.calls[0]!.url, 'https://p.supabase.co/auth/v1/token?grant_type=refresh_token');
  assert.equal(JSON.parse(g.calls[0]!.body).refresh_token, 'r-old');
  const seen = readSession(parseCookieHeader(r!.request.headers.get('cookie')));
  assert.equal(seen?.session.access_token, 'new.at.x');
  assert.equal(seen?.session.expires_at, 1_000_000 + 3600);
  assert.ok(r!.request.headers.get('cookie')!.includes('cc-cookie=1'));
  assert.equal(r!.setCookies.length, 1);
  assert.match(r!.setCookies[0]!, new RegExp(`^${NAME}=base64-.*; Path=/; Max-Age=34560000; SameSite=Lax; Secure$`));
});

test('a spent refresh token signs the person out cleanly; Supabase unreachable changes nothing', async () => {
  const spent = gotrue(400, { error_code: 'refresh_token_already_used' });
  const req = new Request('https://carmacars.ca/va', { headers: { cookie: header({ ...session(1_000_000 - 10, 'y'.repeat(4000)), refresh_token: 'r-spent' }) } });
  const r = await refreshSession(req, { url: 'https://p.supabase.co', anonKey: 'anon', fetch: spent.f, now });
  assert.equal(r?.outcome, 'signed_out');
  assert.equal(r!.request.headers.get('cookie'), 'cc-cookie=1');
  assert.deepEqual(r!.setCookies.map((c) => c.split(';')[0]), [`${NAME}.0=`, `${NAME}.1=`]);
  assert.ok(r!.setCookies.every((c) => c.includes('Max-Age=0')));
  const down = gotrue(503, {});
  const req2 = new Request('https://carmacars.ca/va', { headers: { cookie: header({ ...session(1_000_000 - 10), refresh_token: 'r-other' }) } });
  assert.equal(await refreshSession(req2, { url: 'https://p.supabase.co', anonKey: 'anon', fetch: down.f, now }), null);
  assert.equal(await refreshSession(new Request('https://carmacars.ca/', { headers: { cookie: 'a=1' } }), { url: 'x', anonKey: 'y', fetch: down.f, now }), null);
});

test('an access token is checked against the published key: signature, expiry, audience, issuer', async () => {
  resetJwksCache();
  const { publicKey, privateKey } = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const jwk = { ...(await crypto.subtle.exportKey('jwk', publicKey)), kid: 'k1', alg: 'ES256', key_ops: ['verify'] };
  let fetched = 0;
  const f = (async () => { fetched++; return new Response(JSON.stringify({ keys: [jwk] })); }) as unknown as typeof fetch;
  const sign = async (claims: Record<string, unknown>, kid = 'k1') => {
    const h = b64u(JSON.stringify({ alg: 'ES256', kid, typ: 'JWT' })), p = b64u(JSON.stringify(claims));
    const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, privateKey, new TextEncoder().encode(`${h}.${p}`)));
    return `${h}.${p}.${b64u(sig)}`;
  };
  const url = 'https://p.supabase.co';
  const good = { sub: '9f1c2b7e-1111-4222-8333-944455556666', email: 'a@b.c', aud: 'authenticated', role: 'authenticated', iss: `${url}/auth/v1`, exp: Math.floor(Date.now() / 1000) + 600, aal: 'aal2' };
  const c = await verifyAccessToken(await sign(good), url, { fetch: f });
  assert.equal(c?.sub, good.sub);
  assert.equal(c?.aal, 'aal2');
  assert.equal(await verifyAccessToken(await sign({ ...good, exp: Math.floor(Date.now() / 1000) - 1 }), url, { fetch: f }), null, 'expired');
  assert.equal(await verifyAccessToken(await sign({ ...good, aud: 'other' }), url, { fetch: f }), null, 'audience');
  assert.equal(await verifyAccessToken(await sign({ ...good, iss: 'https://evil/auth/v1' }), url, { fetch: f }), null, 'issuer');
  assert.equal(await verifyAccessToken(await sign(good, 'k2'), url, { fetch: f }), null, 'unknown key');
  const t = await sign(good);
  assert.equal(await verifyAccessToken(t.slice(0, -4) + 'AAAA', url, { fetch: f }), null, 'signature');
  const hs = `${b64u(JSON.stringify({ alg: 'HS256' }))}.${b64u(JSON.stringify(good))}.x`;
  assert.equal(await verifyAccessToken(hs, url, { fetch: f }), null, 'HS256 goes to Supabase Auth instead');
  assert.equal(fetched, 1, 'the key set is fetched once');
});

test('view as: every write outside the Admin portal is refused while the cookie is set', () => {
  const c = 'a=1; cc-view-as=abc.def';
  assert.equal(viewAsWriteRefused('POST', '/owner/profile', c), true, 'a server action in a portal');
  assert.equal(viewAsWriteRefused('POST', '/account', c), true);
  assert.equal(viewAsWriteRefused('PUT', '/api/field/upload', c), true, 'an upload');
  assert.equal(viewAsWriteRefused('DELETE', '/va/tasks/1', c), true);
  assert.equal(viewAsWriteRefused('POST', '/', c), true, 'a public page');
  assert.equal(viewAsWriteRefused('GET', '/owner', c), false, 'reads go through');
  assert.equal(viewAsWriteRefused('POST', '/admin/settings/staff', c), false, 'the Admin portal is the Admin');
  assert.equal(viewAsWriteRefused('POST', '/administrator', c), true, 'only the Admin portal itself');
  assert.equal(viewAsWriteRefused('POST', '/api/view-as/exit', c), false, 'exit');
  assert.equal(viewAsWriteRefused('POST', '/owner/profile', 'a=1; cc-view-as='), false, 'an emptied cookie');
  assert.equal(viewAsWriteRefused('POST', '/owner/profile', 'a=1; cc-view-as-ui=Name'), false, 'the banner cookie alone');
});

test('view as: a refused server action is sent to the read-only page; anything else gets 403', async () => {
  const a = viewAsRefusal(true, {});
  assert.equal(a.headers.get('x-action-redirect'), '/read-only;push');
  const b = viewAsRefusal(false, { 'x-frame-options': 'DENY' });
  assert.equal(b.status, 403);
  assert.match(await b.text(), /^Read only/);
  assert.equal(b.headers.get('x-frame-options'), 'DENY');
});

test('a fresh token from another Supabase Auth (the hosted project, after the move) is refreshed at once; one from this one is left alone', async () => {
  const g = gotrue(200, { access_token: 'new.at.x', refresh_token: 'r-new', expires_in: 3600, token_type: 'bearer', user: { id: 'u1' } });
  const tok = (iss: string): StoredSession => ({ access_token: `h.${b64u(JSON.stringify({ exp: 1_000_000 + 3000, iss }))}.s`, refresh_token: 'r-moved', expires_at: 1_000_000 + 3000, token_type: 'bearer', user: { id: 'u1' } });
  const mine = new Request('https://carmacars.ca/owner', { headers: { cookie: header(tok('https://api.carmacars.ca/auth/v1')) } });
  assert.equal(await refreshSession(mine, { url: 'https://api.carmacars.ca/', anonKey: 'anon', fetch: g.f, now }), null);
  assert.equal(g.calls.length, 0);
  const moved = new Request('https://carmacars.ca/owner', { headers: { cookie: header(tok('https://abcdref.supabase.co/auth/v1')) } });
  const r = await refreshSession(moved, { url: 'https://api.carmacars.ca', anonKey: 'anon', fetch: g.f, now });
  assert.equal(r?.outcome, 'refreshed');
  assert.equal(g.calls.length, 1);
  assert.equal(g.calls[0]!.url, 'https://api.carmacars.ca/auth/v1/token?grant_type=refresh_token');
  assert.ok(r!.setCookies.some((c) => c.startsWith(`${NAME}=`)), 'the same cookie name is kept');
});
