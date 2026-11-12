import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { LiveArea } from '@/features/live/realtime/areas';

// Live updates (release 41, migration 2522): the topics a person may watch, as opaque tokens. The database decides
// (server_live_topics): staff areas for Admin and staff (field staff: the field area only), the person's own alerts and
// messages, a renter's own bookings, an owner's own bookings, one booking for staff or for its renter or owner. A scope
// the person may not read gets no token, so the screen simply does not update live. One small read per frame render.

const SR = { role: 'service_role' as const };
const AREA_SCOPE: Record<LiveArea, (userId: string) => string> = {
  bookings: () => 'staff:bookings', requests: () => 'staff:requests', leads: () => 'staff:leads', messages: () => 'staff:messages',
  field: () => 'staff:field', me: (u) => `user:${u}`, renter: (u) => `renter:${u}`, owner: (u) => `owner:${u}`
};

/** The tokens of the areas, for the portal frame's LivePortal (an area the person may not read is left out). */
export async function liveTokens(userId: string | null | undefined, areas: LiveArea[]): Promise<Partial<Record<LiveArea, string>>> {
  if (!userId || !areas.length) return {};
  const scopes = areas.map((a) => AREA_SCOPE[a](userId));
  const r = (await rpc('server_live_topics', { p_user: userId, p_scopes: scopes }, SR).catch(() => null)) as Record<string, string> | null;
  const out: Partial<Record<LiveArea, string>> = {};
  areas.forEach((a, i) => { const t = r?.[scopes[i]!]; if (typeof t === 'string') out[a] = t; });
  return out;
}

/** The token of one booking (by its number), for its page; null when the person may not read it. */
export async function liveBookingToken(userId: string | null | undefined, bookingNumber: string): Promise<string | null> {
  if (!userId || !bookingNumber) return null;
  const scope = `booking:${bookingNumber}`;
  const r = (await rpc('server_live_topics', { p_user: userId, p_scopes: [scope] }, SR).catch(() => null)) as Record<string, string> | null;
  return typeof r?.[scope] === 'string' ? r[scope]! : null;
}
