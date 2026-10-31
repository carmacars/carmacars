import 'server-only';
import { door } from '@/server/door';
import { env } from '@/lib/env';
import { CACHE_MS } from '@/features/live-map/config';
import { toView, type MapView, type RawMap } from '@/features/live-map/model';

// The Live map's read (migration 0242): one call through the door (admin_read live_map; the database checks the Admin
// again), kept 20 seconds in this Worker instance so a TV and a laptop refreshing together cost one read. The answer is
// the same for every Admin; it is only reused after the caller passed the Admin check. Masked unless `details`. Outside
// production every call reads afresh (the end-to-end tests change the data between two loads).
let kept: { at: number; data: RawMap } | null = null;
let pending: Promise<RawMap> | null = null;

export async function liveMap(adminId: string, details: boolean, aal?: 'aal1' | 'aal2' | null): Promise<MapView> {
  const now = Date.now();
  const keep = env().APP_ENV === 'production' ? CACHE_MS : 0;
  if (!kept || now - kept.at >= keep) {
    pending ??= door<RawMap>(adminId, 'admin_read', 'live_map', {}, aal).then((data) => { kept = { at: Date.now(), data }; return data; }).finally(() => { pending = null; });
    await pending;
  }
  return toView(kept!.data, details);
}
