// 3. Auth (GoTrue) end to end with a throwaway account rent+vpscheck-<run>@carmacars.ca (removed at the end).
// Prints result lines (no secrets, no tokens). Env: API, SITE, ANON, SERVICE, JWT_SECRET, REF, RUN, PHONE
import crypto from 'node:crypto';
const { API, SITE, ANON, SERVICE, JWT_SECRET, REF, RUN, PHONE } = process.env;
const out = (...a) => console.log(a.join(' '));
const email = `rent+vpscheck-${RUN}@carmacars.ca`;
const password = `Vc!${crypto.randomBytes(12).toString('hex')}aA9`;
const H = (k, tok) => ({ apikey: k, authorization: `Bearer ${tok ?? k}`, 'content-type': 'application/json' });
const j = async (r) => { const t = await r.text(); try { return JSON.parse(t); } catch { return { raw: t.slice(0, 200) }; } };
const short = (o) => JSON.stringify(o).replace(/eyJ[\w-]+\.[\w-]+\.[\w-]*/g, '<jwt>').slice(0, 300);
const b64u = (b) => Buffer.from(b).toString('base64url');
const claims = (t) => { try { const [h, p] = t.split('.'); return { h: JSON.parse(Buffer.from(h, 'base64url')), p: JSON.parse(Buffer.from(p, 'base64url')) }; } catch { return null; } };
const hs256 = (payload) => { const h = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' })); const p = b64u(JSON.stringify(payload)); return `${h}.${p}.${crypto.createHmac('sha256', JWT_SECRET).update(`${h}.${p}`).digest('base64url')}`; };
function totp(secret) {
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; let bits = '';
  for (const c of secret.replace(/=+$/, '').toUpperCase()) bits += A.indexOf(c).toString(2).padStart(5, '0');
  const key = Buffer.from(bits.match(/.{8}/g).map((b) => parseInt(b, 2)));
  const ctr = Buffer.alloc(8); ctr.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30000)));
  const h = crypto.createHmac('sha1', key).update(ctr).digest(); const o = h[19] & 15;
  return String(((h.readUInt32BE(o) & 0x7fffffff) % 1e6)).padStart(6, '0');
}
const step = async (name, fn) => { try { await fn(); } catch (e) { out(`${name}: EXCEPTION ${String(e?.message ?? e).slice(0, 200)}`); } };

let uid = null, at = null, rt = null;
await step('settings', async () => {
  const s = await j(await fetch(`${API}/auth/v1/settings`, { headers: H(ANON) }));
  out('settings:', JSON.stringify({ external: Object.entries(s.external ?? {}).filter(([, v]) => v).map(([k]) => k), disable_signup: s.disable_signup, mailer_autoconfirm: s.mailer_autoconfirm, phone_autoconfirm: s.phone_autoconfirm, sms_provider: s.sms_provider, saml: s.saml_enabled }));
  const oc = await j(await fetch(`${API}/auth/v1/.well-known/openid-configuration`)); out('issuer:', oc.issuer);
  const jw = await j(await fetch(`${API}/auth/v1/.well-known/jwks.json`)); out('jwks keys:', (jw.keys ?? []).map((k) => `${k.alg ?? k.kty}/${(k.kid ?? '').slice(0, 8)}`).join(', '));
});
await step('create', async () => {
  const r = await fetch(`${API}/auth/v1/admin/users`, { method: 'POST', headers: H(SERVICE), body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { full_name: 'VPS Check (temporary)' } }) });
  const b = await j(r); uid = b.id ?? null; out('admin create user:', r.status, uid ? 'ok' : short(b));
});
await step('signin', async () => {
  const r = await fetch(`${API}/auth/v1/token?grant_type=password`, { method: 'POST', headers: H(ANON), body: JSON.stringify({ email, password }) });
  const b = await j(r); at = b.access_token; rt = b.refresh_token;
  const c = at ? claims(at) : null;
  out('password sign-in:', r.status, c ? `alg=${c.h.alg} kid=${(c.h.kid ?? '').slice(0, 8)} iss=${c.p.iss} aal=${c.p.aal} role=${c.p.role} exp_in=${c.p.exp - Math.floor(Date.now() / 1000)}s` : short(b));
  const bad = await fetch(`${API}/auth/v1/token?grant_type=password`, { method: 'POST', headers: H(ANON), body: JSON.stringify({ email, password: 'wrong-password-1' }) });
  out('wrong password:', bad.status, short(await j(bad)).slice(0, 120));
});
const restAs = async (tok, label) => {
  const r = await fetch(`${API}/rest/v1/users?select=id`, { headers: H(ANON, tok) }); const b = await j(r);
  const s = await fetch(`${API}/storage/v1/object/list/documents`, { method: 'POST', headers: H(ANON, tok), body: JSON.stringify({ prefix: '', limit: 1 }) }); const sb = await j(s);
  const u = await fetch(`${API}/auth/v1/user`, { headers: H(ANON, tok) });
  out(`${label}: rest users ${r.status} rows=${Array.isArray(b) ? b.length : short(b)}; storage list ${s.status} ${Array.isArray(sb) ? 'rows=' + sb.length : short(sb).slice(0, 120)}; auth /user ${u.status}`);
};
await step('token-use', async () => { if (at) await restAs(at, 'new ES256 user token'); });
await step('hosted-token', async () => {
  if (!uid) return; const now = Math.floor(Date.now() / 1000);
  const base = { sub: uid, aud: 'authenticated', role: 'authenticated', email, aal: 'aal1', iat: now, exp: now + 1800, session_id: claims(at)?.p.session_id };
  await restAs(hs256({ ...base, iss: `https://${REF}.supabase.co/auth/v1` }), 'HS256 token with the hosted issuer');
  await restAs(hs256({ ...base, iss: `${API}/auth/v1` }), 'HS256 token with the new issuer (view-as style)');
});
await step('refresh', async () => {
  const r = await fetch(`${API}/auth/v1/token?grant_type=refresh_token`, { method: 'POST', headers: H(ANON), body: JSON.stringify({ refresh_token: rt }) });
  const b = await j(r); if (b.access_token) { at = b.access_token; rt = b.refresh_token; }
  out('refresh grant:', r.status, b.access_token ? `iss=${claims(at).p.iss}` : short(b));
});
await step('edge-refresh', async () => {
  // a session cookie as a browser from before the switch holds it: an access token from the hosted issuer and a refresh token
  const now = Math.floor(Date.now() / 1000);
  const old = hs256({ sub: uid, aud: 'authenticated', role: 'authenticated', email, aal: 'aal1', iat: now - 60, exp: now + 3000, session_id: claims(at)?.p.session_id, iss: `https://${REF}.supabase.co/auth/v1` });
  const sess = { access_token: old, refresh_token: rt, token_type: 'bearer', expires_in: 3000, expires_at: now + 3000, user: { id: uid, email } };
  const cookie = `sb-${REF}-auth-token=base64-${b64u(JSON.stringify(sess))}`;
  for (const path of ['/account', '/cars']) {
    const r = await fetch(`${SITE}${path}`, { headers: { cookie }, redirect: 'manual' });
    const sc = r.headers.getSetCookie?.() ?? [];
    const authc = sc.filter((c) => /-auth-token/.test(c));
    let iss = '-';
    const v = authc.map((c) => c.split(';')[0].split('=').slice(1).join('=')).join('');
    if (v.startsWith('base64-')) { try { iss = claims(JSON.parse(Buffer.from(v.slice(7), 'base64url').toString()).access_token).p.iss; } catch { iss = 'unreadable (chunked?)'; } }
    out(`edge-refresh ${path}: ${r.status} location=${(r.headers.get('location') ?? '-').replace(SITE, '')} auth set-cookies=${authc.length} new iss=${iss}`);
    if (authc.length) {
      // the refresh spent the refresh token: pick up the new pair for the next steps
      try { const s = JSON.parse(Buffer.from(v.slice(7), 'base64url').toString()); at = s.access_token; rt = s.refresh_token; } catch { /* keep */ }
      break;
    }
  }
});
await step('mfa', async () => {
  let r = await fetch(`${API}/auth/v1/factors`, { method: 'POST', headers: H(ANON, at), body: JSON.stringify({ factor_type: 'totp', friendly_name: `vpscheck-${RUN}` }) });
  let b = await j(r); out('mfa enroll totp:', r.status, b.id ? 'ok' : short(b)); if (!b.id) return;
  const fid = b.id, secret = b.totp?.secret;
  r = await fetch(`${API}/auth/v1/factors/${fid}/challenge`, { method: 'POST', headers: H(ANON, at), body: '{}' }); b = await j(r); out('mfa challenge:', r.status, b.id ? 'ok' : short(b));
  r = await fetch(`${API}/auth/v1/factors/${fid}/verify`, { method: 'POST', headers: H(ANON, at), body: JSON.stringify({ challenge_id: b.id, code: totp(secret) }) });
  b = await j(r); out('mfa verify:', r.status, b.access_token ? `aal=${claims(b.access_token).p.aal}` : short(b));
  if (b.access_token) { at = b.access_token; rt = b.refresh_token ?? rt; }
  r = await fetch(`${API}/auth/v1/factors/${fid}`, { method: 'DELETE', headers: H(ANON, at) }); out('mfa unenroll:', r.status);
});
await step('oauth', async () => {
  const r = await fetch(`${API}/auth/v1/authorize?provider=google&redirect_to=${encodeURIComponent(`${SITE}/auth/callback`)}`, { redirect: 'manual' });
  const loc = r.headers.get('location') ?? ''; let u = null; try { u = new URL(loc); } catch { /* */ }
  out('google authorize (api):', r.status, u ? `host=${u.host} redirect_uri=${u.searchParams.get('redirect_uri')} client_id_set=${!!u.searchParams.get('client_id')}` : loc.slice(0, 120));
  const s = await fetch(`${SITE}/auth/oauth?provider=google`, { redirect: 'manual' });
  const l2 = s.headers.get('location') ?? '';
  out('google start (site /auth/oauth):', s.status, l2.replace(/([?&](code_challenge|state)=)[^&]+/g, '$1…').slice(0, 220));
  if (l2.startsWith(API)) {
    const t = await fetch(l2, { redirect: 'manual' }); const l3 = t.headers.get('location') ?? ''; let u3 = null; try { u3 = new URL(l3); } catch { /* */ }
    out('  -> api:', t.status, u3 ? `host=${u3.host} redirect_uri=${u3.searchParams.get('redirect_uri')}` : l3.slice(0, 120));
  }
});
await step('logout', async () => {
  let r = await fetch(`${API}/auth/v1/logout?scope=global`, { method: 'POST', headers: H(ANON, at) }); out('sign-out (logout):', r.status);
  r = await fetch(`${API}/auth/v1/token?grant_type=refresh_token`, { method: 'POST', headers: H(ANON), body: JSON.stringify({ refresh_token: rt }) });
  out('refresh after sign-out (expect 400):', r.status);
});
await step('recover', async () => {
  const r = await fetch(`${API}/auth/v1/recover?redirect_to=${encodeURIComponent(`${SITE}/auth/callback`)}`, { method: 'POST', headers: H(ANON), body: JSON.stringify({ email }) });
  out('password reset email (recover):', r.status, short(await j(r)).slice(0, 160));
  await new Promise((s) => setTimeout(s, 3000));
  const u = await j(await fetch(`${API}/auth/v1/admin/users/${uid}`, { headers: H(SERVICE) }));
  out('recovery_sent_at set:', !!u.recovery_sent_at, u.recovery_sent_at ?? '');
});
await step('phone', async () => {
  if (!PHONE) return;
  let r = await fetch(`${API}/auth/v1/admin/users/${uid}`, { method: 'PUT', headers: H(SERVICE), body: JSON.stringify({ phone: PHONE.replace('+', ''), phone_confirm: true }) });
  out('attach the company number to the test account:', r.status, r.ok ? 'ok' : short(await j(r)).slice(0, 160));
  const t0 = new Date().toISOString();
  r = await fetch(`${API}/auth/v1/otp`, { method: 'POST', headers: H(ANON), body: JSON.stringify({ phone: PHONE, create_user: false, channel: 'sms' }) });
  out(`phone OTP request at ${t0}:`, r.status, short(await j(r)).slice(0, 220));
});
await step('cleanup', async () => {
  if (!uid) return;
  const r = await fetch(`${API}/auth/v1/admin/users/${uid}`, { method: 'DELETE', headers: H(SERVICE) }); out('delete test account:', r.status);
  const g = await fetch(`${API}/auth/v1/admin/users/${uid}`, { headers: H(SERVICE) }); out('test account gone (expect 404):', g.status);
});
