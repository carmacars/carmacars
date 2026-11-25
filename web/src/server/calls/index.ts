import 'server-only';
import { cookies } from 'next/headers';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { door } from '@/server/door';
import { readToken, signTokenUntil } from '@/server/links';
import { mintToken, type CallRole } from '@/features/calls/token';

// The calls in the site (r50, migration 5010). The database decides who may join which room as what (door call_join;
// a candidate through their single-use link's signed session); this file turns that into the media server's short token.
// The provider is a seam like the others: livekit (the company's LiveKit server), fake (no media: CI and local), off.
const SR = { role: 'service_role' as const };
export type CallsProvider = 'livekit' | 'fake' | 'off';

export interface MediaConfig { provider: CallsProvider; url: string | null }
/** livekit only with its address, key and secret; else fake in local and CI, off in production (the outside link). */
export function mediaConfig(): MediaConfig {
  const e = env();
  if (e.CALLS_PROVIDER === 'livekit') {
    return e.LIVEKIT_URL && e.LIVEKIT_API_KEY && e.LIVEKIT_API_SECRET && /^wss:\/\//.test(e.LIVEKIT_URL) ? { provider: 'livekit', url: e.LIVEKIT_URL } : { provider: 'off', url: null };
  }
  if (e.CALLS_PROVIDER === 'fake' && e.APP_ENV === 'production') return { provider: 'off', url: null };
  return { provider: e.CALLS_PROVIDER, url: null };
}

export interface Joined { in_site: boolean; room: string; kind: string; title: string; meeting_at: string | null; identity: string; name: string; role: CallRole; minutes: number; fallback_url: string | null }
export type JoinAs = { room: 'townhall' } | { room: 'interview'; application_id: string };
export interface CallTicket { provider: CallsProvider; url: string | null; token: string | null; room: string; identity: string; name: string; role: CallRole }

/** The ticket for a signed-in staff member or Admin: the database checks the room, then the token is minted. */
export async function staffTicket(userId: string, as: JoinAs): Promise<{ joined: Joined; ticket: CallTicket }> {
  const joined = await door<Joined>(userId, as.room === 'interview' ? 'admin_read' : 'ops_read', 'call_join', as as unknown as Record<string, unknown>);
  return { joined, ticket: await ticketFor(joined.room, joined.identity, joined.name, joined.role) };
}

export async function ticketFor(room: string, identity: string, name: string, role: CallRole): Promise<CallTicket> {
  const m = mediaConfig();
  const e = env();
  const token = m.provider === 'livekit' ? await mintToken(e.LIVEKIT_API_KEY!, e.LIVEKIT_API_SECRET!, { room, identity, name, role }) : null;
  return { provider: m.provider, url: m.url, token, room, identity, name, role };
}

// ---------------------------------------------------------------- the candidate's session (no staff account)
export const GUEST_COOKIE = 'cc-call-guest';
export interface GuestSession { ok: boolean; error?: string; room: string; identity: string; name: string; role: 'guest'; title: string; first_name: string; role_title: string;
  starts_at: string; ends_at: string; closes_at: string; booking_url: string }

/** The browser's own random value the link is bound to (kept in the signed cookie). */
export function newNonce(): string {
  const b = new Uint8Array(24); crypto.getRandomValues(b);
  return btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
export async function guestCookieValue(link: string, nonce: string, until: Date): Promise<string> {
  return signTokenUntil('call-guest', { l: link, n: nonce }, until);
}
export async function readGuestCookie(): Promise<{ l: string; n: string } | null> {
  const v = (await cookies()).get(GUEST_COOKIE)?.value;
  const t = await readToken<{ l: string; n: string }>('call-guest', v);
  return t && /^[0-9a-f-]{36}$/.test(t.l) && typeof t.n === 'string' ? t : null;
}
export async function guestSession(): Promise<GuestSession | null> {
  const c = await readGuestCookie();
  if (!c) return null;
  const s = (await rpc('server_call_guest_session', { p_link: c.l, p_nonce: c.n }, SR)) as unknown as GuestSession;
  return s?.ok ? s : null;
}

/** A join or leave the page saw (the heartbeat; the media server's webhook says the same, whichever comes first). */
export async function recordEvent(room: string, identity: string, event: 'joined' | 'left' | 'seen', at?: string): Promise<void> {
  await rpc('server_call_event', { p: { room, identity, event, ...(at ? { at } : {}) } as unknown as Json }, SR);
}
