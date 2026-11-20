// The fake tracker provider (migration 3320): the readings a tracker would send for each event of Tracker events, in the
// ingest's generic JSON, so the unit, database and end-to-end tests (and a demonstration) exercise the whole path before
// CarmaCars' own trackers are installed. No imports and no network: `fakeScenario` returns points to sign and post to
// /api/tracker/ingest (scripts/tracker-sim.mjs and the e2e test do that); nothing here runs in production.
import type { Point } from './ingest.ts';

export type FakeScenario = 'speeding_180' | 'speeding_220' | 'speeding_300' | 'slow_down' | 'harsh_driving' | 'tamper' | 'unplugged' | 'pound' | 'left_ontario';
export const FAKE_SCENARIOS: readonly FakeScenario[] = ['speeding_180', 'speeding_220', 'speeding_300', 'slow_down', 'harsh_driving', 'tamper', 'unplugged', 'pound', 'left_ontario'];

export interface FakeOptions {
  /** when the last reading is taken (ms since 1970); the scenario runs up to it */
  end?: number;
  /** where the car is (Highway 401 at Yonge by default) */
  lat?: number; lng?: number;
  /** pound: the lot's pin, and how long the car has been parked there (minutes) */
  lot?: { lat: number; lng: number }; parkedMinutes?: number;
}

const iso = (ms: number) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
/** six decimals, as a tracker reports (the ingest refuses a coordinate with more than twelve) */
const r6 = (n: number) => Math.round(n * 1e6) / 1e6;
const PEAK: Partial<Record<FakeScenario, number>> = { speeding_180: 187, speeding_220: 226, speeding_300: 304, slow_down: 152 };

/** The readings of one scenario for one device, oldest first, 10 seconds apart unless the scenario says otherwise. */
export function fakeScenario(device: string, scenario: FakeScenario, o: FakeOptions = {}): Point[] {
  const end = o.end ?? Date.now(), lat = o.lat ?? 43.7615, lng = o.lng ?? -79.4111;
  const at = (secondsBefore: number) => iso(end - secondsBefore * 1000);
  const pt = (secondsBefore: number, speed: number, extra: Partial<Point> = {}, dLng = 0): Point =>
    ({ device, at: at(secondsBefore), lat: r6(lat), lng: r6(lng + dLng), speed, heading: 90, ignition: speed > 0 || extra.ignition === true, battery: 90, power: true, ...extra });
  switch (scenario) {
    case 'speeding_180': case 'speeding_220': case 'speeding_300': case 'slow_down': {
      // up to the peak and back: three readings over the limit in a row make one record, not three
      const peak = PEAK[scenario]!;
      return [pt(60, 110, {}, -0.03), pt(50, peak - 20, {}, -0.025), pt(40, peak, {}, -0.02), pt(30, peak - 2, {}, -0.015), pt(20, peak - 4, {}, -0.01), pt(10, 118, {}, -0.005), pt(0, 105)];
    }
    case 'harsh_driving':
      // two events the tracker reports itself, then 80 to 10 km/h in five seconds (worked out from the readings)
      return [pt(120, 70, { event: 'harsh_accel' }, -0.02), pt(90, 85, { event: 'harsh_brake' }, -0.015), pt(15, 80, {}, -0.005), pt(10, 10, {}, -0.004), pt(0, 30)];
    case 'tamper':
      return [pt(20, 0, { ignition: false }), pt(10, 0, { ignition: false, event: 'tamper' }), pt(0, 0, { ignition: false, event: 'tamper' })];
    case 'unplugged':
      return [pt(20, 0, { ignition: false }), pt(10, 0, { ignition: false, power: false, battery: 71 }), pt(0, 0, { ignition: false, power: false, battery: 70 })];
    case 'pound': {
      const lot = o.lot ?? { lat, lng }, mins = Math.max(1, o.parkedMinutes ?? 30);
      const park = (secondsBefore: number): Point => ({ device, at: at(secondsBefore), lat: r6(lot.lat), lng: r6(lot.lng), speed: 0, heading: 0, ignition: false, battery: 88, power: true });
      // towed in (ignition off, moving), then parked inside the lot: a reading when it arrives, one in the middle, one now
      return [{ ...park(mins * 60 + 300), lat: r6(lot.lat - 0.02), speed: 35 }, park(mins * 60), park(Math.round(mins * 30)), park(0)];
    }
    case 'left_ontario':
      // Buffalo, across the Peace Bridge
      return [{ ...pt(60, 50), lat: 42.9, lng: -78.95 }, { ...pt(0, 45), lat: 42.886, lng: -78.878 }];
  }
}
