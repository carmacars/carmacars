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
// r48.2 (release 48, migration 3030). The owner (Nov 15): "even when they are available, if they're not exactly in the
// correct angle like they should be, it should just generate it to be in that angle so that all of the photos look like
// they've been taken exactly the same way in like a studio", the covers "in the EXACT same angle and facing the same
// direction as the sample cover photos", and "change the background to make it something more realistic". So:
//   * every view stands in the car's SCENE (Program settings listing_photo_scene, the fleet default, or the car's own
//     choice): the dark dealership studio with the CarmaCars sign on the wall (the default; on the cover also the model's
//     name in metal letters on the wall behind the car), or a realistic place of the marketing scenes (highway, brick
//     building, ...). One background plate per scene and angle family, made once, so every car's cover looks the same;
//   * the outside views face the way the sample covers face: the front three-quarter and the side profile with the car's
//     nose to the LEFT of the frame, the rear three-quarter with its nose to the right; the check says where the nose points;
//   * the licence plates are taken off cleanly (a smooth blank plate area), never drawn;
//   * the check splits its reasons: identity (another model, colour, warped, wrong view or direction, the old background
//     still there, a readable plate) always refuses; looks (framing, parts the real photos may not show, wheels, render look)
//     refuse the first two tries only, so a car is never left without its view for a small doubt;
//   * a measured check on top of Gemini's: the edges of the result must differ from the same-angle real photo
//     (borderDiff), so a background that "still looks the exact same" is refused.
// r48.4 (R50 hotfix 2, migration 5080): Gemini makes only the car, alone on a flat key colour; the site keys it out and puts
// it on its own drawn dealership (the CarmaCars sign and the car's name), the same place for every car (studio-composite.ts).
// The references are the car's listing photos, else its check-in and check-out photos, all of them sent (5080 removed the
// render chain that dropped the check-in photos while the words still counted them). The view and the direction follow one
// rule (viewReasons). The plate and scene words below stay for the marketing studio and scripts/r48-references.mjs.
// Pure: no I/O, so the unit tests cover the words, the angle specs, the plate families and the check's verdict.
import type { NBox } from './plate-cover.ts';
import type { Rgba } from './subject-frame.ts';
import { PLATES_KEY, angleOf, carName, isExterior, readPlates, type CarFacts, type CheckReason } from './r45.ts';
import { GATE_FEEDBACK, KEY, type GateReason, type KeyName } from './studio-gate.ts';

/** The standard (app.photo_r48_spec() returns the same; keep the two equal). */
export const R48_SPEC = 'r48.4';
/** r48.4 (5080): the cover, the first view of app.photo_render_order() (the sample photos' lead); its cutout drives off the cards. */
export const COVER_SHOT = 'front_left';
/** r48.4 (5080): the one dealership room every outside view stands in, stored once (the cards' plate behind a cutout). */
export const R48_ROOM_PATH = 'site/r48/room.jpg';
/** The preset recorded on a photo made to this standard. */
export const R48_PRESET = 'gemini_r48';
/** The car's real photos sent as references at most (each made at most R48_REF_SIDE on its long side). */
export const R48_MAX_REFS = 4;
export const R48_REF_SIDE = 1280;
/** The request's images together stay under this many bytes (Gemini takes about 20 MB inline, base64 included). */
export const R48_MAX_BYTES = 12_000_000;

// ================================================================ the angles: the target framing of each
export type PlateFamily = 'front' | 'side' | 'rear';
export interface AngleSpec { shot: string; label: string; exterior: boolean; family: PlateFamily | null; guide: string | null; framing: string }
/** The sample photos' angles in the sample photos' order (features/car/studio.ts SHOTS: lead, side, rear34, front, rear, dash,
 *  seats, wheel), the front three-quarter always first (5080: the owner's spec, every car gets exactly this set). `guide` is
 *  the sample cars' drawing of the view (its SHOTS key). */
// r48.4 (5080): the camera of each view only; the car's size and place in the frame are the site's (studio-composite.ts), and
// the words of the key (keyRule) ask for the whole car with a margin, so no line here asks for a floor or a share of the frame.
export const R48_ANGLES: readonly AngleSpec[] = [
  { shot: 'front_left', label: 'Front three-quarter', exterior: true, family: 'front', guide: 'lead',
    framing: 'front three-quarter of the driver (left) side, exactly as the composition guide: the car\'s nose points to the LEFT edge of the frame, turned about 30 degrees from a pure side profile towards the camera, so the whole left side and the front corner show; camera height about 0.9 m (headlight level); a 50 mm full-frame lens look from about 7 m (no wide-angle stretch, no fisheye); the whole car in the frame; the front wheels straight' },
  { shot: 'left', label: 'Side profile', exterior: true, family: 'side', guide: 'side',
    framing: 'full side profile of the driver (left) side, the car\'s nose to the LEFT of the frame: the camera square to the side of the car (90 degrees), level with the door handles (about 0.9 m); a 50 mm full-frame lens look from about 8 m; the whole car from bumper to bumper, both wheels fully visible and round' },
  { shot: 'rear_left', label: 'Rear three-quarter', exterior: true, family: 'rear', guide: 'rear34',
    framing: 'rear three-quarter from the driver (left) side, the car\'s nose to the RIGHT of the frame: the camera turned 45 degrees from the car\'s centre line so the whole back and the whole left side show; camera height about 0.9 m (tail-light level); a 50 mm full-frame lens look from about 7 m; the whole car in the frame' },
  { shot: 'front', label: 'Front', exterior: true, family: 'front', guide: 'front',
    framing: 'straight front view: the camera on the car\'s centre line, square to the front; camera height about 0.8 m (headlight level); a 70 mm full-frame lens look from about 8 m; the whole front in the frame, both mirrors and both front tyres visible' },
  { shot: 'rear', label: 'Rear', exterior: true, family: 'rear', guide: 'rear',
    framing: 'straight rear view: the camera on the car\'s centre line, square to the back; camera height about 0.8 m (tail-light level); a 70 mm full-frame lens look from about 8 m; the whole back in the frame, both rear tyres visible' },
  { shot: 'dashboard', label: 'Dashboard', exterior: false, family: null, guide: 'dash',
    framing: 'the dashboard from the middle of the rear seat, between the front seats, at shoulder height: the steering wheel, the instrument cluster, the centre screen and the centre console, level and centred; a 24 mm full-frame lens look without distortion of straight lines' },
  { shot: 'front_seats', label: 'Front seats', exterior: false, family: null, guide: 'seats',
    framing: 'both front seats seen through the open driver door from outside, at seat height: the driver seat in front, the passenger seat behind it, the door sill at the bottom of the frame; a 28 mm full-frame lens look' },
  { shot: 'wheel', label: 'Wheel detail', exterior: false, family: null, guide: 'wheel',
    framing: 'a close-up of the front left wheel, exactly as the composition guide: the camera level with the hub, square to the wheel, about 1.2 m away; the whole rim and tyre, the brake behind the spokes and the edge of the fender and the arch around it fill the frame; no background, no floor and no room visible beyond the car itself; a 70 mm full-frame lens look'}
] as const;
/** The outside views the site keys out and puts on the dealership (the wheel close-up and the inside views are kept as made). */
export const KEYED_SHOTS = ['front_left', 'left', 'rear_left', 'front', 'rear'] as const;
export const isKeyed = (shot: string) => (KEYED_SHOTS as readonly string[]).includes(shot);
export const r48Angle = (shot: string) => R48_ANGLES.find((a) => a.shot === shot) ?? null;
/** The background plate of a shot. r48.3 (release 50, 3701): ONE plate per scene for every outside view (the 'side' plate,
 *  the camera square to the back wall), so every view of every car stands in exactly the same room and floor; none inside. */
export const plateFamily = (shot: string): PlateFamily | null => (r48Angle(shot)?.exterior ? 'side' : null);
export const PLATE_FAMILIES: readonly PlateFamily[] = ['front', 'side', 'rear'];
/** The stored composition guide of an angle for a body type (scripts/r48-references.mjs writes them). */
export const guidePath = (body: string | null | undefined, shot: string): string | null => {
  const g = r48Angle(shot)?.guide;
  const b = /^[a-z]{2,12}$/.test(body ?? '') ? body! : 'sedan';
  return g ? `site/r48/guides/${b}-${g}.jpg` : null;
};
/** Where the made background plate of a family is kept (an Admin upload has its own name); r48.2: per scene. */
export const platePath = (f: PlateFamily, tag = '', scene = '') =>
  `site/r48/plates/${scene ? `${scene.replace(/[^a-z0-9]+/g, '-')}-` : ''}${f}${tag ? `-${tag}` : ''}.jpg`;

// ================================================================ r48.2: the scene, the direction
/** A scene of Program settings' marketing_scenes (the image model's words for the place). */
export interface R48Scene { code: string; label?: string | null; place?: string | null; reference?: boolean }
/** The fleet's scene unless Program settings or the car say otherwise: the dark dealership with the CarmaCars sign. */
export const DEFAULT_SCENE = 'showroom_dark';
export const isDealership = (s: R48Scene | null | undefined) => !s || s.code === DEFAULT_SCENE;
/** Where the car's nose points in each outside view of the standard (as the sample covers: features/car/studio.ts carShot). */
export const FACING: Readonly<Record<string, 'left' | 'right'>> = { front_left: 'left', left: 'left', rear_left: 'right' };
/** The words of the dark dealership studio, the room every car stands in by default. */
export const DEALERSHIP_PLACE = 'a modern, minimal, dark car dealership showroom: a charcoal back wall with a slatted walnut panel between two vertical LED light strips, the CarmaCars logo as a large softly lit sign high on the back wall, recessed linear lights in the ceiling, a polished dark tiled floor with soft reflections';
/** The licence plates of a generated view: taken off cleanly (r48.2), never drawn or blurred into a smudge. r48 (3040): a bare
 *  bumper, never a blank plate, box or blur, and where the car has no plate nothing at all is changed (the owner: "a lot of
 *  the cars don't have front license plates, and you're still blurring out the spot where the license plate would have been"). */
export const PLATE_REMOVE_RULE = 'THE LICENCE PLATES: no licence plate in the photo. Look at the real photos of each end of the car. Where the car has NO plate (many Ontario cars have no front plate), leave that bumper exactly as it is in the real photos: nothing where a plate would be, no plate holder, no blank rectangle, no blur, no box, no patch. Where the car carries a plate, take it off cleanly: show the bare bumper or plate recess in the car\'s own paint, shapes and lines, as if the plate was removed cleanly for the photo shoot; no blank plate, no letters, numbers or stickers, no blur, no box, no smudge.';
/** Which end of the car a view shows its plate on: front, rear, or none (a side profile, an inside view). */
export const plateEndOf = (shot: string): 'front' | 'rear' | null => (/^front(_left|_right)?$/.test(shot) ? 'front' : /^rear(_left|_right)?$/.test(shot) ? 'rear' : null);
/** r48 (3040): the plate rule of one view. `plateEnd`: whether the car's own photos show a plate at the end this view shows
 *  ('yes', 'no', or null when not known: app.photo_r48_plate_end). */
export function plateRule(shot: string, plateEnd?: 'yes' | 'no' | null): string {
  const end = plateEndOf(shot);
  if (!isExterior(shot)) return PLATE_REMOVE_RULE;
  if (!end) return `${PLATE_REMOVE_RULE} This view shows no plate: add nothing where a plate could be.`;
  if (plateEnd === 'no') return `${PLATE_REMOVE_RULE} THIS CAR HAS NO ${end.toUpperCase()} PLATE: its ${end} bumper stays exactly as in the real photos, untouched, with no plate, holder, rectangle, blur or box anywhere on it.`;
  if (plateEnd === 'yes') return `${PLATE_REMOVE_RULE} This car carries a ${end} plate: take it off cleanly so the bare ${end} bumper shows, with no blank plate, blur or box left.`;
  return end === 'front' ? `${PLATE_REMOVE_RULE} This is a front view: if the real photos show no front plate, the front bumper stays bare and untouched.` : PLATE_REMOVE_RULE;
}

// ================================================================ the real-photography cues
/** r48.4 (5080): what makes the car read as a photograph while it stands on the flat key colour (the site adds the room,
 *  the floor, its reflection and the shadow, so none of those is asked of the model). */
export const REAL_PHOTO_RULE = 'REAL PHOTOGRAPHY: the car must look like an unretouched studio photograph by a professional car photographer with a full-frame camera, not a 3D render or CGI: soft, even studio light from above and the front, the paint, chrome and glass reflecting soft white studio lights (never the key colour), real paint texture, true perspective for the asked lens. No plastic look, no glow, no HDR halos, no over-smoothing.';
/** r48: no text and no logo added anywhere (the site draws the CarmaCars sign and the name on its own room). */
export const NO_TEXT_NO_LOGO = 'NO TEXT AND NO LOGOS: add no letters, numbers, words, captions, watermarks, signs, stickers or logos anywhere. Only the car\'s own maker badges stay, where the car has them.';
const IDENTITY = (car: string, stock: boolean) => `THE CAR is a ${car}, exactly the car in the real photos: the same make, model, generation, body style and trim, the same paint colour and finish (match the real photos${stock ? ', not the stock photo' : ''}), the same wheels (design, size and colour), badges, lights, grille, mirrors, roof and window trim, the same interior materials and colours; its body lines and proportions true, nothing warped, stretched or bent, no part added or missing. Show it clean and damage-free (no dirt, scratches or dents), nothing else changed.`;
/** r48.4 (5080): the flat background the site keys out (studio-gate.ts chromaKey). */
export const keyRule = (key: KeyName) => `THE BACKGROUND: the car alone on a perfectly flat, uniform ${KEY[key].words} (${KEY[key].hex}) background that fills the whole frame from edge to edge, behind and under the car: no floor, no ground line, no room, no horizon, no shadow, no reflection, no gradient, no vignette, no other object. Nothing of the places in the real photos remains. The WHOLE car is inside the frame with a clear margin of the background on every side, about 70 percent of the frame width, centred; no part of the car is cut off by the frame.`;

// ================================================================ the generation words
export interface R48PromptInput { car: CarFacts; shot: string; refs: number; guide: boolean; stock: boolean; feedback?: readonly string[] | null;
  /** r48.4: the key colour of an outside view (studio-gate.ts keyFor: magenta for a green car) */
  key?: KeyName;
  /** r48.2: the car has no photo: the stock photo of its model is the only image of the car (sent first) */
  stockOnly?: boolean;
  /** r48 (3040): whether the car's own photos show a plate at the end this view shows (plateRule) */
  plateEnd?: 'yes' | 'no' | null }
/** The images in the order they are sent: the real photos (the listing's, else the check-in and check-out ones), the guide,
 *  the stock photo. r48.4: every one of them is sent (no image is dropped on the way, so the numbers always match). */
export function imageRoles(o: Pick<R48PromptInput, 'refs' | 'guide' | 'stock' | 'shot' | 'stockOnly'>): string[] {
  const ext = isExterior(o.shot);
  const out: string[] = [];
  const only = !!o.stockOnly && ext;
  const n = only ? 1 : Math.max(1, o.refs);
  out.push(only ? 'Image 1 is a stock photo of this exact model (another car of it): copy its shapes, lights, grille and proportions; the paint colour, wheels and trim are those named for THE CAR below, never the stock photo\'s plate, background or light.'
    : `${n === 1 ? 'Image 1 is a real photo' : `Images 1 to ${n} are real photos`} of THIS car: the source of its identity (colour, trim, wheels, badges${ext ? '' : ', interior materials'}).`);
  let k = n;
  if (o.guide) out.push(`Image ${++k} is a composition guide (a simple drawing of another car): copy exactly its camera position, height, angle and the direction the car's nose points; nothing of its look, colours, car, room or size in the frame.`);
  if (o.stock && ext && !only) out.push(`Image ${++k} is a stock photo of the same model (another car): use it only for shapes of this model the real photos do not show; never its colour, wheels, plate, background or light.`);
  return out;
}
/** What the result is refused for, as a sentence the next try is told. */
export const FEEDBACK_TEXT: Partial<Record<CheckReason | R48Reason, string>> = {
  wrong_colour: 'the paint colour did not match the real photos', wrong_model: 'it was not the same model', warped: 'the body or wheels were warped',
  parts_changed: 'parts were added or missing', text_elsewhere: 'text or a logo appeared', plate_readable: 'a plate could be read', blurry: 'it was blurred',
  clutter: 'the interior had loose objects', wrong_view: 'it showed the wrong view', wrong_wheels: 'the wheels were not the car\'s wheels',
  looks_cgi: 'it looked like a render, not a photograph', wrong_framing: 'the camera angle or height did not follow the angle description',
  no_answer: 'the check did not answer', plate_off_car: 'text like a plate appeared off the car', original_background: 'the place of the real photos was still there',
  wrong_direction: 'the car faced the wrong way (see where its nose must point)',
  plate_patch: 'there was a blur, box or blank rectangle where a plate is or would be (leave the bumper bare)', plate_oversized: 'a plate area spread over the bumper',
  plate_added: 'a plate was added to an end of the car that has none', plate_left: 'a licence plate was still on the car (take it off cleanly)'
};
export const feedbackLine = (reasons: readonly string[] | null | undefined): string => {
  const words = [...new Set((reasons ?? []).map((r) => FEEDBACK_TEXT[r as R48Reason] ?? GATE_FEEDBACK[r as GateReason] ?? '').filter(Boolean))].slice(0, 6);
  return words.length ? `AN EARLIER TRY WAS REFUSED because ${words.join('; ')}. Fix exactly that this time.` : '';
};

/** The words of one generated view. r48.4 (5080): an outside view is the car alone on the key colour (the site puts it in
 *  the room); an inside view is the car's interior as before (nothing is keyed inside). */
export function r48Prompt(o: R48PromptInput): string {
  const a = r48Angle(o.shot);
  const ext = isExterior(o.shot);
  const view = a?.framing ?? (angleOf(o.shot)?.view ?? o.shot.replace(/_/g, ' '));
  const face = FACING[o.shot];
  return [
    `Create one new photograph for a car rental listing: the ${a?.label.toLowerCase() ?? o.shot.replace(/_/g, ' ')} of a ${carName(o.car)}.`,
    `THE IMAGES: ${imageRoles(o).join(' ')}`,
    `TARGET VIEW: ${view}. Landscape 3:2.${face ? ` The car's nose MUST point to the ${face.toUpperCase()} of the frame, whatever way it faces in the real photos.` : ''}`,
    o.stockOnly && ext ? `THE CAR is a ${carName(o.car)}: the make, model, generation and body of the stock photo, in exactly the colour named here, its body lines and proportions true, nothing warped, clean and damage-free.` : IDENTITY(carName(o.car), o.stock && ext),
    ext ? keyRule(o.key ?? 'green')
      : o.shot === 'wheel' ? 'THE WHEEL: the car\'s own wheel exactly as in the real photos (the same rim design, spokes, finish, centre cap, tyre and brake colour), clean, the tyre black; only the car fills the frame: no floor, no room and no background visible.'
      : 'THE INTERIOR: no background is swapped; the windows show soft, bright daylight, nothing readable outside. Clean and bright, even soft light, no clutter (no bags, bottles, cables, papers or phones), the screens dark or a plain glow.',
    ext || o.shot === 'wheel' ? REAL_PHOTO_RULE : 'REAL PHOTOGRAPHY: an unretouched interior photograph from a full-frame camera, real material textures (leather grain, stitching, plastics), real light falloff, no render look, no glow, no over-smoothing.',
    plateRule(o.shot, o.plateEnd),
    NO_TEXT_NO_LOGO,
    'The whole car (or interior) sharp, no depth-of-field blur, no motion blur.',
    feedbackLine(o.feedback)
  ].filter(Boolean).join(' ');
}

/** r48.4 (5080): one of the car's real outside photos, added after the standard views: the car cut out as it is (its own
 *  angle), on the key colour, so the site puts it on the same dealership background. */
export function r48ExtraPrompt(o: { car: CarFacts; key: KeyName; feedback?: readonly string[] | null }): string {
  return [
    `Edit this real photograph of a ${carName(o.car)} for a car rental listing.`,
    'Keep the car exactly as it is in the photo: the same camera angle, distance, perspective and pose, the same paint, wheels, badges, lights and every part; do not turn, move, redraw or restyle it. Clean it (no dirt, scratches or dents).',
    `Replace EVERYTHING that is not the car (the ground, its shadow, the street, sky, buildings, people and other cars) with a perfectly flat, uniform ${KEY[o.key].words} (${KEY[o.key].hex}) background from edge to edge, with a clear margin of it on every side of the car. Where the car runs past the edge of the photo, show the whole car.`,
    PLATE_REMOVE_RULE,
    NO_TEXT_NO_LOGO,
    feedbackLine(o.feedback)
  ].filter(Boolean).join(' ');
}

// ================================================================ the check
export type R48Reason = CheckReason | 'wrong_wheels' | 'looks_cgi' | 'wrong_framing' | 'wrong_direction' | 'plate_added' | 'plate_left';
/** r48.2: the reasons that always refuse (it is not this car, not this view, or the old background is still there). */
export const HARD_REASONS: readonly R48Reason[] = ['wrong_colour', 'wrong_model', 'warped', 'wrong_view', 'wrong_direction', 'original_background', 'plate_readable',
  'plate_off_car', 'text_elsewhere', 'no_answer', 'plate_patch', 'plate_oversized', 'plate_added'];
/** The tries after which the other reasons alone no longer refuse (a view is then kept rather than left out for a doubt). */
export const SOFT_LAST_TRY = 2;

/** r48.4 (5080): the one rule for the view, used by the check's verdict (the words ask exactly this). The view the check
 *  reads must be the asked one, or the same view of the other side when the nose still points the standard's way; where
 *  the standard fixes the direction (FACING) the nose must point that way: 'camera', 'none' or no answer is a refusal, as
 *  the words say MUST. An extra photo ('studio_extra') keeps its own angle: no view rule. */
export function viewReasons(shot: string, view: string | null, nose: string | null): Array<'wrong_view' | 'wrong_direction'> {
  if (shot === 'studio_extra') return [];
  const out: Array<'wrong_view' | 'wrong_direction'> = [];
  const base = (s: string) => (s === 'right' ? 'left' : s.replace(/_right$/, '_left'));
  if (!view || base(view) !== base(shot)) out.push('wrong_view');
  const face = FACING[shot];
  if (face && nose !== face) out.push('wrong_direction');
  return out;
}

export const R48_CHECK_SYSTEM = 'You are a strict quality inspector for a car rental website\'s listing photos. You compare a generated photo with real photos of the same car and with the description of the wanted view, and answer with JSON only, in the shape asked.';
export function r48CheckPrompt(o: { car: CarFacts; shot: string; key?: KeyName | null; plateEnd?: 'yes' | 'no' | null }): string {
  const a = r48Angle(o.shot);
  const ext = isExterior(o.shot) || o.shot === 'studio_extra';
  const extra = o.shot === 'studio_extra';
  return [
    `The FIRST image is a generated listing photo to inspect${ext && o.key ? `: the car alone on a flat ${KEY[o.key].words} background (the background is wanted; the site replaces it)` : ''}. The other images are real photos of the same car, a ${carName(o.car)}.`,
    extra ? 'The wanted view: the same angle as the real photo.' : `The wanted view: ${a?.framing ?? o.shot.replace(/_/g, ' ')}.`,
    'Answer one JSON object with these keys, each true when the problem IS present in the generated photo:',
    '"wrong_colour": the paint colour or finish differs from the real photos;',
    '"wrong_model": not the same make, model, generation or body style;',
    '"wrong_wheels": the wheels clearly differ from the real photos (design or colour), only where the real photos show them clearly;',
    '"parts_changed": a part clearly visible in the real photos is missing or a part was added (mirrors, lights, badges, spoilers, roof rails); never for a part the real photos do not show;',
    '"warped": the body, wheels or interior are distorted, bent, melted or out of proportion;',
    '"looks_cgi": it looks like a 3D render or CGI rather than a real photograph (plastic surfaces, glow, wrong perspective);',
    '"wrong_framing": the camera angle or height clearly differs from the wanted view (not the car\'s size or place in the frame);',
    ext ? '"original_background": anything of a real place (a street, building, driveway, garage, trees, sky, ground or other cars) is still in the photo;' : '"original_background": always false here;',
    '"text_elsewhere": readable letters, numbers, words or logos anywhere other than the car\'s own maker badges;',
    '"plate_readable": any licence plate character can be read;',
    '"plate_present": a licence plate (with letters or numbers, readable or not) is on the car in the generated photo; false for a bare bumper or an empty plate recess;',
    '"plate_cover": a blur, smudge, mosaic, box, patch or blank rectangle on the car where a plate is or would be (the plates must be gone cleanly, the bumper bare);',
    `"real_plate": whether the real photos show a licence plate on the end of the car this view shows: "yes", "no" (for example a front bumper without a plate, common in Ontario) or "unsure"${plateEndOf(o.shot) ? '' : ' ("no" for a side profile or an inside view)'};`,
    '"blurry": the photo or a large part of it is blurred;',
    '"clutter": an interior shows loose objects that are not part of the car;',
    '"view": the view the generated photo shows, one of front_left, front_right, front, left, right, rear_left, rear_right, rear, dashboard, front_seats, rear_seats, trunk, wheel, other;',
    '"nose": where the car\'s front (nose) points in the frame: "left", "right", "camera" (straight at the camera), "away" (straight away), or "none" (an interior);',
    `"plates": ${PLATES_KEY};`,
    'Example: {"wrong_colour": false, "wrong_model": false, "wrong_wheels": false, "parts_changed": false, "warped": false, "looks_cgi": false, "wrong_framing": false, "original_background": false, "text_elsewhere": false, "plate_readable": false, "plate_present": false, "plate_cover": false, "real_plate": "no", "blurry": false, "clutter": false, "view": "front_left", "nose": "left", "plates": []}'
  ].join(' ');
}
export const R48_CHECK_SCHEMA = {
  type: 'object',
  properties: {
    wrong_colour: { type: 'boolean' }, wrong_model: { type: 'boolean' }, wrong_wheels: { type: 'boolean' }, parts_changed: { type: 'boolean' }, warped: { type: 'boolean' },
    looks_cgi: { type: 'boolean' }, wrong_framing: { type: 'boolean' }, original_background: { type: 'boolean' }, text_elsewhere: { type: 'boolean' },
    plate_readable: { type: 'boolean' }, plate_present: { type: 'boolean' }, plate_cover: { type: 'boolean' }, real_plate: { type: 'string' },
    blurry: { type: 'boolean' }, clutter: { type: 'boolean' }, view: { type: 'string' }, nose: { type: 'string' },
    plates: { type: 'array', items: { type: 'object', properties: { box_2d: { type: 'array', items: { type: 'number' } } } } }
  },
  required: ['wrong_colour', 'wrong_model', 'wrong_wheels', 'parts_changed', 'warped', 'looks_cgi', 'wrong_framing', 'text_elsewhere', 'plate_readable', 'plate_present', 'plate_cover', 'real_plate', 'blurry', 'view', 'nose', 'plates']
} as const;

export interface R48Verdict { pass: boolean; reasons: R48Reason[]; plates: NBox[]; view: string | null; nose?: string | null; soft?: R48Reason[] }
const truthy = (v: unknown) => v === true || v === 'true' || v === 'yes';
/** The check's answer as a verdict. No answer is a refusal. r48 (3040): the plates must be gone cleanly: a blur, box or blank
 *  patch where a plate is or would be, a plate area spread over the bumper, or a plate on an end of the car that has none
 *  (`plateEnd` 'no', or the check's own real_plate "no") always refuse; a real plate left on the car refuses the first tries
 *  (soft), and is then blurred by the site, tight to the plate. No box is kept when the check says no plate is there, so the
 *  site never blurs a bare bumper. "plate_readable" alone refuses only when the plate could not be placed. The view and the
 *  direction: viewReasons (r48.4). r48.2: from try SOFT_LAST_TRY on (`tries`, the tries made before this one), only
 *  HARD_REASONS refuse; the others are kept as `soft`. */
export function judgeR48(answer: unknown, o: { shot: string; tries?: number; plateEnd?: 'yes' | 'no' | null }): R48Verdict {
  if (!answer || typeof answer !== 'object') return { pass: false, reasons: ['no_answer'], plates: [], view: null };
  const a = answer as Record<string, unknown>;
  const ext = isExterior(o.shot) || o.shot === 'studio_extra';
  const reasons: R48Reason[] = [];
  // an extra photo keeps its own camera: no framing rule
  for (const k of ['wrong_colour', 'wrong_model', 'wrong_wheels', 'parts_changed', 'warped', 'looks_cgi', 'wrong_framing', 'text_elsewhere', 'blurry'] as const) {
    if (truthy(a[k]) && !(k === 'wrong_framing' && o.shot === 'studio_extra')) reasons.push(k);
  }
  if (ext && truthy(a.original_background)) reasons.push('original_background');
  if (!ext && truthy(a.clutter)) reasons.push('clutter');
  const pr = readPlates(a, o.shot);
  const plates: NBox[] = ext ? pr.plates : [];
  if (pr.offCar) reasons.push('plate_off_car');
  if (ext && truthy(a.plate_cover)) reasons.push('plate_patch');
  if (ext && pr.oversized) reasons.push('plate_oversized');
  const real = typeof a.real_plate === 'string' ? a.real_plate.toLowerCase() : null;
  const shown = plates.length > 0 || pr.present === true;
  if (ext && shown && plateEndOf(o.shot) && (o.plateEnd === 'no' || real === 'no')) reasons.push('plate_added');
  else if (ext && shown) reasons.push('plate_left');
  if (truthy(a.plate_readable) && !plates.length && !pr.oversized) reasons.push('plate_readable');
  const view = typeof a.view === 'string' ? a.view.slice(0, 20) : null;
  const nose = typeof a.nose === 'string' ? a.nose.slice(0, 10).toLowerCase() : null;
  reasons.push(...viewReasons(o.shot, view, nose));
  const all = [...new Set(reasons)];
  const late = (o.tries ?? 0) >= SOFT_LAST_TRY;
  const refusing = late ? all.filter((r) => HARD_REASONS.includes(r)) : all;
  return { pass: !refusing.length, reasons: refusing, plates, view, nose, soft: all.filter((r) => !refusing.includes(r)) };
}

// ================================================================ r48.2 (3030): the marketing studio's measure
/** r48.2: how different the edges of two photos are (0 the same, 1 opposite): the top 30 percent and the outer tenth of each
 *  side, sampled on a 120 x 80 grid. A generated outside view whose edges are this close to the same-angle real photo still
 *  shows the old place (BACKGROUND_SAME). Pure. */
export const BACKGROUND_SAME = 0.07;
export function borderDiff(a: Rgba, b: Rgba): number {
  const GX = 120, GY = 80;
  let sum = 0, n = 0;
  for (let gy = 0; gy < GY; gy++) {
    for (let gx = 0; gx < GX; gx++) {
      if (!(gy < GY * 0.3 || gx < GX * 0.1 || gx >= GX * 0.9)) continue;
      const ia = (Math.min(a.height - 1, Math.floor(((gy + 0.5) / GY) * a.height)) * a.width + Math.min(a.width - 1, Math.floor(((gx + 0.5) / GX) * a.width))) * 4;
      const ib = (Math.min(b.height - 1, Math.floor(((gy + 0.5) / GY) * b.height)) * b.width + Math.min(b.width - 1, Math.floor(((gx + 0.5) / GX) * b.width))) * 4;
      sum += (Math.abs(a.data[ia]! - b.data[ib]!) + Math.abs(a.data[ia + 1]! - b.data[ib + 1]!) + Math.abs(a.data[ia + 2]! - b.data[ib + 2]!)) / 765;
      n++;
    }
  }
  return n ? sum / n : 0;
}

// ================================================================ the background plates
/** The words that make one plate: the scene's place, empty, shot for that family's camera position. r48.2: the dark dealership
 *  (with the CarmaCars sign: its drawn layout is sent as the image) by default, or another scene's place. */
export function platePrompt(f: PlateFamily, scene?: R48Scene | null): string {
  const deal = isDealership(scene);
  const where = f === 'side'
    ? 'the camera square to the background (a car will stand side-on, parallel to it)'
    : f === 'front'
      ? 'the camera looking into the place at a slight angle (a car will stand turned towards the camera, its front to the left)'
      : 'the camera looking into the place at a slight angle, from the other side (a car will stand turned away, its back towards the camera)';
  return [
    `A real photograph of ${deal ? DEALERSHIP_PLACE : (scene?.place || scene?.label || DEALERSHIP_PLACE)}, empty, taken for a car listing photo:`,
    `${where}; the camera at about 0.9 m, a 50 mm full-frame lens look, landscape 3:2, the horizon level.`,
    'A large free ground area in the middle of the frame where a whole car will stand (from about 15 percent to 85 percent of the width, the bottom fifth of the frame ground), the background about 8 m away.',
    deal ? 'The image given is the layout of this room (a drawing): keep its layout, the CarmaCars sign exactly as drawn (its letters and shape) high on the back wall, and make everything a real photograph.'
      : scene?.reference ? 'The image given is a real photo of this place: the same place, the same ground and light, without any car or person in it.' : '',
    'Real photography: natural light falloff, soft shadows, slight lens vignetting, fine sensor grain, real material textures. Not a 3D render, not CGI, no glow, no HDR.',
    `Completely empty: no cars, no people, nothing in the middle. ${deal ? 'No text other than the CarmaCars sign.' : 'No text, no logos, no signs, no posters.'}`
  ].filter(Boolean).join(' ');
}
export const PLATE_CHECK_SYSTEM = 'You are a strict photo editor. You judge whether an image is a real photograph and answer with JSON only, in the shape asked.';
export const PLATE_CHECK_PROMPT = 'Inspect the image, meant as a real photograph of an empty place used as a background for car photos. Answer one JSON object: "looks_real" (true when it looks like an unretouched real photograph, not a 3D render, CGI or illustration), "has_text" (any readable letters, numbers or words), "has_logo" (any logo or sign), "has_cars_or_people" (any car, vehicle or person), "free_floor" (a clear floor area in the middle where a whole car could stand), "issues" (a short list of what looks fake, at most 5 strings). Example: {"looks_real": true, "has_text": false, "has_logo": false, "has_cars_or_people": false, "free_floor": true, "issues": []}';
export const PLATE_CHECK_SCHEMA = {
  type: 'object',
  properties: { looks_real: { type: 'boolean' }, has_text: { type: 'boolean' }, has_logo: { type: 'boolean' }, has_cars_or_people: { type: 'boolean' }, free_floor: { type: 'boolean' },
    issues: { type: 'array', items: { type: 'string' } } },
  required: ['looks_real', 'has_text', 'has_logo', 'has_cars_or_people', 'free_floor']
} as const;
/** A plate is used only when the check says it looks like a real photo, empty, with no text or logo and room for a car. */
export function judgePlate(answer: unknown, o: { logo?: boolean } = {}): { pass: boolean; reasons: string[] } {
  if (!answer || typeof answer !== 'object') return { pass: false, reasons: ['no_answer'] };
  const a = answer as Record<string, unknown>;
  const reasons: string[] = [];
  if (!truthy(a.looks_real)) reasons.push('not_real');
  // the dealership's plate carries the CarmaCars sign (its text and logo are wanted there)
  if (!o.logo && truthy(a.has_text)) reasons.push('text');
  if (!o.logo && truthy(a.has_logo)) reasons.push('logo');
  if (truthy(a.has_cars_or_people)) reasons.push('cars_or_people');
  if (a.free_floor !== undefined && !truthy(a.free_floor)) reasons.push('no_free_floor');
  return { pass: !reasons.length, reasons };
}
