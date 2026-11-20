import 'server-only';
import { env } from '@/lib/env';
import { DbError, rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { androidOrigins, checkAssertion, checkRegistration, type PublicJwk } from '@/lib/auth/webauthn';
import type { PasskeyOptions, PasskeyRow } from '@/features/mobile-api/contract';
import { sessionForUser, type Issued } from './auth';

// Passkeys for the native app (release 48, migration 3170). The phone keeps the key; the database keeps the public key
// and the one-time challenges and decides what is allowed; this file checks the phone's answer (src/lib/auth/webauthn.ts)
// between the two. The relying party is the site's own domain, which the apps are tied to by the app links files
// (/.well-known/apple-app-site-association: webcredentials; /.well-known/assetlinks.json: get_login_creds).
const SR = { role: 'service_role' as const };

/** The domain passkeys belong to (carmacars.ca), and the origins an answer may come from. */
export function relyingParty(): { id: string; origins: string[] } {
  const e = env();
  const host = new URL(e.NEXT_PUBLIC_APP_URL).hostname.replace(/^www\./, '');
  return { id: host, origins: [`https://${host}`, `https://www.${host}`, ...androidOrigins(e.APP_ANDROID_CERT_SHA256),
    // the local stack and the tests: the site itself over http
    ...(e.APP_ENV !== 'production' ? [new URL(e.NEXT_PUBLIC_APP_URL).origin] : [])] };
}

export async function passkeyList(userId: string): Promise<PasskeyRow[]> {
  return ((await rpc('server_passkeys', { p_user: userId }, SR)) ?? []) as unknown as PasskeyRow[];
}

/** What the phone needs to make a passkey for the signed-in person (or, with no user, to sign in with one). */
export async function passkeyOptions(user: { id: string; email: string; name?: string | null } | null, ip: string | null): Promise<PasskeyOptions> {
  const c = (await rpc('server_passkey_challenge', { p_user: (user?.id ?? null) as unknown as string, p_kind: user ? 'register' : 'sign_in', p_ip: ip ?? undefined }, SR)) as unknown as { id: string; challenge: string; credentials: string[] };
  const rp = relyingParty();
  return { challenge_id: c.id, challenge: c.challenge, rp_id: rp.id, rp_name: 'CarmaCars',
    ...(user ? { user: { id: user.id, name: user.email || user.name || 'CarmaCars account', display_name: user.name || user.email || 'CarmaCars account' }, exclude: c.credentials } : {}) };
}

export async function passkeyAdd(userId: string, challengeId: string, credential: { id: string; response: { clientDataJSON: string; attestationObject: string } }, device: string | undefined): Promise<PasskeyRow[]> {
  const ch = (await rpc('server_passkey_challenge_read', { p_id: challengeId, p_kind: 'register' }, SR)) as unknown as { challenge: string; user_id: string | null } | null;
  if (!ch || ch.user_id !== userId) throw new DbError('That took too long. Try adding the passkey again.', 'P0001');
  const rp = relyingParty();
  const r = await checkRegistration(credential.response, { challenge: ch.challenge, rpId: rp.id, origins: rp.origins });
  if (!r.ok || r.credentialId !== credential.id) {
    console.warn('passkey registration refused', r.ok ? 'credential id' : r.reason);
    throw new DbError('The phone\'s passkey could not be checked. Try again.', 'P0001');
  }
  return (await rpc('server_passkey_register', { p_user: userId, p_challenge: challengeId,
    p: { credential_id: r.credentialId, public_key: r.jwk, alg: r.alg, sign_count: r.signCount, device: device ?? null } as unknown as Json }, SR)) as unknown as PasskeyRow[];
}

export async function passkeyRemove(userId: string, id: string): Promise<PasskeyRow[]> {
  return (await rpc('server_passkey_remove', { p_user: userId, p_id: id }, SR)) as unknown as PasskeyRow[];
}

const REFUSED = 'This passkey was not accepted. Sign in with your email or phone instead.';
/** A sign-in with a passkey: the answer is checked with the stored key, the challenge is spent, the session is issued. */
export async function passkeySignIn(challengeId: string, credential: { id: string; response: { clientDataJSON: string; authenticatorData: string; signature: string } }): Promise<Issued & { userId?: string }> {
  const [ch, key] = await Promise.all([
    rpc('server_passkey_challenge_read', { p_id: challengeId, p_kind: 'sign_in' }, SR) as unknown as Promise<{ challenge: string } | null>,
    rpc('server_passkey_lookup', { p_credential: credential.id }, SR) as unknown as Promise<{ user_id: string; public_key: PublicJwk; alg: number } | null>
  ]);
  if (!ch) return { ok: false, code: 'expired', message: 'That took too long. Try again.' };
  if (!key) return { ok: false, code: 'credentials', message: REFUSED };
  const rp = relyingParty();
  const r = await checkAssertion(credential.response, { challenge: ch.challenge, rpId: rp.id, origins: rp.origins, jwk: key.public_key, alg: key.alg });
  if (!r.ok) { console.warn('passkey sign-in refused', r.reason); return { ok: false, code: 'credentials', message: REFUSED }; }
  let userId: string;
  try { userId = (await rpc('server_passkey_used', { p_challenge: challengeId, p_credential: credential.id, p_sign_count: r.signCount }, SR)) as unknown as string; }
  catch (e) { return { ok: false, code: 'credentials', message: e instanceof DbError ? e.message : REFUSED }; }
  const s = await sessionForUser(userId);
  return s.ok ? { ...s, userId } : s;
}
