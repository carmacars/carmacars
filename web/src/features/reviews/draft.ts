// The review helper's draft (migration 0146, docs/changes/2026-10-24-review-requests.md). The renter picks what they
// liked, may give a star feel and writes a sentence in their own words; this puts a short first-person draft together
// from those answers and the facts of their booking (the car, how long, delivery or pickup), for them to check, change,
// copy and post on Google.
//
// The rules (tested in draft.test.ts): a phrase only for a thing the renter selected; the booking's facts only as
// facts (no praise of something they did not pick); their sentence as they wrote it; nothing at all without their input;
// the phrasing varies (the seed) but never the meaning. No imports: it runs in the browser and in plain Node.

export const LIKED = ['car', 'handover', 'communication', 'price', 'cleanliness', 'easy_booking'] as const;
export type Liked = (typeof LIKED)[number];

/** The chips' labels on the page. */
export const LIKED_LABEL: Record<Liked, string> = {
  car: 'The car',
  handover: 'Pickup or delivery',
  communication: 'Communication',
  price: 'Price',
  cleanliness: 'Cleanliness',
  easy_booking: 'Booking was easy'
};

/** The booking's facts the draft may state. */
export interface DraftFacts {
  vehicle: string | null;
  days: number | null;
  delivered: boolean;
  /** staff who did the handover or return (first names), offered as chips */
  staff: string[];
}

/** The renter's own answers. */
export interface DraftAnswers {
  liked: Liked[];
  /** staff names the renter tapped (only names from DraftFacts.staff are used) */
  staff: string[];
  /** the optional star feel, 1 to 5 */
  stars: number | null;
  /** one sentence in their own words */
  sentence: string;
}

export const SENTENCE_MAX = 400;

/** Small, stable hash: the same answers and seed give the same draft. */
function hash(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}
const pick = <T,>(xs: readonly T[], n: number): T => xs[n % xs.length]!;

/** The sentence as written: spaces tidied, a full stop added when it has no end mark, long dashes made commas. */
export function tidySentence(s: string): string {
  let t = String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, SENTENCE_MAX);
  t = t.replace(/\s*[\u2013\u2014]\s*/g, ', ');
  if (!t) return '';
  if (!/[.!?)"']$/.test(t)) t += '.';
  return t.charAt(0).toUpperCase() + t.slice(1);
}

function lengthText(days: number | null): string | null {
  if (!days || days < 1 || !Number.isFinite(days)) return null;
  return days === 1 ? 'a day' : `${Math.round(days)} days`;
}

function names(xs: string[]): string {
  if (xs.length <= 1) return xs.join('');
  return `${xs.slice(0, -1).join(', ')} and ${xs[xs.length - 1]}`;
}

/** The opening: the facts of the booking only. */
function opener(f: DraftFacts, n: number): string {
  const car = f.vehicle?.trim() ? `the ${f.vehicle.trim()}` : 'a car';
  const len = lengthText(f.days);
  const forLen = len ? ` for ${len}` : '';
  const delivered = f.delivered ? pick([' and had it delivered', ', delivered to me', ' with delivery'], n >> 3) : '';
  return pick([
    `I rented ${car} from CarmaCars${forLen}${delivered}.`,
    `Rented ${car} from CarmaCars${forLen}${delivered}.`,
    `I had ${car} from CarmaCars${forLen}${delivered}.`
  ], n);
}

const PHRASES: Record<Exclude<Liked, 'handover'>, readonly string[]> = {
  car: ['The car was great.', 'I liked the car.', 'Really liked the car itself.'],
  communication: ['Communication was good.', 'Communication was clear.', 'Good communication throughout.'],
  price: ['The price was fair.', 'Good value for the price.', 'Fair price.'],
  cleanliness: ['The car was clean.', 'Everything was clean.', 'The car was nice and clean.'],
  easy_booking: ['Booking was easy.', 'The booking was simple.', 'Easy to book.']
};
function handoverPhrase(delivered: boolean, n: number): string {
  return delivered ? pick(['The delivery went well.', 'Delivery was smooth.', 'The delivery was easy.'], n)
    : pick(['Pickup went well.', 'Pickup was smooth.', 'The pickup was easy.'], n);
}
function staffPhrase(xs: string[], n: number): string {
  const who = names(xs);
  return pick([`Thanks to ${who}.`, `${who} ${xs.length > 1 ? 'were' : 'was'} great.`, `Special thanks to ${who}.`], n);
}

/** Has the renter given anything to write from? */
export function hasInput(a: DraftAnswers, f: DraftFacts): boolean {
  return a.liked.some((x) => (LIKED as readonly string[]).includes(x)) || a.staff.some((x) => f.staff.includes(x)) || tidySentence(a.sentence).length > 0;
}

/** The draft, or '' when the renter gave nothing to write from (a review is never written for them). */
export function draftReview(f: DraftFacts, a: DraftAnswers, seed = 0): string {
  if (!hasInput(a, f)) return '';
  const base = hash(`${seed}|${a.liked.join(',')}|${a.staff.join(',')}`);
  const parts: string[] = [opener(f, base)];
  // in the order of the chips, each with its own variant
  let i = 0;
  for (const k of LIKED) {
    if (!a.liked.includes(k)) continue;
    const n = hash(`${base}:${k}:${i++}`);
    parts.push(k === 'handover' ? handoverPhrase(f.delivered, n) : pick(PHRASES[k], n));
  }
  const staff = a.staff.filter((x, j, xs) => f.staff.includes(x) && xs.indexOf(x) === j);
  if (staff.length) parts.push(staffPhrase(staff, hash(`${base}:staff`)));
  const own = tidySentence(a.sentence);
  if (own) parts.push(own);
  // the star feel is not written into the text: Google asks for the stars itself
  return parts.join(' ');
}

/** A low star feel: the page also offers "Something wasn't right? Tell us directly" (everyone still gets the Google link). */
export const unhappy = (stars: number | null): boolean => stars !== null && stars >= 1 && stars <= 3;
