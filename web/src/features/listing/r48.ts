// Release 48 (migrations 2900 to 2902): listing photo standard r48.1. The owner (Nov 14): "Why is the background dealership
// still so fake looking? ... generate AI photos of every single car in every single correct angle by sending Gemini a prompt
// with the sample photos as a reference and the real photos also as a reference and the background as a reference and
// describing what we want the outcome to look like for each angle." So, for every car and every standard angle:
//   * Gemini GENERATES the view from references: all the car's real photos (its identity), the composition guide of the
//     angle (the sample cars' drawing of that view, for the camera position only), the stock photo of the model (shapes the
//     real photos do not show) and the background plate of the angle family (a photorealistic empty showroom, made once by
//     Gemini and checked as "looks like a real photo", or a real showroom photo an Admin uploads). The words describe the
//     target framing of the angle (camera height, focal length look, crop, centring, 45 degrees for a three-quarter).
//   * Inside views get no background plate (nothing is swapped): the car's interior, clean and bright.
//   * Plates blurred, never readable; no text and no logo added anywhere.
//   * A second Gemini check compares the result with the real photos (same car, colour, wheels, trim, no warping, no CGI
//     look) and with the angle's framing; a refusal is made again with the reasons as feedback (two more tries); still
//     refused: flagged, and the car's real photo of that angle stays on the site (2890's rule).
// Pure: no I/O, so the unit tests cover the words, the angle specs, the plate families and the check's verdict.
import type { NBox } from './plate-cover.ts';
import { PLATE_BLUR_RULE, angleOf, carName, isExterior, onCar, type CarFacts, type CheckReason } from './r45.ts';

/** The standard (app.photo_r48_spec() returns the same; keep the two equal). */
export const R48_SPEC = 'r48.1';
/** The preset recorded on a photo made to this standard. */
export const R48_PRESET = 'gemini_r48';
/** The car's real photos sent as references at most (each made at most R48_REF_SIDE on its long side). */
export const R48_MAX_REFS = 6;
export const R48_REF_SIDE = 1280;
/** The request's images together stay under this many bytes (Gemini takes about 20 MB inline, base64 included). */
export const R48_MAX_BYTES = 12_000_000;

// ================================================================ the angles: the target framing of each
export type PlateFamily = 'front' | 'side' | 'rear';
export interface AngleSpec { shot: string; label: string; exterior: boolean; family: PlateFamily | null; guide: string | null; framing: string }
/** The nine standard angles in the order the site shows them (the front three-quarter always first). `guide` is the sample
 *  cars' drawing of the view (features/car/studio.ts SHOTS key), null when there is none. */
export const R48_ANGLES: readonly AngleSpec[] = [
  { shot: 'front_left', label: 'Front three-quarter', exterior: true, family: 'front', guide: 'lead',
    framing: 'front three-quarter from the driver (left) side: the camera turned 45 degrees from the car\'s centre line so the whole front and the whole left side show equally; camera height about 0.9 m (headlight level); a 50 mm full-frame lens look from about 7 m (no wide-angle stretch, no fisheye); the whole car in the frame, centred, about 80 percent of the frame width, a little floor in front of the bumper and above the roof; the front wheels straight' },
  { shot: 'front', label: 'Front', exterior: true, family: 'front', guide: 'front',
    framing: 'straight front view: the camera on the car\'s centre line, square to the front; camera height about 0.8 m (headlight level); a 70 mm full-frame lens look from about 8 m; the whole front in the frame, centred, about 65 percent of the frame width, both mirrors and both front tyres visible' },
  { shot: 'left', label: 'Side profile', exterior: true, family: 'side', guide: 'side',
    framing: 'full side profile of the driver (left) side: the camera square to the side of the car (90 degrees), level with the door handles (about 0.9 m); a 50 mm full-frame lens look from about 8 m; the whole car from bumper to bumper, centred, about 85 percent of the frame width, both wheels fully visible and round' },
  { shot: 'rear_left', label: 'Rear three-quarter', exterior: true, family: 'rear', guide: 'rear34',
    framing: 'rear three-quarter from the driver (left) side: the camera turned 45 degrees from the car\'s centre line so the whole back and the whole left side show; camera height about 0.9 m (tail-light level); a 50 mm full-frame lens look from about 7 m; the whole car in the frame, centred, about 80 percent of the frame width' },
  { shot: 'rear', label: 'Rear', exterior: true, family: 'rear', guide: 'rear',
    framing: 'straight rear view: the camera on the car\'s centre line, square to the back; camera height about 0.8 m (tail-light level); a 70 mm full-frame lens look from about 8 m; the whole back in the frame, centred, about 65 percent of the frame width, both rear tyres visible' },
  { shot: 'dashboard', label: 'Dashboard', exterior: false, family: null, guide: 'dash',
    framing: 'the dashboard from the middle of the rear seat, between the front seats, at shoulder height: the steering wheel, the instrument cluster, the centre screen and the centre console, level and centred; a 24 mm full-frame lens look without distortion of straight lines' },
  { shot: 'front_seats', label: 'Front seats', exterior: false, family: null, guide: 'seats',
    framing: 'both front seats seen through the open driver door from outside, at seat height: the driver seat in front, the passenger seat behind it, the door sill at the bottom of the frame; a 28 mm full-frame lens look' },
  { shot: 'rear_seats', label: 'Rear seats', exterior: false, family: null, guide: null,
    framing: 'the whole rear seat bench seen through the open left rear door from outside, at seat height, the backs of the front seats at the edge of the frame; a 28 mm full-frame lens look' },
  { shot: 'trunk', label: 'Trunk', exterior: false, family: null, guide: null,
    framing: 'the open trunk (cargo area) seen from directly behind the car at chest height (about 1.3 m), the lid or tailgate fully open, the cargo floor empty and clean, the bumper at the bottom of the frame; a 35 mm full-frame lens look' }
] as const;
export const r48Angle = (shot: string) => R48_ANGLES.find((a) => a.shot === shot) ?? null;
/** The background plate of a shot: front (front three-quarter and front), side, rear (rear three-quarter and rear); none inside. */
export const plateFamily = (shot: string): PlateFamily | null => r48Angle(shot)?.family ?? null;
export const PLATE_FAMILIES: readonly PlateFamily[] = ['front', 'side', 'rear'];
/** The stored composition guide of an angle for a body type (scripts/r48-references.mjs writes them). */
export const guidePath = (body: string | null | undefined, shot: string): string | null => {
  const g = r48Angle(shot)?.guide;
  const b = /^[a-z]{2,12}$/.test(body ?? '') ? body! : 'sedan';
  return g ? `site/r48/guides/${b}-${g}.jpg` : null;
};
/** Where the made background plate of a family is kept (an Admin upload has its own name). */
export const platePath = (f: PlateFamily, tag = '') => `site/r48/plates/${f}${tag ? `-${tag}` : ''}.jpg`;

// ================================================================ the real-photography cues
/** What makes the result read as a photograph, not a render (the owner: "so fake looking"). */
export const REAL_PHOTO_RULE = 'REAL PHOTOGRAPHY: it must look like an unretouched photograph taken by a professional car photographer with a full-frame camera, not a 3D render or CGI: real light falloff from soft overhead lights, a correct dark contact shadow where each tyre meets the floor and a soft shadow under the car, natural reflections of the room in the paint, glass and polished floor (soft, not mirror-perfect), the car\'s perspective and lens matching the room\'s perspective and horizon exactly, the same white balance and light direction on the car and on the room, real paint texture, slight natural lens vignetting and fine sensor grain. No plastic look, no glow, no HDR halos, no over-smoothing, no floating car.';
/** r48: no text and no logo added anywhere (the plate rule of r45 stays: blurred, never drawn). */
export const NO_TEXT_NO_LOGO = 'NO TEXT AND NO LOGOS: add no letters, numbers, words, captions, watermarks, signs, stickers or logos anywhere (not on the walls, floor, windows or car). Only the car\'s own maker badges stay, where the car has them.';
const IDENTITY = (car: string, stock: boolean) => `THE CAR is a ${car}, exactly the car in the real photos: the same make, model, generation, body style and trim, the same paint colour and finish (match the real photos${stock ? ', not the stock photo' : ''}), the same wheels (design, size and colour), badges, lights, grille, mirrors, roof and window trim, the same interior materials and colours; its body lines and proportions true, nothing warped, stretched or bent, no part added or missing. Show it clean and damage-free (no dirt, scratches or dents), nothing else changed.`;

// ================================================================ the generation words
export interface R48PromptInput { car: CarFacts; shot: string; refs: number; guide: boolean; stock: boolean; plate: boolean; feedback?: readonly string[] | null }
/** The images in the order they are sent: the real photos, the guide, the stock photo, the plate. */
export function imageRoles(o: Pick<R48PromptInput, 'refs' | 'guide' | 'stock' | 'plate' | 'shot'>): string[] {
  const ext = isExterior(o.shot);
  const out: string[] = [];
  const n = Math.max(1, o.refs);
  out.push(`${n === 1 ? 'Image 1 is a real photo' : `Images 1 to ${n} are real photos`} of THIS car: the source of its identity (colour, trim, wheels, badges${ext ? '' : ', interior materials'}).`);
  let k = n;
  if (o.guide) out.push(`Image ${++k} is a composition guide (a simple drawing of another car): copy only its camera position, height and framing; nothing of its look, colours, car or room.`);
  if (o.stock && ext) out.push(`Image ${++k} is a stock photo of the same model (another car): use it only for shapes of this model the real photos do not show; never its colour, wheels, plate, background or light.`);
  if (o.plate && ext) out.push(`Image ${++k}, the last, is the background plate: the real, empty showroom the car stands in.`);
  return out;
}
/** What the result is refused for, as a sentence the next try is told. */
export const FEEDBACK_TEXT: Partial<Record<CheckReason | R48Reason, string>> = {
  wrong_colour: 'the paint colour did not match the real photos', wrong_model: 'it was not the same model', warped: 'the body or wheels were warped',
  parts_changed: 'parts were added or missing', text_elsewhere: 'text or a logo appeared', plate_readable: 'a plate could be read', blurry: 'it was blurred',
  clutter: 'the interior had loose objects', wrong_view: 'it showed the wrong view', wrong_wheels: 'the wheels were not the car\'s wheels',
  looks_cgi: 'it looked like a render, not a photograph', wrong_framing: 'the framing did not follow the angle description', background_wrong: 'the room was not the background plate',
  no_answer: 'the check did not answer', plate_off_car: 'text like a plate appeared off the car', edges_not_dark: 'the edges were not the room', original_background: 'the place of the real photos was still there'
};
export const feedbackLine = (reasons: readonly string[] | null | undefined): string => {
  const words = [...new Set((reasons ?? []).map((r) => FEEDBACK_TEXT[r as R48Reason] ?? '').filter(Boolean))].slice(0, 6);
  return words.length ? `AN EARLIER TRY WAS REFUSED because ${words.join('; ')}. Fix exactly that this time.` : '';
};

/** The words of one generated view. */
export function r48Prompt(o: R48PromptInput): string {
  const a = r48Angle(o.shot);
  const ext = isExterior(o.shot);
  const view = a?.framing ?? (angleOf(o.shot)?.view ?? o.shot.replace(/_/g, ' '));
  return [
    `Create one new photograph for a car rental listing: the ${a?.label.toLowerCase() ?? o.shot.replace(/_/g, ' ')} of a ${carName(o.car)}.`,
    `THE IMAGES: ${imageRoles(o).join(' ')}`,
    `TARGET FRAMING: ${view}. Landscape 3:2.`,
    IDENTITY(carName(o.car), o.stock && ext),
    ext
      ? (o.plate
        ? 'THE ROOM: the background plate exactly as it is (its walls, windows, lights and floor, nothing added, moved or removed), the car standing on its floor in the free space in the middle, at the scale and perspective the room\'s floor and horizon give. Nothing of the places in the real photos may remain (no street, sky, trees, buildings, garage, other cars or people).'
        : 'THE ROOM: a real, empty, modern car dealership showroom: a polished light-grey floor with soft natural reflections, plain light walls, a window wall with soft daylight, recessed overhead lights; no other cars, people or furniture. Nothing of the places in the real photos may remain.')
      : 'THE INTERIOR: no background is swapped; the windows show soft, bright daylight, nothing readable outside. Clean and bright, even soft light, no clutter (no bags, bottles, cables, papers or phones), the screens dark or a plain glow.',
    ext ? REAL_PHOTO_RULE : 'REAL PHOTOGRAPHY: an unretouched interior photograph from a full-frame camera, real material textures (leather grain, stitching, plastics), real light falloff, no render look, no glow, no over-smoothing.',
    PLATE_BLUR_RULE,
    NO_TEXT_NO_LOGO,
    'The whole car (or interior) sharp, no depth-of-field blur, no motion blur.',
    feedbackLine(o.feedback)
  ].filter(Boolean).join(' ');
}

// ================================================================ the check
export type R48Reason = CheckReason | 'wrong_wheels' | 'looks_cgi' | 'wrong_framing' | 'background_wrong';
export const R48_CHECK_SYSTEM = 'You are a strict quality inspector for a car rental website\'s listing photos. You compare a generated photo with real photos of the same car and with the description of the wanted view, and answer with JSON only, in the shape asked.';
export function r48CheckPrompt(o: { car: CarFacts; shot: string; plate: boolean }): string {
  const a = r48Angle(o.shot);
  const ext = isExterior(o.shot);
  return [
    `The FIRST image is a generated listing photo to inspect. The other images are real photos of the same car, a ${carName(o.car)}${ext && o.plate ? ', and the last one is the background plate (the empty showroom the car must stand in)' : ''}.`,
    `The wanted view: ${a?.framing ?? o.shot.replace(/_/g, ' ')}.`,
    'Answer one JSON object with these keys, each true when the problem IS present in the generated photo:',
    '"wrong_colour": the paint colour or finish differs from the real photos;',
    '"wrong_model": not the same make, model, generation or body style;',
    '"wrong_wheels": the wheels differ from the real photos (design, size or colour), where the real photos show them;',
    '"parts_changed": parts added or missing compared with the real car (mirrors, lights, badges, spoilers, seats, screens);',
    '"warped": the body, wheels or interior are distorted, bent, melted or out of proportion;',
    '"looks_cgi": it looks like a 3D render or CGI rather than a real photograph (plastic surfaces, no contact shadow, floating car, perspective of car and room not matching, glow);',
    `"wrong_framing": the camera angle, height, crop or centring clearly differs from the wanted view;`,
    ext && o.plate ? '"background_wrong": the room is not the background plate, or anything of another place (street, sky, other cars, people) is there;' : '"background_wrong": always false here;',
    '"text_elsewhere": readable letters, numbers, words or logos anywhere other than the car\'s own maker badges;',
    '"plate_readable": any licence plate character can still be read;',
    '"blurry": the photo or a large part of it is blurred (a strongly blurred licence plate does not count);',
    '"clutter": an interior shows loose objects that are not part of the car;',
    '"view": the view the generated photo shows, one of front_left, front_right, front, left, right, rear_left, rear_right, rear, dashboard, front_seats, rear_seats, trunk, other;',
    '"plates": every licence plate in the generated photo, each {"box_2d": [ymin, xmin, ymax, xmax]} on a 0 to 1000 grid (y first); [] when none.',
    'Example: {"wrong_colour": false, "wrong_model": false, "wrong_wheels": false, "parts_changed": false, "warped": false, "looks_cgi": false, "wrong_framing": false, "background_wrong": false, "text_elsewhere": false, "plate_readable": false, "blurry": false, "clutter": false, "view": "front_left", "plates": []}'
  ].join(' ');
}
export const R48_CHECK_SCHEMA = {
  type: 'object',
  properties: {
    wrong_colour: { type: 'boolean' }, wrong_model: { type: 'boolean' }, wrong_wheels: { type: 'boolean' }, parts_changed: { type: 'boolean' }, warped: { type: 'boolean' },
    looks_cgi: { type: 'boolean' }, wrong_framing: { type: 'boolean' }, background_wrong: { type: 'boolean' }, text_elsewhere: { type: 'boolean' },
    plate_readable: { type: 'boolean' }, blurry: { type: 'boolean' }, clutter: { type: 'boolean' }, view: { type: 'string' },
    plates: { type: 'array', items: { type: 'object', properties: { box_2d: { type: 'array', items: { type: 'number' } } } } }
  },
  required: ['wrong_colour', 'wrong_model', 'wrong_wheels', 'parts_changed', 'warped', 'looks_cgi', 'wrong_framing', 'text_elsewhere', 'plate_readable', 'blurry', 'view', 'plates']
} as const;

export interface R48Verdict { pass: boolean; reasons: R48Reason[]; plates: NBox[]; view: string | null }
const truthy = (v: unknown) => v === true || v === 'true' || v === 'yes';
/** The check's answer as a verdict. No answer is a refusal. A plate the check placed on the car is blurred by the site
 *  afterwards, so "plate_readable" alone refuses only when the plate could not be placed. The view must be the asked one (a
 *  three-quarter from the other side is accepted). */
export function judgeR48(answer: unknown, o: { shot: string; plate: boolean }): R48Verdict {
  if (!answer || typeof answer !== 'object') return { pass: false, reasons: ['no_answer'], plates: [], view: null };
  const a = answer as Record<string, unknown>;
  const ext = isExterior(o.shot);
  const reasons: R48Reason[] = [];
  for (const k of ['wrong_colour', 'wrong_model', 'wrong_wheels', 'parts_changed', 'warped', 'looks_cgi', 'wrong_framing', 'text_elsewhere', 'blurry'] as const) if (truthy(a[k])) reasons.push(k);
  if (ext && o.plate && truthy(a.background_wrong)) reasons.push('background_wrong');
  if (!ext && truthy(a.clutter)) reasons.push('clutter');
  const plates: NBox[] = [];
  for (const it of Array.isArray(a.plates) ? a.plates.slice(0, 6) : []) {
    const b = (it as { box_2d?: unknown })?.box_2d;
    if (!Array.isArray(b) || b.length !== 4 || !b.every((n) => typeof n === 'number' && Number.isFinite(n))) continue;
    const [y0, x0, y1, x1] = (b as number[]).map((n) => Math.max(0, Math.min(1000, n)) / 1000) as [number, number, number, number];
    if (x1 <= x0 || y1 <= y0) continue;
    plates.push({ x: x0, y: y0, w: x1 - x0, h: y1 - y0 });
  }
  if (plates.some((p) => !onCar(p))) reasons.push('plate_off_car');
  if (truthy(a.plate_readable) && !plates.length) reasons.push('plate_readable');
  const view = typeof a.view === 'string' ? a.view.slice(0, 20) : null;
  const sameSide = (want: string, got: string) => got === want || (want === 'front_left' && got === 'front_right') || (want === 'rear_left' && got === 'rear_right') || (want === 'left' && got === 'right');
  if (view && view !== 'other' && !sameSide(o.shot, view)) reasons.push('wrong_view');
  return { pass: !reasons.length, reasons: [...new Set(reasons)], plates: plates.filter(onCar), view };
}

// ================================================================ the background plates
/** The words that make one plate: a real, empty showroom shot for that family's camera position. */
export function platePrompt(f: PlateFamily): string {
  const where = f === 'side'
    ? 'the camera square to the long back wall (a car will stand side-on, parallel to the back wall)'
    : f === 'front'
      ? 'the camera looking into the room at a slight angle to the back wall (a car will stand turned 45 degrees to the camera, its front towards the camera)'
      : 'the camera looking into the room at a slight angle to the back wall, from the other end of the room (a car will stand turned away, its back towards the camera)';
  return [
    'A real photograph of an empty, modern, high-end car dealership showroom, taken for a car listing photo:',
    `${where}; the camera at about 0.9 m, a 50 mm full-frame lens look, landscape 3:2, the horizon level.`,
    'A large free floor area in the middle of the frame where a whole car will stand (from about 15 percent to 85 percent of the width, the bottom fifth of the frame floor), the back wall about 8 m away.',
    'A polished light-grey concrete or large-format porcelain floor with soft, natural reflections; plain warm-white and light-grey walls; a tall window wall or glass front with soft, even daylight; recessed overhead lights and long soft light panels; clean and minimal.',
    'Real photography: natural light falloff, soft shadows, slight lens vignetting, fine sensor grain, real material textures. Not a 3D render, not CGI, no glow, no HDR.',
    'Completely empty: no cars, no people, no furniture in the middle, no plants in the way. No text, no logos, no signs, no screens, no posters anywhere.'
  ].join(' ');
}
export const PLATE_CHECK_SYSTEM = 'You are a strict photo editor. You judge whether an image is a real photograph and answer with JSON only, in the shape asked.';
export const PLATE_CHECK_PROMPT = 'Inspect the image, meant as a real photograph of an empty car showroom used as a background for car photos. Answer one JSON object: "looks_real" (true when it looks like an unretouched real photograph, not a 3D render, CGI or illustration), "has_text" (any readable letters, numbers or words), "has_logo" (any logo or sign), "has_cars_or_people" (any car, vehicle or person), "free_floor" (a clear floor area in the middle where a whole car could stand), "issues" (a short list of what looks fake, at most 5 strings). Example: {"looks_real": true, "has_text": false, "has_logo": false, "has_cars_or_people": false, "free_floor": true, "issues": []}';
export const PLATE_CHECK_SCHEMA = {
  type: 'object',
  properties: { looks_real: { type: 'boolean' }, has_text: { type: 'boolean' }, has_logo: { type: 'boolean' }, has_cars_or_people: { type: 'boolean' }, free_floor: { type: 'boolean' },
    issues: { type: 'array', items: { type: 'string' } } },
  required: ['looks_real', 'has_text', 'has_logo', 'has_cars_or_people', 'free_floor']
} as const;
/** A plate is used only when the check says it looks like a real photo, empty, with no text or logo and room for a car. */
export function judgePlate(answer: unknown): { pass: boolean; reasons: string[] } {
  if (!answer || typeof answer !== 'object') return { pass: false, reasons: ['no_answer'] };
  const a = answer as Record<string, unknown>;
  const reasons: string[] = [];
  if (!truthy(a.looks_real)) reasons.push('not_real');
  if (truthy(a.has_text)) reasons.push('text');
  if (truthy(a.has_logo)) reasons.push('logo');
  if (truthy(a.has_cars_or_people)) reasons.push('cars_or_people');
  if (a.free_floor !== undefined && !truthy(a.free_floor)) reasons.push('no_free_floor');
  return { pass: !reasons.length, reasons };
}
