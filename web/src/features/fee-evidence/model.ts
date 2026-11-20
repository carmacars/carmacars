// r48 FE (3190): the evidence every fee needs. Pure: the words the Money tab, the Checklist and the guides share.

/** What each kind of evidence is called (the database's app.fee_evidence_label says the same). */
export const EVIDENCE_LABEL: Record<string, string> = {
  return_time: 'the return time', tracker_at_return: 'the Tracker location at the return', late_notices: 'the late notices sent',
  final_notice: 'the final late notice with its deadline passed', readings_km: 'the odometer at pickup and at return',
  readings_fuel: 'the fuel or battery level at pickup and at return', trip_photos: 'the pickup and return photos', guided_photos: 'the guided evidence photos',
  clean_description: 'a written description', clean_video: 'a video', toll_notice: 'the 407 statement line', toll_route: 'the Tracker route',
  ticket_notice: 'the ticket notice PDF', speed_series: 'the Tracker speed readings', tracker_map: 'the Tracker readings and map', damage_closeups: 'the damage close-ups',
  pickup_photos: 'the pickup photos', receipt: 'the receipt or invoice', callout_invoice: 'the tire or roadside invoice', keys_reading: 'the keys returned',
  police_or_incident: 'the theft incident with the police report', improper_proof: 'photos or the Tracker location at the return', staff_note: 'a note of what was wrong',
  booking_record: 'the booking record', signed_clause: 'the signed clause', photos: 'photos'
};
export const evidenceLabel = (k: string): string => EVIDENCE_LABEL[k] ?? k.replace(/_/g, ' ');

export type EvidenceStatus = 'ok' | 'needs_evidence' | 'overridden' | 'not_required';
export const STATUS_WORDS: Record<EvidenceStatus, string> = { ok: 'Evidence complete', needs_evidence: 'Needs evidence: not charged yet', overridden: 'Charged without evidence (Admin)', not_required: 'No evidence needed' };

/** The return charges of the rental agreement (10.6 to 10.8, 11.6), as the Money tab offers them. */
export const RETURN_CHARGES: Array<[string, string]> = [['improper_return', 'Improper return ($250 + costs)'], ['non_return', 'Non-return ($1,000 + recovery costs)'],
  ['theft_recovery', 'Theft recovery ($1,500 + costs)'], ['tire', 'Flat tire or blowout (cost + $50)'], ['roadside', 'Roadside call-out: tow, boost, lockout, fuel (cost + $50)']];
export const IMPROPER_REASONS: Array<[string, string]> = [['', 'Only for an improper return'], ['wrong_place', 'Left at the wrong place'], ['keys_not_returned', 'Keys not returned'],
  ['unlocked', 'Left unlocked'], ['unsecured', 'Left unsecured (windows, sunroof, trunk)'], ['unagreed_drop', 'A drop-off we did not agree to']];

/** The guided photos of a return that is not clean (app.clean_evidence_shots). */
export const CLEAN_SHOTS: Array<{ shot: string; label: string; tip: string }> = [
  { shot: 'clean_ash', label: 'Ash, butts, burns or residue', tip: 'Close up, with the spot in frame: ash, a butt, a burn hole, vape residue.' },
  { shot: 'clean_seats', label: 'Seats', tip: 'Each stained or burned seat, the whole seat then the mark.' },
  { shot: 'clean_headliner', label: 'Headliner', tip: 'The roof lining above the seats: yellowing, stains, burns.' },
  { shot: 'clean_cupholders', label: 'Ashtray and cupholders', tip: 'Ash or butts in the ashtray, cupholders and door pockets.' },
  { shot: 'clean_floor', label: 'Floor and mats', tip: 'The mats and the carpet under them: ash, mud, spills, pet hair.' },
  { shot: 'clean_other', label: 'Anything else', tip: 'The trunk, the smell source, a bag of trash left behind.' }
];
/** The seq numbers of the guided shots on the return report (damage close-ups use 20 and up). */
export const CLEAN_SEQ0 = 40;
export const CLEAN_MIN = 3;
export const DESCRIPTION_MIN = 15;

/** What a return that is not clean still lacks, in the Checklist's words (null: nothing). */
export function cleanMissing(cleanliness: string | undefined, photos: number, description: string | undefined, min = CLEAN_MIN): string | null {
  if (!cleanliness || cleanliness === 'clean') return null;
  if (photos < min) return `${min - photos} more evidence photo${min - photos === 1 ? '' : 's'}`;
  if ((description ?? '').trim().length < DESCRIPTION_MIN) return 'A written description';
  return null;
}

/** The Checklist's answer as the database keeps it (the old screen saved needs_cleaning and pet_hair, which it refused). */
export const CLEAN_CHOICES: Array<[string, string]> = [['clean', 'Standard'], ['cleaning', 'Needs cleaning'], ['heavy', 'Heavy soiling or odour'], ['pet', 'Pet hair'], ['smoking', 'Smoking evidence']];
/** The fee a return that is not clean drafts (assess_check_in), for the Checklist's note. */
export const CLEAN_FEE: Record<string, string> = { cleaning: 'the cleaning fee', heavy: 'the heavy cleaning fee', pet: 'the pet cleaning fee', smoking: 'the $300 smoking fee' };
