// The handover checklist of a field job, on the phone: the photos, the odometer, the fuel, the keys, any damage and the
// signatures. The database completes a pickup or a return in one step and refuses anything missing; this says what is
// still to do before the button is pressed, in the order it is done, so nobody finds out at the end. It mirrors the
// site's checklist (web/src/features/field/Checklist.tsx). No imports.
export interface Shot { seq: number; shot: string; guide: string | null }
export interface Damage { label: string; location: string; description: string; kind: string; size_cm: number | null; position: null; is_new: boolean }
export interface Draft {
  odometer_km: string; fuel_pct: number | null; keys_count: number | null; cleanliness: string | null; notes: string;
  licence_seen: boolean; card_seen: boolean; renter_present: boolean;
  renter_signature_ref: string | null; staff_signature_ref: string | null; renter_declined_to_sign: boolean; renter_decline_reason: string;
  damages: Damage[];
  /** the shots already taken (on the server's report, or uploaded from this phone) */
  shotsDone: string[];
}
export interface JobFacts { kind: 'pickup' | 'return' | 'ready' | null; shots: Shot[]; unattended: boolean; detailsLater: boolean; odometerOutKm: number | null }

export const LOCATIONS = ['front bumper', 'hood', 'windshield', 'roof', 'left front door', 'left rear door', 'left side', 'right front door', 'right rear door', 'right side', 'rear bumper', 'trunk', 'wheel or tire', 'mirror', 'interior', 'other'] as const;
export const DAMAGE_KINDS = ['scratch', 'dent', 'chip', 'crack', 'scuff', 'stain', 'tear', 'other'] as const;
export const CLEANLINESS: ReadonlyArray<readonly [string, string]> = [['clean', 'Standard'], ['needs_cleaning', 'Needs cleaning'], ['heavy', 'Heavy soiling or odour'], ['pet_hair', 'Pet hair'], ['smoking', 'Smoking evidence']];
export const shotName = (s: string) => { const t = s.replace(/_/g, ' '); return t.charAt(0).toUpperCase() + t.slice(1); };

export function emptyDraft(report?: { odometer_km: number | null; fuel_pct: number | null; keys_count: number | null; cleanliness: string | null; photos: Array<{ shot: string }>; damages: Array<Partial<Damage>> } | null,
  defaults?: { odometer_km?: number | null; fuel_pct?: number | null } | null): Draft {
  return {
    odometer_km: report?.odometer_km != null ? String(report.odometer_km) : defaults?.odometer_km != null ? String(defaults.odometer_km) : '',
    fuel_pct: report?.fuel_pct ?? defaults?.fuel_pct ?? null, keys_count: report?.keys_count ?? null, cleanliness: report?.cleanliness ?? null, notes: '',
    licence_seen: false, card_seen: false, renter_present: true, renter_signature_ref: null, staff_signature_ref: null, renter_declined_to_sign: false, renter_decline_reason: '',
    damages: (report?.damages ?? []).map((d) => ({ label: d.label ?? '', location: d.location ?? 'other', description: d.description ?? '', kind: d.kind ?? 'other', size_cm: d.size_cm ?? null, position: null, is_new: d.is_new ?? true })),
    shotsDone: [...new Set((report?.photos ?? []).map((p) => p.shot))]
  };
}

export interface Section { key: 'photos' | 'readings' | 'damage' | 'checks' | 'signatures'; title: string; done: boolean; problems: string[] }
/** Each part of the handover with what it still needs. */
export function sections(j: JobFacts, d: Draft): Section[] {
  const pickup = j.kind === 'pickup';
  const unattended = j.unattended || j.detailsLater;
  const missingShots = j.shots.filter((s) => !d.shotsDone.includes(s.shot));
  const photos = missingShots.length ? [`${missingShots.length} photo${missingShots.length === 1 ? '' : 's'} to take: ${missingShots.slice(0, 3).map((s) => shotName(s.shot)).join(', ')}${missingShots.length > 3 ? '…' : ''}`] : [];
  const km = d.odometer_km.replace(/[\s,]/g, '');
  const readings: string[] = [];
  if (!/^\d{1,7}$/.test(km)) readings.push('Enter the odometer in whole kilometres.');
  else if (!pickup && j.odometerOutKm !== null && Number(km) < j.odometerOutKm) readings.push(`The odometer is lower than at pickup (${j.odometerOutKm.toLocaleString('en-CA')} km). Check it.`);
  if (d.fuel_pct === null) readings.push('Pick the fuel level.');
  if (d.keys_count === null) readings.push('Count the keys.');
  if (!j.detailsLater && !d.cleanliness) readings.push('Say how clean the car is.');
  const damage = d.damages.flatMap((x, i) => (!x.description.trim() || !x.location ? [`Damage ${i + 1}: say where it is and describe it.`] : []));
  const checks: string[] = [];
  if (pickup && !unattended && !d.licence_seen) checks.push('Check the driver\'s licence.');
  if (pickup && !unattended && !d.card_seen) checks.push('Check the card.');
  const sign: string[] = [];
  if (!d.staff_signature_ref) sign.push('Sign as CarmaCars staff.');
  const renterSigned = !!d.renter_signature_ref;
  if (pickup) { if (!unattended && !renterSigned) sign.push('The renter signs.'); }
  else if (!j.detailsLater && !(renterSigned || (d.renter_declined_to_sign && d.renter_decline_reason.trim()) || !d.renter_present)) sign.push('The renter signs, or say why not.');
  const part = (key: Section['key'], title: string, problems: string[]): Section => ({ key, title, done: problems.length === 0, problems });
  return [part('photos', 'Photos', photos), part('readings', 'Odometer, fuel and keys', readings), part('damage', 'Damage', damage),
    ...(pickup && !unattended ? [part('checks', 'Licence and card', checks)] : []), part('signatures', 'Signatures', sign)];
}
/** The first thing still to do, or null when the handover can be completed. */
export const firstProblem = (j: JobFacts, d: Draft): string | null => sections(j, d).flatMap((s) => s.problems)[0] ?? null;

/** What is sent with save_report, complete_handover and complete_return. */
export function reportPayload(j: JobFacts, d: Draft): Record<string, unknown> {
  const unattended = j.unattended || j.detailsLater;
  const out: Record<string, unknown> = {
    odometer_km: /^\d{1,7}$/.test(d.odometer_km.replace(/[\s,]/g, '')) ? Number(d.odometer_km.replace(/[\s,]/g, '')) : undefined,
    fuel_pct: d.fuel_pct ?? undefined, keys_count: d.keys_count ?? undefined, cleanliness: d.cleanliness ?? undefined, notes: d.notes.trim() || undefined,
    licence_seen: d.licence_seen, card_seen: d.card_seen, renter_present: unattended ? false : d.renter_present, unattended,
    renter_signature_ref: d.renter_signature_ref ?? undefined, staff_signature_ref: d.staff_signature_ref ?? undefined,
    renter_declined_to_sign: d.renter_declined_to_sign || undefined, renter_decline_reason: d.renter_declined_to_sign ? d.renter_decline_reason.trim() : undefined,
    damages: d.damages
  };
  if (j.kind === 'pickup') out.fuel_or_charge_ok = (d.fuel_pct ?? 0) >= 80;
  for (const k of Object.keys(out)) if (out[k] === undefined) delete out[k];
  return out;
}

// ---------------------------------------------------------------- clocking in and out
export interface Fix { lat: number; lng: number; accuracy: number; located_at: string }
/** Clocking needs where the phone is, or the reason it cannot say (the database keeps either; an Admin sees the map). */
export function clockProblem(fix: Fix | null, reason: string): string | null {
  if (fix) return null;
  return reason.trim().length >= 5 ? null : 'Location is off. Turn it on, or say why this phone cannot share it.';
}
/** "2 h 05 min" since a shift started. */
export function elapsed(startedIso: string, now: number = Date.now()): string {
  const m = Math.max(0, Math.floor((now - new Date(startedIso).getTime()) / 60000));
  return `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, '0')} min`;
}
