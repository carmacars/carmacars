// Tracker events (migration 3320): what the database's read (ops_read tracker_events) returns, and the words the screens
// use for an event, its source, its charge and its seal. No imports but the alert labels: unit tested in Node (events.test.ts).
import { ALERT, type AlertKind } from './model.ts';

export interface EventLine { id: string; amount_cents: number; evidence_status: string | null; on_statement: boolean }
export type TrackerEvent = {
  id: string; alert_id: string | null; kind: AlertKind; tier: number | null; title: string; detail: string | null; at: string; lat: number | null; lng: number | null;
  speed_kmh: number | null; source: string; device: string | null; clause: string | null; fee_code: string | null; fee_cents: number | null; chargeable: boolean;
  vehicle: string | null; vehicle_id: string; booking_number: string | null; readings: number; sealed: boolean; sha256: string | null;
  renter_notice_at: string | null; owner_notice_at: string | null; seen: boolean; line: EventLine | null;
};
export type PoundFlag = {
  id: string; status: 'open' | 'charged' | 'recovered' | 'dismissed'; path: string | null; note: string | null; lot_name: string; lot_address: string | null; lot_phone: string | null;
  lot_hours: string | null; since: string; vehicle: string | null; vehicle_id: string; booking_number: string | null; evidence_id: string | null; resolved_at: string | null; resolved_by: string | null;
};
export type PoundLot = {
  id: string; name: string; address: string; city: string | null; phone: string | null; hours: string | null; serves: string | null; latitude: number | null; longitude: number | null;
  radius_m: number | null; notes: string | null; is_active: boolean; checked: boolean; source_url: string | null;
};
export interface EventSettings {
  events_on: boolean; renter_notices: boolean; owner_notices: boolean; event_window_minutes: number; harsh_on: boolean; harsh_kmh_per_s: number; harsh_count: number;
  night_on: boolean; night_from: string; night_to: string; pound_radius_m: number; pound_minutes: number; ingest_per_minute: number; speed_alert_kmh: number;
}
export interface TrackerEvents {
  on: boolean; settings: EventSettings; fees: { speeding_180: number; speeding_220: number; speeding_300: number; non_return: number; theft_recovery: number };
  can: { manage: boolean; charge: boolean; resolve: boolean }; events: TrackerEvent[]; flags: PoundFlag[]; lots: PoundLot[];
}
export interface OwnerEvent { id: string; kind: AlertKind; tier: number | null; vehicle_id: string; vehicle: string | null; at: string; lat: number | null; lng: number | null; speed_kmh: number | null; what: string | null; title: string | null }

const dollars = (cents: number) => `$${(cents / 100).toLocaleString('en-CA', { minimumFractionDigits: cents % 100 ? 2 : 0, maximumFractionDigits: 2 })}`;

/** The event in a few words: "Speeding over 220 km/h", "Harsh driving", "At a pound". */
export function eventLabel(e: Pick<TrackerEvent, 'kind' | 'tier'>): string {
  if (e.kind === 'speeding') return e.tier ? `Speeding over ${e.tier} km/h` : 'Over the speeding alert level';
  return ALERT[e.kind]?.label ?? e.kind.replace(/_/g, ' ');
}
export const eventTone = (e: Pick<TrackerEvent, 'kind' | 'tier'>): 'red' | 'amber' | 'grey' => (e.kind === 'speeding' && !e.tier ? 'amber' : ALERT[e.kind]?.tone ?? 'grey');

const SOURCE: Record<string, string> = { reading: 'A tracker reading', device_event: 'The tracker\'s own alarm', derived: 'Worked out from readings', job: 'The hourly check' };
export const sourceLabel = (s: string): string => SOURCE[s] ?? s.replace(/_/g, ' ');

/** What the event costs the renter, in plain words. */
export function feeLine(e: Pick<TrackerEvent, 'kind' | 'tier' | 'fee_cents' | 'fee_code'>, fees?: TrackerEvents['fees']): string {
  if (e.kind === 'speeding' && e.tier && e.fee_cents != null) return `${dollars(e.fee_cents)} plus HST`;
  if (e.kind === 'pound') return fees ? `Recovery costs at cost; ${dollars(fees.non_return)} non-return or ${dollars(fees.theft_recovery)} theft recovery` : 'Recovery costs at cost; the non-return or theft recovery charge';
  if (e.kind === 'overdue_driving') return 'Late return fee and extra days';
  return 'No set charge';
}

/** The state of an event's charge: what the last column says. */
export function chargeState(e: Pick<TrackerEvent, 'chargeable' | 'line' | 'kind' | 'booking_number'>): 'charged' | 'waiting_evidence' | 'can_charge' | 'pound' | 'no_renter' | 'none' {
  if (e.line) return e.line.evidence_status === 'needs_evidence' ? 'waiting_evidence' : 'charged';
  if (e.kind === 'pound') return 'pound';
  if (e.chargeable) return 'can_charge';
  if (e.kind === 'speeding' && !e.booking_number) return 'no_renter';
  return 'none';
}

/** The first and last characters of the seal, enough to compare with the dispute pack. */
export const sealShort = (sha: string | null | undefined): string => (sha && sha.length >= 16 ? `${sha.slice(0, 8)}…${sha.slice(-6)}` : 'not sealed yet');

export const mapUrl = (p: { lat: number | null; lng: number | null }): string | null => (p.lat != null && p.lng != null ? `https://www.google.com/maps?q=${p.lat},${p.lng}` : null);

/** Who was told, in a few words. */
export function toldLine(e: Pick<TrackerEvent, 'renter_notice_at' | 'owner_notice_at'>): string {
  const who = [e.renter_notice_at ? 'renter' : null, e.owner_notice_at ? 'owner' : null].filter(Boolean);
  return who.length ? `Staff, ${who.join(' and ')}` : 'Staff only';
}

export const PATHS: Array<[string, string]> = [
  ['non_return', 'Non-return charge and the recovery costs (10.6)'],
  ['theft_recovery', 'Theft recovery charge and the costs (10.8)'],
  ['no_charge', 'Recovered, nothing to charge'],
  ['not_a_pound', 'Not a pound (a wrong match)']
];
export const pathLabel = (p: string | null | undefined): string => PATHS.find(([k]) => k === p)?.[1] ?? '';

/** The lots that still need something before they can flag a car. */
export function lotIssues(l: Pick<PoundLot, 'latitude' | 'longitude' | 'checked' | 'is_active' | 'phone' | 'hours'>): string[] {
  const out: string[] = [];
  if (!l.is_active) return ['Off'];
  if (l.latitude == null || l.longitude == null) out.push('No pin yet');
  if (!l.checked) out.push('Not checked');
  if (!l.hours) out.push('Hours missing');
  if (!l.phone) out.push('Phone missing');
  return out;
}
