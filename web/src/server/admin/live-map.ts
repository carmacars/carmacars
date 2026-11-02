import 'server-only';
import { door } from '@/server/door';
import { env } from '@/lib/env';
import { CACHE_MS } from '@/features/live-map/config';
import { toView, type FleetCar, type MapView, type RawMap } from '@/features/live-map/model';
import { stateOf, withDemo, type Fleet } from '@/features/tracking/model';

// The Live map's read (migration 0242): one call through the door (admin_read live_map; the database checks the Admin
// again), kept 20 seconds in this Worker instance so a TV and a laptop refreshing together cost one read. The answer is
// the same for every Admin; it is only reused after the caller passed the Admin check. Phones and emails only with `contact` (Release 26). Outside
// production every call reads afresh (the end-to-end tests change the data between two loads).
let kept: { at: number; data: RawMap } | null = null;
let pending: Promise<RawMap> | null = null;

export async function liveMap(adminId: string, contact: boolean, aal?: 'aal1' | 'aal2' | null): Promise<MapView> {
  const now = Date.now();
  const keep = env().APP_ENV === 'production' ? CACHE_MS : 0;
  if (!kept || now - kept.at >= keep) {
    pending ??= door<RawMap>(adminId, 'admin_read', 'live_map', {}, aal).then((data) => { kept = { at: Date.now(), data }; return data; }).finally(() => { pending = null; });
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
  const raw = await door<RawMap>(userId, 'va_read', 'live_map', {}, aal);
  return toView(raw, contact);
}
