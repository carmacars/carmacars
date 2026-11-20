// The pickup identity check (release 48 ops, migrations 3292 and 3293): is the person taking the car the renter? What the
// step shows and the words for each result. The comparing is done in the database (app.pickup_identity_record).
export type Result = 'match' | 'mismatch' | 'unclear' | 'not_checked';
export type Outcome = 'match' | 'mismatch' | 'unclear';
export type Answer = 'yes' | 'no' | '';
export interface Results { name: Result; number: Result; expiry: Result; face: Result; card_last4: Result; card_name: Result }
export interface Upload { id: string; kind: string }
export interface PickupDriver { driver_id: string; name: string; role: string; licence_number: string | null; licence_expiry: string | null; on_file: Upload[] | null; at_pickup: Upload[] | null }
export interface LastCheck {
  id: string; at: string; outcome: Outcome; by_renter: boolean; by: string | null; mismatches: string[]; coverage_problem: boolean;
  read: { name: string | null; number: string | null; expiry: string | null } | null; results: Results;
}
export interface PickupView {
  booking_id: string; booking_number: string; staff: boolean; open: boolean; booking_name: string | null; coverage_card: boolean; marked: boolean;
  drivers: PickupDriver[]; card: { brand: string | null; last4: string | null; name: string | null } | null; last: LastCheck | null;
}
export interface CheckDone { outcome: Outcome; mismatches: string[]; coverage_problem: boolean; results: Results }

export const FLAG_TITLE = 'Possible wrong person at pickup';
const LABEL: Record<keyof Results, string> = {
  name: 'Name', number: 'Licence number', expiry: 'Expiry', face: 'Face', card_last4: 'Card, last 4 digits', card_name: 'Name on the card'
};
const WORD: Record<Result, string> = { match: 'Matches', mismatch: 'Does not match', unclear: 'Could not tell', not_checked: 'Not checked' };
export const UPLOAD_LABEL: Record<string, string> = {
  licence_front: 'Licence on file', selfie: 'Selfie on file', licence_front_pickup: 'Licence shown at pickup', licence_back_pickup: 'Back of the licence shown at pickup', selfie_pickup: 'Selfie at pickup'
};

/** The lines of a check, in the order they are read: what was compared and how it came out. */
export function resultLines(r: Results, staff: boolean): Array<{ key: keyof Results; label: string; result: Result; word: string }> {
  const keys: Array<keyof Results> = staff ? ['name', 'number', 'expiry', 'face', 'card_last4', 'card_name'] : ['name', 'number', 'expiry', 'face'];
  return keys.map((key) => ({ key, label: LABEL[key], result: r[key], word: WORD[r[key]] }));
}

/** One sentence for the person at the car. A mismatch never says "stop": the check never blocks the pickup. */
export function outcomeWords(o: Outcome, staff: boolean): string {
  if (o === 'match') return 'Checked: it matches what is on file.';
  if (o === 'mismatch') return staff
    ? 'Something does not match what is on file. Fleet and Admin have been told. Look again before you hand over the keys.'
    : 'Thanks. Our team will take a quick look at your photos. You can carry on with your check-in.';
  return staff ? 'The photo could not be compared automatically. Compare the licence with the photo on file yourself.' : 'Thanks. Your photos are saved with your booking.';
}

/** The card on file in words: "Visa ending in 4242, in the name of Rita Example". */
export function cardWords(c: PickupView['card']): string {
  if (!c?.last4) return 'No card on file for this booking';
  const brand = c.brand ? c.brand.charAt(0).toUpperCase() + c.brand.slice(1) : 'Card';
  return `${brand} ending in ${c.last4}${c.name ? `, in the name of ${c.name}` : ''}`;
}

/** The face comparison's answer, kept only when the model is sure enough; anything else is "unsure" and flags nothing. */
export function faceAnswer(d: unknown): 'same' | 'different' | 'unsure' {
  const o = (d && typeof d === 'object' ? d : {}) as Record<string, unknown>;
  const said = String(o.same_person ?? '').toLowerCase();
  const sure = typeof o.confidence === 'number' ? o.confidence : Number(o.confidence);
  if (said === 'same' && sure >= 60) return 'same';
  if (said === 'different' && sure >= 80) return 'different';
  return 'unsure';
}
