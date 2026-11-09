import 'server-only';
import { door } from '@/server/door';
import { env } from '@/lib/env';
import { CACHE_MS } from '@/features/live-map/config';
import { MAP_PARTS, mergeParts, toView, type FleetCar, type MapPart, type MapView, type RawMap } from '@/features/live-map/model';
import { stateOf, withDemo, type Fleet } from '@/features/tracking/model';

// The Live map's read (migration 0242; 1080: a call per layer, at once): through the door (admin_read live_map; the database checks the Admin
// again), kept 20 seconds in this Worker instance so a TV and a laptop refreshing together cost one read. The answer is
// the same for every Admin; it is only reused after the caller passed the Admin check. Phones and emails only with `contact` (Release 26). Outside
// production every call reads afresh (the end-to-end tests change the data between two loads).
// 1080: the three layers (the KPI tiles, the pins, the fleet) are read at once, each on its own: one that fails or runs
// long is left out and named (the page says "Couldn't load ..."), the others are drawn. A read that fails everywhere throws.
let kept: { at: number; data: RawMap } | null = null;
async function readParts(userId: string, call: 'admin_read' | 'va_read', aal?: 'aal1' | 'aal2' | null): Promise<RawMap> {
  const parts = await Promise.all(MAP_PARTS.map((part: MapPart) => door<RawMap>(userId, call, 'live_map', { part }, aal)
    .then((value) => ({ part, ok: true as const, value }), (error: unknown) => ({ part, ok: false as const, error }))));
  for (const x of parts) if (!x.ok) console.error(`live map: the ${x.part} layer`, x.error);
  // a refusal (not an Admin, two-step sign-in) is the same for every layer: the caller sees it
  const refused = parts.find((x) => !x.ok && /only|two-step|second|Admin/i.test(x.error instanceof Error ? x.error.message : ''));
  if (refused && !refused.ok) throw refused.error;
  return mergeParts(parts);
}
let pending: Promise<RawMap> | null = null;

export async function liveMap(adminId: string, contact: boolean, aal?: 'aal1' | 'aal2' | null): Promise<MapView> {
  const now = Date.now();
  const keep = env().APP_ENV === 'production' ? CACHE_MS : 0;
  if (!kept || now - kept.at >= keep) {
    pending ??= readParts(adminId, 'admin_read', aal).then((data) => { kept = { at: data.failed?.length ? 0 : Date.now(), data }; return data; }).finally(() => { pending = null; });
    await pending;
  }
  const raw = kept!.data as RawMap & { tracker_demo?: boolean };
  // 0400: demo mode (Fleet tracking settings) puts the simulated cars on the fleet layer while no tracker reports
  if (raw.tracker_demo && !raw.fleet.length) {
    const fleet = await demoFleet(adminId, aal);
    if (fleet.length) return { ...toView({ ...raw, fleet }, contact), fleet_demo: true };
  }
  return toView(raw, contact);
}

async function demoFleet(adminId: string, aal?: 'aal1' | 'aal2' | null): Promise<FleetCar[]> {
  const f = await door<Fleet>(adminId, 'ops_read', 'tracker_fleet', {}, aal).catch(() => null);
  if (!f) return [];
  const now = Date.now();
  return withDemo(f, now).cars.filter((c) => c.pos).map((c): FleetCar => ({
    vehicle_id: c.vehicle_id, code: c.code, name: c.name, lat: c.pos!.lat, lng: c.pos!.lng, heading: stateOf(c, now) === 'moving' ? c.pos!.heading : null, speed: c.pos!.speed,
    status: c.booking?.status === 'on_rent' ? 'on_rent' : c.status === 'available' || c.status === 'ready_to_list' ? 'available' : 'in_service', updated_at: c.pos!.at,
    photo: (c.photo as FleetCar['photo']) ?? null }));
}

/** The staff Visitors page's map (r27 consolidation, migration 0500): customer service and Sales, through va_read live_map
 *  (the database checks the function again and leaves out the fleet layer and the money). Read afresh each time: the
 *  answer depends on the person. */
export async function staffLiveMap(userId: string, contact: boolean, aal?: 'aal1' | 'aal2' | null): Promise<MapView> {
  return toView(await readParts(userId, 'va_read', aal), contact);
}
