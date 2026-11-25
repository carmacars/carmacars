// The calls in the site (r50, migration 5010): LiveKit's access token and webhook check, pure (the server and the unit
// tests share it). A token is a JWT (HS256) signed with the server's API secret: who (sub, name), which room and what
// they may do there (video grant), for a few minutes only. The media server checks it; nothing else is trusted.
import { SignJWT, jwtVerify } from 'jose';

export type CallRole = 'presenter' | 'host' | 'member' | 'guest';
export interface Grant { room: string; identity: string; name: string; role: CallRole }

/** What each role may do: everyone talks, shows a camera, shares a screen and chats; the presenter (Admin) and the
 *  interviewer may also moderate (mute or remove someone). */
export function videoGrant(g: Grant): Record<string, unknown> {
  const admin = g.role === 'presenter' || g.role === 'host';
  return { room: g.room, roomJoin: true, canPublish: true, canSubscribe: true, canPublishData: true, canUpdateOwnMetadata: true, roomAdmin: admin,
    canPublishSources: ['camera', 'microphone', 'screen_share', 'screen_share_audio'] };
}

export const TOKEN_SECONDS = 10 * 60;

/** A short token for one person and one room (10 minutes to connect; LiveKit renews it while connected). */
export async function mintToken(key: string, secret: string, g: Grant, now = Date.now()): Promise<string> {
  if (!/^[a-z0-9-]{6,80}$/.test(g.room)) throw new Error('bad room');
  if (!/^(u|g)-[0-9a-f-]{36}$/.test(g.identity)) throw new Error('bad identity');
  const t = Math.floor(now / 1000);
  return new SignJWT({ jti: `${g.identity}:${t}`, name: g.name.slice(0, 80), video: videoGrant(g), metadata: JSON.stringify({ role: g.role }) })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' }).setIssuer(key).setSubject(g.identity).setNotBefore(t - 5).setIssuedAt(t).setExpirationTime(t + TOKEN_SECONDS)
    .sign(new TextEncoder().encode(secret));
}

const b64 = (u: ArrayBuffer) => { let s = ''; for (const b of new Uint8Array(u)) s += String.fromCharCode(b); return btoa(s); };

/** A webhook from the media server: its Authorization is a JWT by our key and secret whose sha256 claim is the body's. */
export async function verifyWebhook(key: string, secret: string, body: string, auth: string | null | undefined): Promise<boolean> {
  const tok = (auth ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!tok) return false;
  try {
    const { payload } = await jwtVerify(tok, new TextEncoder().encode(secret), { issuer: key, algorithms: ['HS256'], clockTolerance: 60 });
    const want = b64(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(body)));
    return typeof payload.sha256 === 'string' && payload.sha256 === want;
  } catch { return false; }
}

export interface CallEvent { room: string; identity: string; event: 'joined' | 'left'; at: string }
/** The webhook events that move attendance: a person joined or left a room. Anything else: null. */
export function webhookEvent(body: unknown): CallEvent | null {
  const b = body as { event?: string; room?: { name?: string }; participant?: { identity?: string }; createdAt?: string | number };
  const ev = b?.event === 'participant_joined' ? 'joined' : b?.event === 'participant_left' ? 'left' : null;
  const room = b?.room?.name, id = b?.participant?.identity;
  if (!ev || !room || !id || !/^(u|g)-[0-9a-f-]{36}$/.test(id)) return null;
  const s = Number(b.createdAt);
  return { room, identity: id, event: ev, at: new Date(Number.isFinite(s) && s > 0 ? s * 1000 : Date.now()).toISOString() };
}
