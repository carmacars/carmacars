// Release 50: the pictures of the academy (migration 4200). Two kinds, both served as small webp files from web/public/academy:
//  - screenshots: the guides' own cropped screens (docs/guides/src/img, listed in docs/guides/content/images.json) converted to webp;
//    a section names one by its stem ("va-cs-03-requests-desktop", or the stem with its hash when a stem has two files);
//  - example photos: good and bad car photos, a dashboard and damage, drawn from the sample-car illustrations (web/public/sample-photos)
//    so no real person, plate or customer is ever shown. They are examples of the shot, labelled as such on the page.
// web/scripts/academy-images.mjs builds the files and writes images.json (name, width, height, bytes, source) next to this file.
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
export const MANIFEST = join(dirname(fileURLToPath(import.meta.url)), 'images.json');
/** The most a picture may weigh (bytes): about 150 KB. */
export const MAX_BYTES = 150 * 1024;

const GUIDE_FILES = JSON.parse(readFileSync(join(ROOT, 'docs', 'guides', 'content', 'images.json'), 'utf8'));
const stemOf = (f) => f.replace(/\.(jpe?g|png|webp)$/i, '');
const noHash = (s) => s.replace(/-[0-9a-f]{8}$/, '');

/** A guide screenshot file from its stem (with or without the hash); the first file of a stem when it has more than one. */
export function resolveShot(key) {
  const hit = GUIDE_FILES.find((f) => stemOf(f) === key) ?? GUIDE_FILES.find((f) => noHash(stemOf(f)) === key);
  if (!hit) throw new Error(`academy picture: no guide screenshot "${key}"`);
  return hit;
}
/** The name (in /academy) of a picture key: a screenshot keeps its stem, an example photo its own name. */
export function pictureName(key) {
  return PHOTO_JOBS.some((p) => p.name === key) ? `${key}.webp` : `${stemOf(resolveShot(key))}.webp`;
}
/** What the build wrote: { name: { w, h, bytes } }; empty before the first build. */
export function loadManifest() {
  return existsSync(MANIFEST) ? JSON.parse(readFileSync(MANIFEST, 'utf8')) : {};
}

// ---- the example photos, drawn with sharp from the sample illustrations (width 800, 3:2). Each is { name, svg, steps }:
// `steps` is a function (sharp, svgPath) => sharp pipeline that returns a 800 x 533 image.
const CARS = 'web/public/sample-photos/cars';
const W = 800, H = 533;
const base = (sharp, file) => sharp(join(ROOT, CARS, file), { density: 96 }).resize(W, H, { fit: 'cover' });
const overlay = (svg) => ({ input: Buffer.from(svg), top: 0, left: 0 });
export const PHOTO_JOBS = [
  { name: 'photo-car-good', note: 'The whole car in the frame, level and well lit, a little space around it.',
    build: (sharp) => base(sharp, 'toyota-corolla-rear34.svg') },
  { name: 'photo-car-bad', note: 'Cut off, tilted, dark and soft.',
    build: async (sharp) => {
      const full = await sharp(join(ROOT, CARS, 'toyota-corolla-rear34.svg'), { density: 96 }).resize(1200, 800, { fit: 'cover' }).png().toBuffer();
      const img = await sharp(full).extract({ left: 380, top: 120, width: 700, height: 466 }).resize(W, H).modulate({ brightness: 0.45 }).blur(3.2).toBuffer();
      return sharp(img).rotate(7, { background: '#0b0b0b' }).resize(W, H, { fit: 'cover' });
    } },
  { name: 'photo-dash-good', note: 'The whole dashboard in focus, the display readable, no glare.',
    build: (sharp) => base(sharp, 'toyota-corolla-dash.svg') },
  { name: 'photo-dash-bad', note: 'Glare on the display, out of focus and cut off.',
    build: async (sharp) => {
      const full = await sharp(join(ROOT, CARS, 'toyota-corolla-dash.svg'), { density: 96 }).resize(1200, 800, { fit: 'cover' }).png().toBuffer();
      const img = await sharp(full).extract({ left: 120, top: 170, width: 720, height: 480 }).resize(W, H).blur(4).toBuffer();
      return sharp(img).composite([overlay(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}"><defs><radialGradient id="g" cx="62%" cy="38%" r="38%"><stop offset="0" stop-color="#fff" stop-opacity=".95"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient></defs><rect width="${W}" height="${H}" fill="url(#g)"/></svg>`)]);
    } },
  { name: 'photo-damage-close', note: 'Close up and lit: the scratch is sharp, with the door around it for place.',
    build: async (sharp) => {
      const full = await sharp(join(ROOT, CARS, 'toyota-corolla-side.svg'), { density: 192 }).resize(1800, 1200).png().toBuffer();
      const img = await sharp(full).extract({ left: 1020, top: 690, width: 600, height: 400 }).resize(W, H).modulate({ brightness: 1.25 }).toBuffer();
      return sharp(img).composite([overlay(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}"><path d="M250 255 L330 235 L400 262 L505 238" fill="none" stroke="#2b2b2b" stroke-width="5" stroke-linecap="round"/><path d="M250 258 L330 238 L400 265 L505 241" fill="none" stroke="#f5f5f5" stroke-width="2" stroke-linecap="round" opacity=".8"/><ellipse cx="378" cy="248" rx="170" ry="64" fill="none" stroke="#e11d2e" stroke-width="5"/></svg>`)]);
    } },
  { name: 'photo-damage-far', note: 'Too far away and dim: nobody can see where the damage is.',
    build: async (sharp) => base(sharp, 'toyota-corolla-side.svg').modulate({ brightness: 0.6 }).blur(1.6) }
];
