// Release 48 (migration 3030): the Marketplace and social marketing set made from the car's studio set (the r48.2 views the
// website shows), so the Marketplace photos and the site's photos are the same car in the same angle, the cover first.
//   * Each copy moves the processed view into another scene (highway, brick building, the dark dealership, ...): the car,
//     its angle, size and place in the frame unchanged; only the place changes. The first photo in the dealership scene
//     keeps the CarmaCars sign and the model's name on the wall behind the car. A copy in the car's own website scene is the
//     website's photo itself (no image call).
//   * Lifestyle shots (the owner, Nov 15): a few copies with one glamorous adult woman with the car, styled like a fashion or
//     luxury car advert (cocktail or evening dress, a stylish going-out outfit, heels, sunglasses), confident poses: beside the
//     car, at the open door, in the driver's seat, walking past. Ad-appropriate always: fully dressed, no lingerie, swimwear,
//     nudity or sexual poses. Marked AI-generated; chosen per post. A shot Gemini refuses is skipped, never asked again with
//     other words.
//   * Verified like the website's views: Gemini's check says it is the same car (colour, model, wheels, not warped, no
//     readable plate) and, for a lifestyle shot, that the person is an adult dressed as the rules say; the site measures that
//     the background really changed (borderDiff against the source view).
// Pure: no I/O.
import { isDealership, type R48Scene } from './r48.ts';

/** The lifestyle poses, in the order a set uses them. */
export const LIFESTYLE_POSES: ReadonlyArray<{ code: string; label: string; words: string; shots: readonly string[] }> = [
  { code: 'beside', label: 'Beside the car', shots: ['front_left', 'front', 'left'],
    words: 'standing confidently beside the front wheel of the car, one hand resting lightly on the bonnet edge, looking towards the camera' },
  { code: 'door', label: 'At the open door', shots: ['front_left', 'left'],
    words: 'standing at the open driver door, one hand on the top of the door, about to get in, a confident half smile' },
  { code: 'driver', label: 'In the driver\'s seat', shots: ['front_left', 'left'],
    words: 'sitting in the driver\'s seat with the driver door open, both feet inside the car, hands on the steering wheel, seen through the open door' },
  { code: 'walking', label: 'Walking past', shots: ['front_left', 'front', 'left'],
    words: 'walking past the front of the car towards the camera side, mid-stride, sunglasses on, a small handbag in one hand' }
] as const;
export const LIFESTYLE_MAX = 3;
/** The outfits a lifestyle shot picks from, one per shot in turn (a fashion or luxury car advert). */
export const OUTFITS: readonly string[] = [
  'a fitted black cocktail dress with heels and sunglasses',
  'an elegant satin evening dress with heels',
  'a stylish going-out outfit: tailored trousers, a fitted top and a blazer, heels and sunglasses',
  'a fitted red midi dress with heels and gold jewellery'
];
/** The rules no setting or pose loosens. */
export const PERSON_RULES = 'THE PERSON: exactly one woman, clearly an adult (about 25 to 35 years old), attractive and well groomed, styled like a fashion or luxury car advertisement; fully dressed in the outfit named; a confident, natural, tasteful pose. NEVER: lingerie, swimwear, nudity, see-through or revealing clothes, sexual or suggestive poses or expressions. She never hides the car\'s badges and never sits or leans on the car in a way that hides it.';

export interface StudioMove { place: string; label: string; plate: boolean; reference: boolean; cover: boolean; scene: R48Scene | null; name: string | null;
  pose?: string | null; outfit?: string | null }
/** The words that move a studio view into another scene (and, for a lifestyle shot, add the person). */
export function studioMovePrompt(o: StudioMove): string {
  const pose = o.pose ? LIFESTYLE_POSES.find((p) => p.code === o.pose) ?? null : null;
  const deal = isDealership(o.scene);
  return [
    `Edit the first image, a studio photo of a car, into a real, high-end ${pose ? 'fashion and luxury car advertisement' : 'marketing'} photograph of the same car in this place: ${o.place}.`,
    o.plate ? 'The second image is the empty place (the background plate): the car stands in exactly that place, on its ground, at the scale and perspective its ground and horizon give.'
      : o.reference ? 'The second image is a photo of that real place: put the car in exactly that place, in front of the same building and wall, on the same ground, in the same light. Do not copy any car, person or sign from it.' : '',
    'THE CAR: exactly the same car, unchanged: the same make, model, generation, body, trim, paint colour and finish, wheels, badges and lights; the same camera angle, the same direction (its nose points the same way), the same size and place in the frame; not cropped, not warped, nothing added or removed. Only relight it for the place.',
    'Nothing of the studio around the car may remain: the whole background is the new place. Give the car a real, soft contact shadow under each tyre and believable reflections for the place.',
    deal && o.cover && o.name ? `On the back wall behind the car keep the CarmaCars sign and the model name "${o.name}" in brushed-metal letters, spelled exactly "${o.name}".` : '',
    pose ? `${PERSON_RULES} Her outfit: ${o.outfit ?? OUTFITS[0]}. Her pose: ${pose.words}.` : 'No people.',
    'No licence plate and no plate characters anywhere: keep each bumper as it is in the first image (bare, with nothing where a plate would be), never a blank plate, blur or box. No other text, logos, watermarks or signs added. Landscape 3:2. It must look like a real photograph, not a render.'
  ].filter(Boolean).join(' ');
}

export const STUDIO_MOVE_CHECK_SYSTEM = 'You are a strict quality inspector for a car rental company\'s marketing photos. You compare an edited photo with the original photo of the same car and answer with JSON only, in the shape asked.';
export function studioMoveCheckPrompt(o: { lifestyle: boolean }): string {
  return [
    'The FIRST image is an edited marketing photo to inspect. The SECOND image is the original photo of the same car.',
    'Answer one JSON object with these keys, each true when the problem IS present in the edited photo:',
    '"wrong_colour": the paint colour or finish differs from the original; "wrong_model": not the same make, model or body; "wrong_wheels": the wheels differ;',
    '"warped": the car is distorted, bent or out of proportion; "wrong_angle": the car is seen from another angle or faces another way than in the original;',
    '"background_same": the background is still the original\'s place; "plate_readable": any licence plate character can be read;',
    o.lifestyle
      ? '"person_not_ok": there is not exactly one person, or she does not clearly look like an adult, or she wears lingerie, swimwear or revealing or see-through clothes, or the pose or expression is sexual or suggestive;'
      : '"person_not_ok": any person is in the photo;',
    '"looks_cgi": it looks like a 3D render rather than a photograph.',
    'Example: {"wrong_colour": false, "wrong_model": false, "wrong_wheels": false, "warped": false, "wrong_angle": false, "background_same": false, "plate_readable": false, "person_not_ok": false, "looks_cgi": false}'
  ].join(' ');
}
export const STUDIO_MOVE_CHECK_SCHEMA = {
  type: 'object',
  properties: { wrong_colour: { type: 'boolean' }, wrong_model: { type: 'boolean' }, wrong_wheels: { type: 'boolean' }, warped: { type: 'boolean' }, wrong_angle: { type: 'boolean' },
    background_same: { type: 'boolean' }, plate_readable: { type: 'boolean' }, person_not_ok: { type: 'boolean' }, looks_cgi: { type: 'boolean' } },
  required: ['wrong_colour', 'wrong_model', 'wrong_wheels', 'warped', 'wrong_angle', 'background_same', 'plate_readable', 'person_not_ok']
} as const;
const truthy = (v: unknown) => v === true || v === 'true' || v === 'yes';
/** The check's answer as a verdict: every key above refuses (looks_cgi only counts as a note). No answer refuses. */
export function judgeStudioMove(answer: unknown): { pass: boolean; reasons: string[] } {
  if (!answer || typeof answer !== 'object') return { pass: false, reasons: ['no_answer'] };
  const a = answer as Record<string, unknown>;
  const reasons = ['wrong_colour', 'wrong_model', 'wrong_wheels', 'warped', 'wrong_angle', 'background_same', 'plate_readable', 'person_not_ok'].filter((k) => truthy(a[k]));
  return { pass: !reasons.length, reasons };
}

/** The lifestyle shots of a set: up to `n` (at most LIFESTYLE_MAX) of the poses, each on the first of its shots the set has,
 *  each with the next outfit. Pure. */
export function lifestylePlan(n: number, shots: readonly string[]): Array<{ pose: string; shot: string; outfit: string }> {
  const out: Array<{ pose: string; shot: string; outfit: string }> = [];
  for (const p of LIFESTYLE_POSES) {
    if (out.length >= Math.max(0, Math.min(LIFESTYLE_MAX, Math.floor(n)))) break;
    const shot = p.shots.find((s) => shots.includes(s));
    if (shot) out.push({ pose: p.code, shot, outfit: OUTFITS[out.length % OUTFITS.length]! });
  }
  return out;
}
