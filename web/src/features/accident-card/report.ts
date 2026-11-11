import { imageSniff } from '../../lib/file-sniff.ts';
// The renter's accident report (release 35, migration 0912): what the form sends, checked the same way on the phone and the
// server, and the kind of each uploaded file from its first bytes. Pure: the form, the route and the unit tests share it.
export const ACCIDENT_MEDIA_MAX = 25 * 1024 * 1024;

/** A photo or a video, from its first bytes: JPEG, PNG, MP4, QuickTime or WebM. */
export function mediaKind(b: Uint8Array): { ext: 'jpg' | 'png' | 'mp4' | 'mov' | 'webm'; mime: string; video: boolean } | null {
  const { jpg, png } = imageSniff(b);
  if (jpg) return { ext: 'jpg', mime: 'image/jpeg', video: false };
  if (png) return { ext: 'png', mime: 'image/png', video: false };
  if (b[0] === 0x1a && b[1] === 0x45 && b[2] === 0xdf && b[3] === 0xa3) return { ext: 'webm', mime: 'video/webm', video: true };
  if (b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) {
    const brand = String.fromCharCode(b[8] ?? 0, b[9] ?? 0, b[10] ?? 0, b[11] ?? 0);
    return brand === 'qt  ' ? { ext: 'mov', mime: 'video/quicktime', video: true } : { ext: 'mp4', mime: 'video/mp4', video: true };
  }
  return null;
}

export interface AccidentDraft {
  description: string; occurred_at: string; place: string; latitude: number | null; longitude: number | null;
  other_name: string; other_phone: string; other_plate: string; other_coverage: string; police: string;
  anyone_hurt: '' | 'yes' | 'no'; drivable: '' | 'yes' | 'no';
  media: Array<{ bucket: string; path: string; video: boolean; name: string }>;
}
export const emptyDraft = (): AccidentDraft => ({ description: '', occurred_at: '', place: '', latitude: null, longitude: null, other_name: '', other_phone: '',
  other_plate: '', other_coverage: '', police: '', anyone_hurt: '', drivable: '', media: [] });

/** What is still missing, in the renter's words; null when the report can be sent. */
export function draftProblem(d: AccidentDraft, now: Date = new Date()): string | null {
  if (d.description.trim().length < 5) return 'Say what happened.';
  if (d.occurred_at && new Date(d.occurred_at).getTime() > now.getTime() + 5 * 60_000) return 'The time of the accident cannot be in the future.';
  if (!d.anyone_hurt) return 'Is anyone hurt? Answer yes or no.';
  if (!d.drivable) return 'Can the car be driven? Answer yes or no.';
  return null;
}

/** The report as the database takes it (app.renter_accident_report). */
export function draftPayload(booking: string, d: AccidentDraft): Record<string, unknown> {
  const other = { name: d.other_name.trim(), phone: d.other_phone.trim(), plate: d.other_plate.trim(), coverage: d.other_coverage.trim() };
  return {
    booking, description: d.description.trim(), occurred_at: d.occurred_at ? new Date(d.occurred_at).toISOString() : null, place: d.place.trim() || null,
    latitude: d.latitude, longitude: d.longitude, other_party: Object.values(other).some(Boolean) ? other : null, police_report_number: d.police.trim() || null,
    anyone_hurt: d.anyone_hurt === 'yes', drivable: d.drivable === 'yes', media: d.media.map(({ bucket, path }) => ({ bucket, path }))
  };
}
