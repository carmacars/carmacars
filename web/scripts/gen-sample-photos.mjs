// The built-in sample photos (migration 0054): one placeholder per body type, shown on a listing with no real photo until
// staff add real photos or a library photo (Admin > Settings > Sample photos). Since r35 S2 they are drawn in the showroom v2
// (the studio module of the site, src/features/car/studio.ts), the body type's name on the wall and "Sample photo" in the
// corner so a copy shared on its own still says what it is.
//   node --experimental-strip-types scripts/gen-sample-photos.mjs     writes public/sample-photos/<type>.svg and .jpg (1600 x 1067)
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from '@playwright/test';
import { carShot } from '../src/features/car/studio.ts';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(WEB, 'public/sample-photos');
const W = 1600, H = 1067;
// each body type: the studio drawing's shape, and the word on the wall
const TYPES = { sedan: ['sedan', 'Sedan'], suv: ['suv', 'SUV'], truck: ['suvlg', 'Pickup truck'], van: ['van', 'Van'], coupe: ['fastback', 'Coupe'],
  hatchback: ['compact', 'Hatchback'], ev: ['sedan', 'Electric car'] };

mkdirSync(OUT, { recursive: true });
const browser = await chromium.launch(process.env.CHROME ? { executablePath: process.env.CHROME } : {});
const page = await browser.newPage({ viewport: { width: W, height: H } });
for (const [type, [shape, label]] of Object.entries(TYPES)) {
  const s = carShot({ year: '', name: label, model: label, colour: 'grey', shape, paint: 'grey' }, 'lead', W, H, 'SAMPLE PHOTO').replace(/\n\s+/g, '\n');
  writeFileSync(path.join(OUT, `${type}.svg`), s);
  await page.setContent(`<!doctype html><html><body style="margin:0">${s}</body></html>`);
  await page.screenshot({ path: path.join(OUT, `${type}.jpg`), type: 'jpeg', quality: 82, clip: { x: 0, y: 0, width: W, height: H } });
}
await browser.close();
console.log(`sample photos: ${Object.keys(TYPES).join(', ')} in public/sample-photos`);
