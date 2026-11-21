// Location on the live map (release 48, migration 3350): when the app takes the phone's position and when it sends one.
// No React and no native modules, so the unit test runs it in Node. The database still decides on every report
// (ops_do location_report); these rules only keep the app from reading the location when it would not be kept:
//   staff     only once the electronic monitoring policy is accepted, and only on shift or on an active job, never off
//             duty; during an active job the switch cannot be turned off (the server says `locked`)
//   renters   and owners: only two hours either side of a pickup or return (the server's booking window), never otherwise
//   everyone  only with the phone's own permission; in the background only with "Always" / "Allow all the time"
import { goodFix, type BodyOf, type MyLocation } from '../shared.ts';

export type Grant = 'granted' | 'denied' | 'undetermined';
export interface Perms { foreground: Grant; background: Grant }
/** off: nothing is read. foreground: only while the app is open. background: the task keeps reporting with the app closed. */
export type Mode = 'off' | 'foreground' | 'background';
export interface Plan { mode: Mode; why: 'signed_out' | 'unknown' | 'not_now' | 'policy' | 'off' | 'permission' | 'share' }
export interface Fix { lat: number; lng: number; accuracy: number | null; at: number; speed?: number | null }
export interface Sent { fix: Fix; at: number }

/** The fastest the app sends while moving (the database keeps at most one each 20 seconds). */
export const MOVING_MS = 30_000;
/** Moving: at least this far from the last position sent (or the fix's own accuracy, if worse). */
export const MOVED_M = 25;
/** Moving by the phone's own speed reading (metres a second; a walk is about 1.4). */
export const MOVING_SPEED = 1.5;
/** The phone's own filters for the background task. */
export const TASK_OPTIONS = { timeInterval: MOVING_MS, distanceInterval: MOVED_M } as const;

const isStaff = (s: MyLocation) => s.kind === 'staff';
export const policyAccepted = (s: MyLocation | null): boolean => !!s?.policy?.accepted_at;
/** Staff who have not accepted the electronic monitoring policy: nothing is shared until they do. */
export const needsPolicy = (s: MyLocation | null): boolean => !!s && isStaff(s) && !!s.policy && !policyAccepted(s);
/** Whether the switch may be turned off now: never by staff during an active job. */
export const canSwitchOff = (s: MyLocation | null): boolean => !(s && isStaff(s) && s.locked);
/** Staff may share with the app closed (on shift, on a job); renters and owners only while the app is open. */
export const wantsBackground = (s: MyLocation | null): boolean => !!s && isStaff(s);

/** Whether this person qualifies now, from the server's answer alone (the same rules as the database's location_state). */
export function qualifies(s: MyLocation | null): boolean {
  if (!s || !s.kind || !s.share) return false;
  if (isStaff(s)) {
    if (!policyAccepted(s)) return false;
    // on an active job it is always on; on shift only with the switch on; off duty never
    if (s.field_job_id || s.reason === 'job') return true;
    return !!s.on_shift && s.sharing_on !== false;
  }
  // renters and owners: a booking at a pickup or return now, with the switch on
  return s.sharing_on !== false && !!s.booking_id && (s.reason === 'pickup' || s.reason === 'return');
}

/** What to run: nothing, a watch while the app is open, or the background task. */
export function decide(s: MyLocation | null, perms: Perms, signedIn: boolean): Plan {
  if (!signedIn) return { mode: 'off', why: 'signed_out' };
  if (!s || !s.kind) return { mode: 'off', why: 'unknown' };
  if (needsPolicy(s)) return { mode: 'off', why: 'policy' };
  if (s.sharing_on === false && !(isStaff(s) && s.locked)) return { mode: 'off', why: 'off' };
  if (!qualifies(s)) return { mode: 'off', why: 'not_now' };
  if (perms.foreground !== 'granted') return { mode: 'off', why: 'permission' };
  return { mode: wantsBackground(s) && perms.background === 'granted' ? 'background' : 'foreground', why: 'share' };
}

/** Metres between two points (haversine). */
export function distanceM(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const R = 6_371_000, rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad, dLng = (b.lng - a.lng) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Whether this fix is sent: the first good one at once; then at most every 30 seconds, and only while moving (none while still). */
export function shouldSend(last: Sent | null, fix: Fix, now = Date.now()): boolean {
  if (!goodFix(fix, now)) return false;
  if (!last) return true;
  if (now - last.at < MOVING_MS) return false;
  const moved = distanceM(last.fix, fix) >= Math.max(MOVED_M, Math.min(fix.accuracy ?? 0, 200));
  return moved || (fix.speed ?? 0) >= MOVING_SPEED;
}

/** After a report: keep going, or ask the server again (it said no: a shift ended, a pickup window closed, turned off). */
export function afterReport(r: { ok: true; data: { stored?: boolean; why?: string } } | { ok: false; code: string }): 'keep' | 'recheck' | 'stop' {
  if (!r.ok) return r.code === 'auth' || r.code === 'expired' ? 'stop' : 'keep';
  if (r.data.stored === false && r.data.why !== 'soon' && r.data.why !== 'stale') return 'recheck';
  return 'keep';
}

type Body = BodyOf<'me.locationAct'>;
const body = (b: Partial<Body> & Pick<Body, 'action'>): Body => ({ lat: undefined, lng: undefined, accuracy_m: undefined, at: undefined, sharing_on: undefined, version: undefined, ...b });
/** The body of a report, rounded as the site's own reports are. */
export function reportBody(f: Fix): Body {
  return body({ action: 'report', lat: Math.round(f.lat * 1e6) / 1e6, lng: Math.round(f.lng * 1e6) / 1e6, accuracy_m: Math.min(100_000, Math.max(0, Math.round(f.accuracy ?? 0))), at: new Date(f.at).toISOString() });
}
/** The switch. */
export const prefsBody = (on: boolean): Body => body({ action: 'prefs', sharing_on: on });
/** Staff: the electronic monitoring policy, this version. */
export const policyBody = (version: string): Body => body({ action: 'policy', version });

/** The switch's line under it, as the site's card says it. */
export function switchLine(s: MyLocation): string {
  if (isStaff(s)) return s.locked ? 'On during an active job; you can turn it off once the job is done.' : 'Only while you are on shift or on a job, never off duty. Admins and Fleet see it.';
  return 'Only two hours either side of your pickup or return, so the team can meet you. Never otherwise.';
}

/** The permission line on the settings screen ('' when nothing is missing). */
export function permissionLine(s: MyLocation | null, p: Perms): string {
  if (!s || s.sharing_on === false) return '';
  if (p.foreground === 'denied') return 'Location is off for CarmaCars in the phone\'s settings. Turn it on there to share.';
  if (p.foreground !== 'granted') return 'Allow location on this phone so it can be shared when it qualifies.';
  if (wantsBackground(s) && p.background !== 'granted') return 'Shared only while the app is open. Choose "Always" (iPhone) or "Allow all the time" (Android) to keep sharing on shift with the app closed.';
  return '';
}
