// The sample cars' photos (public/sample-photos/cars/<slug>-<shot>.svg, 8 shots each) drawn by the site's own studio module
// (src/features/car/studio.ts: the showroom v2 since r35 S2), from the sample set of prototype/tools/src/data.mjs.
//   node --experimental-strip-types scripts/gen-sample-cars.mjs
import { writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { CARS } from '../../prototype/tools/src/data.mjs';
import { SHOTS, carShot } from '../src/features/car/studio.ts';

const OUT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public', 'sample-photos', 'cars');
let n = 0;
for (const c of CARS) for (const s of SHOTS) { writeFileSync(path.join(OUT, `${c.slug}-${s.key}.svg`), carShot(c, s.key, 1800, 1200).replace(/\n\s+/g, '\n')); n++; }
console.log(`gen-sample-cars: ${n} images`);
